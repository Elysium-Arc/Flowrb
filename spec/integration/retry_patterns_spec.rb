# frozen_string_literal: true

# Comprehensive retry tests based on patterns from:
# - Tenacity (Python): stop conditions, wait strategies, retry conditions
# - Celery (Python): autoretry_for, retry_backoff, retry_backoff_max, retry_jitter
# - Prefect (Python): exponential_backoff, retry_jitter_factor, retry_delay_seconds list
# - Airflow (Python): execution_timeout, max_retry_delay, retry_exponential_backoff

RSpec.describe 'Retry Patterns' do
  describe 'stop conditions' do
    # Pattern from Tenacity: stop_after_attempt
    it 'stops after specified number of attempts' do
      attempts = 0

      pipeline = Piperb.define do
        step :limited_retries, retries: 3 do
          attempts += 1
          raise "Attempt #{attempts} failed"
        end
      end

      expect { pipeline.run }.to raise_error(Piperb::StepError)
      expect(attempts).to eq(4) # 1 initial + 3 retries
    end

    # Pattern from Tenacity: stop_after_attempt(0) edge case
    it 'handles zero retries (no retry attempts)' do
      attempts = 0

      pipeline = Piperb.define do
        step :no_retries, retries: 0 do
          attempts += 1
          raise 'immediate failure'
        end
      end

      expect { pipeline.run }.to raise_error(Piperb::StepError)
      expect(attempts).to eq(1)
    end

    # Inspired by Prefect issue #13794: exponential_backoff with retries=0
    it 'handles retry options with zero retries gracefully' do
      attempts = 0

      pipeline = Piperb.define do
        step :backoff_no_retries, retries: 0, retry_delay: 1, retry_backoff: :exponential do
          attempts += 1
          raise 'fails immediately'
        end
      end

      expect { pipeline.run }.to raise_error(Piperb::StepError)
      expect(attempts).to eq(1)
    end

    # Large retry count (stress test)
    it 'handles large number of retries' do
      attempts = 0
      success_on = 10

      pipeline = Piperb.define do
        step :many_retries, retries: 15 do
          attempts += 1
          raise 'not yet' if attempts < success_on

          'finally succeeded'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(attempts).to eq(success_on)
      expect(result[:many_retries].retries).to eq(success_on - 1)
    end
  end

  describe 'wait strategies' do
    # Pattern from Tenacity: wait_fixed
    it 'applies fixed delay between retries' do
      timestamps = []

      pipeline = Piperb.define do
        step :fixed_delay, retries: 2, retry_delay: 0.1 do
          timestamps << Time.now
          raise 'retry' if timestamps.size < 3

          'done'
        end
      end

      result = pipeline.run
      expect(result).to be_success

      # All delays should be approximately equal
      delay1 = timestamps[1] - timestamps[0]
      delay2 = timestamps[2] - timestamps[1]
      expect(delay1).to be_within(0.03).of(0.1)
      expect(delay2).to be_within(0.03).of(0.1)
    end

    # Pattern from Tenacity: wait_exponential
    it 'applies exponential backoff with doubling delays' do
      timestamps = []

      pipeline = Piperb.define do
        step :exp_backoff, retries: 3, retry_delay: 0.05, retry_backoff: :exponential do
          timestamps << Time.now
          raise 'retry' if timestamps.size < 4

          'done'
        end
      end

      result = pipeline.run
      expect(result).to be_success

      # Delays should approximately double: 0.05, 0.1, 0.2
      delay1 = timestamps[1] - timestamps[0]
      delay2 = timestamps[2] - timestamps[1]
      delay3 = timestamps[3] - timestamps[2]

      expect(delay1).to be_within(0.02).of(0.05)
      expect(delay2).to be_within(0.03).of(0.10)
      expect(delay3).to be_within(0.05).of(0.20)
    end

    # Pattern from Celery: retry_backoff with linear increase
    it 'applies linear backoff with incrementing delays' do
      timestamps = []

      pipeline = Piperb.define do
        step :linear_backoff, retries: 3, retry_delay: 0.05, retry_backoff: :linear do
          timestamps << Time.now
          raise 'retry' if timestamps.size < 4

          'done'
        end
      end

      result = pipeline.run
      expect(result).to be_success

      # Delays should increase linearly: 0.05, 0.10, 0.15
      delay1 = timestamps[1] - timestamps[0]
      delay2 = timestamps[2] - timestamps[1]
      delay3 = timestamps[3] - timestamps[2]

      expect(delay1).to be_within(0.02).of(0.05)
      expect(delay2).to be_within(0.02).of(0.10)
      expect(delay3).to be_within(0.02).of(0.15)
    end

    # Zero delay (no wait between retries)
    it 'handles zero retry_delay (immediate retries)' do
      timestamps = []

      pipeline = Piperb.define do
        step :no_delay, retries: 3, retry_delay: 0 do
          timestamps << Time.now
          raise 'retry' if timestamps.size < 4

          'done'
        end
      end

      start = Time.now
      result = pipeline.run
      elapsed = Time.now - start

      expect(result).to be_success
      # Should complete very quickly with no delays
      expect(elapsed).to be < 0.1
    end
  end

  describe 'retry conditions' do
    # Pattern from Tenacity: retry_if_exception_type
    it 'retries only for specified exception types' do
      attempts = 0

      pipeline = Piperb.define do
        step :selective, retries: 3, retry_if: ->(e) { e.is_a?(IOError) } do
          attempts += 1
          raise IOError, 'transient IO error' if attempts < 3

          'recovered'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(attempts).to eq(3)
    end

    # Pattern from Tenacity: retry_if_not_exception_type
    it 'does not retry for excluded exception types' do
      attempts = 0

      pipeline = Piperb.define do
        step :no_retry_for_arg_error, retries: 3, retry_if: ->(e) { !e.is_a?(ArgumentError) } do
          attempts += 1
          raise ArgumentError, 'permanent error'
        end
      end

      expect { pipeline.run }.to raise_error(Piperb::StepError)
      expect(attempts).to eq(1) # No retries for ArgumentError
    end

    # Pattern from Celery: autoretry_for with multiple exception types
    it 'retries for multiple exception types' do
      attempts = 0
      errors = [IOError, Errno::ECONNREFUSED, Errno::ETIMEDOUT]

      pipeline = Piperb.define do
        step :multi_exception, retries: 5, retry_if: ->(e) { errors.any? { |t| e.is_a?(t) } } do
          attempts += 1
          case attempts
          when 1 then raise IOError, 'io error'
          when 2 then raise Errno::ECONNREFUSED, 'connection refused'
          when 3 then raise Errno::ETIMEDOUT, 'timeout'
          else 'success after various errors'
          end
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(attempts).to eq(4)
    end

    # Pattern from Airflow: AirflowFailException equivalent (fast-fail)
    it 'supports fast-fail condition to skip retries' do
      attempts = 0
      permanent_error_class = Class.new(StandardError)

      pipeline = Piperb.define do
        step :fast_fail, retries: 5, retry_if: ->(e) { !e.is_a?(permanent_error_class) } do
          attempts += 1
          raise permanent_error_class, 'API key invalid - no point retrying'
        end
      end

      expect { pipeline.run }.to raise_error(Piperb::StepError)
      expect(attempts).to eq(1)
    end
  end

  describe 'combined timeout and retry' do
    # Pattern from Airflow: execution_timeout with retries
    it 'retries after timeout and eventually succeeds' do
      attempts = 0

      pipeline = Piperb.define do
        step :timeout_then_success, timeout: 0.1, retries: 3 do
          attempts += 1
          if attempts < 3
            sleep 1 # Will timeout
          else
            'success on third attempt'
          end
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:timeout_then_success].output).to eq('success on third attempt')
      expect(attempts).to eq(3)
    end

    # Pattern from Airflow: timeout does not reset across retries
    it 'applies timeout independently to each retry attempt' do
      attempt_durations = []
      mutex = Mutex.new

      pipeline = Piperb.define do
        step :independent_timeouts, timeout: 0.1, retries: 2 do
          start = Time.now
          begin
            sleep 0.05 # Should complete within timeout
            mutex.synchronize { attempt_durations << (Time.now - start) }
            raise 'intentional failure' if attempt_durations.size < 3

            'done'
          rescue StandardError
            mutex.synchronize { attempt_durations << (Time.now - start) }
            raise
          end
        end
      end

      result = pipeline.run
      expect(result).to be_success
      # Each attempt should have taken ~0.05s (within timeout)
      expect(attempt_durations).to all(be < 0.1)
    end

    # All retries timeout
    it 'fails when all retry attempts timeout' do
      attempts = 0

      pipeline = Piperb.define do
        step :always_timeout, timeout: 0.05, retries: 2 do
          attempts += 1
          sleep 1 # Always exceeds timeout
        end
      end

      expect { pipeline.run }.to raise_error(Piperb::StepError) do |error|
        expect(error.original_error).to be_a(Piperb::TimeoutError)
      end
      expect(attempts).to eq(3) # 1 initial + 2 retries
    end
  end

  describe 'error preservation' do
    # Pattern from Tenacity: reraise original exception
    it 'preserves original exception in StepError' do
      custom_error = Class.new(StandardError)

      pipeline = Piperb.define do
        step :custom_error_step, retries: 2 do
          raise custom_error, 'custom message'
        end
      end

      expect { pipeline.run }.to raise_error(Piperb::StepError) do |error|
        expect(error.original_error).to be_a(custom_error)
        expect(error.original_error.message).to eq('custom message')
      end
    end

    # Verify last error is preserved (not first)
    it 'preserves the last error after all retries exhausted' do
      attempt = 0

      pipeline = Piperb.define do
        step :changing_errors, retries: 2 do
          attempt += 1
          raise "Error on attempt #{attempt}"
        end
      end

      expect { pipeline.run }.to raise_error(Piperb::StepError) do |error|
        expect(error.original_error.message).to eq('Error on attempt 3')
      end
    end
  end

  describe 'parallel execution with retries' do
    # Multiple steps with different retry configurations
    it 'handles different retry configs in parallel steps' do
      attempts = { a: 0, b: 0, c: 0 }
      mutex = Mutex.new

      pipeline = Piperb.define do
        step :step_a, retries: 1 do
          mutex.synchronize { attempts[:a] += 1 }
          raise 'fail a' if attempts[:a] < 2

          'a done'
        end

        step :step_b, retries: 2 do
          mutex.synchronize { attempts[:b] += 1 }
          raise 'fail b' if attempts[:b] < 3

          'b done'
        end

        step :step_c, retries: 0 do
          mutex.synchronize { attempts[:c] += 1 }
          'c done immediately'
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(attempts[:a]).to eq(2)
      expect(attempts[:b]).to eq(3)
      expect(attempts[:c]).to eq(1)
    end

    # One step fails after retries while others succeed
    it 'propagates failure from one parallel step after retries' do
      attempts = { ok: 0, fail: 0 }
      mutex = Mutex.new

      pipeline = Piperb.define do
        step :ok_step, retries: 2 do
          mutex.synchronize { attempts[:ok] += 1 }
          raise 'temporary' if attempts[:ok] < 2

          'ok'
        end

        step :fail_step, retries: 2 do
          mutex.synchronize { attempts[:fail] += 1 }
          raise 'always fails'
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Piperb::StepError) do |error|
        expect(error.step_name).to eq(:fail_step)
      end
    end

    # Retry with delays in parallel
    it 'applies retry delays correctly in parallel execution' do
      timestamps = { a: [], b: [] }
      mutex = Mutex.new

      pipeline = Piperb.define do
        step :delayed_a, retries: 2, retry_delay: 0.05 do
          mutex.synchronize { timestamps[:a] << Time.now }
          raise 'retry a' if timestamps[:a].size < 3

          'a done'
        end

        step :delayed_b, retries: 2, retry_delay: 0.05 do
          mutex.synchronize { timestamps[:b] << Time.now }
          raise 'retry b' if timestamps[:b].size < 3

          'b done'
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success

      # Both steps should have applied delays
      %i[a b].each do |step|
        delay1 = timestamps[step][1] - timestamps[step][0]
        expect(delay1).to be >= 0.04
      end
    end
  end

  describe 'retry state tracking' do
    it 'tracks retry count in step result' do
      attempts = 0

      pipeline = Piperb.define do
        step :tracked, retries: 5 do
          attempts += 1
          raise 'retry' if attempts < 4

          'done'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:tracked].retries).to eq(3)
    end

    it 'reports zero retries for first-attempt success' do
      pipeline = Piperb.define do
        step :immediate_success, retries: 5 do
          'instant success'
        end
      end

      result = pipeline.run
      expect(result[:immediate_success].retries).to eq(0)
    end

    it 'reports retry count even on final failure' do
      pipeline = Piperb.define do
        step :always_fails, retries: 3 do
          raise 'nope'
        end
      end

      expect { pipeline.run }.to raise_error(Piperb::StepError) do |error|
        failed_step_result = error.partial_results[:always_fails]
        expect(failed_step_result.retries).to eq(3)
      end
    end
  end

  describe 'idempotency with retries' do
    # Important pattern: retried operations should be idempotent
    it 'produces same result regardless of retry count' do
      # Simulate idempotent operation
      call_count = 0
      stored_value = nil

      pipeline = Piperb.define do
        step :idempotent_write, retries: 3 do
          call_count += 1
          # Idempotent: always sets same value
          stored_value = 'final_value'
          raise 'transient error' if call_count < 3

          stored_value
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(stored_value).to eq('final_value')
      expect(result[:idempotent_write].output).to eq('final_value')
    end
  end

  describe 'edge cases' do
    it 'handles nil retry_if (always retry)' do
      attempts = 0

      pipeline = Piperb.define do
        step :nil_condition, retries: 2, retry_if: nil do
          attempts += 1
          raise 'error' if attempts < 3

          'done'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(attempts).to eq(3)
    end

    it 'handles exception in retry_if condition' do
      attempts = 0

      pipeline = Piperb.define do
        step :bad_condition, retries: 2, retry_if: ->(_e) { raise 'condition error' } do
          attempts += 1
          raise 'step error'
        end
      end

      # When retry_if raises, it's caught and results in a failed pipeline
      # (the exception from retry_if is caught by the executor's rescue block)
      result = pipeline.run
      expect(result).to be_failed
      expect(result.error.message).to eq('condition error')
      expect(attempts).to eq(1)
    end

    it 'handles very short timeout' do
      pipeline = Piperb.define do
        step :micro_timeout, timeout: 0.001 do
          sleep 0.1
          'never'
        end
      end

      expect { pipeline.run }.to raise_error(Piperb::StepError) do |error|
        expect(error.original_error).to be_a(Piperb::TimeoutError)
      end
    end

    it 'handles step that succeeds on last retry' do
      attempts = 0

      pipeline = Piperb.define do
        step :last_chance, retries: 3 do
          attempts += 1
          raise 'not yet' if attempts <= 3 # Fails initial + first 2 retries

          'made it on final retry'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:last_chance].output).to eq('made it on final retry')
      expect(result[:last_chance].retries).to eq(3)
    end
  end
end
