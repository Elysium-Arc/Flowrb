# frozen_string_literal: true

# Comprehensive timeout tests based on patterns from:
# - Airflow: execution_timeout, sensor timeout, AirflowTaskTimeout, AirflowSensorTimeout
# - Celery: soft_time_limit, time_limit
# - General distributed systems: timeout handling, partial completion

RSpec.describe 'Timeout Patterns' do
  describe 'basic timeout behavior' do
    it 'allows completion within timeout' do
      pipeline = Flowrb.define do
        step :fast_enough, timeout: 1 do
          sleep 0.05
          'completed in time'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:fast_enough].output).to eq('completed in time')
      expect(result[:fast_enough]).not_to be_timed_out
    end

    it 'terminates step exceeding timeout' do
      pipeline = Flowrb.define do
        step :too_slow, timeout: 0.1 do
          sleep 10
          'never returned'
        end
      end

      start = Time.now
      expect { pipeline.run }.to raise_error(Flowrb::StepError)
      elapsed = Time.now - start

      # Should have terminated around timeout, not waited 10 seconds
      expect(elapsed).to be < 0.5
    end

    it 'marks timed out step result correctly' do
      pipeline = Flowrb.define do
        step :timeout_marker, timeout: 0.05 do
          sleep 1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        step_result = error.partial_results[:timeout_marker]
        expect(step_result).to be_timed_out
        expect(step_result).to be_failed
      end
    end
  end

  describe 'timeout error details' do
    it 'includes step name in timeout error' do
      pipeline = Flowrb.define do
        step :named_timeout, timeout: 0.05 do
          sleep 1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error).to be_a(Flowrb::TimeoutError)
        expect(error.original_error.step_name).to eq(:named_timeout)
      end
    end

    it 'includes timeout duration in error' do
      pipeline = Flowrb.define do
        step :duration_timeout, timeout: 0.123 do
          sleep 1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error.timeout_seconds).to eq(0.123)
        expect(error.original_error.message).to include('0.123')
      end
    end
  end

  describe 'timeout with dependencies' do
    it 'times out step while preserving completed dependencies' do
      pipeline = Flowrb.define do
        step :fast_dependency do
          'dependency completed'
        end

        step :slow_dependent, depends_on: :fast_dependency, timeout: 0.05 do |_input|
          sleep 1
          'never'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.step_name).to eq(:slow_dependent)
        expect(error.partial_results[:fast_dependency].output).to eq('dependency completed')
      end
    end

    it 'does not execute dependents of timed out step' do
      executed = []

      pipeline = Flowrb.define do
        step :timeout_step, timeout: 0.05 do
          executed << :timeout_step
          sleep 1
        end

        step :never_runs, depends_on: :timeout_step do |_|
          executed << :never_runs
          'dependent'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError)
      expect(executed).to eq([:timeout_step])
      expect(executed).not_to include(:never_runs)
    end
  end

  describe 'parallel execution with timeouts' do
    it 'times out individual parallel steps independently' do
      results_received = {}
      mutex = Mutex.new

      pipeline = Flowrb.define do
        step :fast_parallel, timeout: 1 do
          sleep 0.05
          mutex.synchronize { results_received[:fast] = true }
          'fast done'
        end

        step :slow_parallel, timeout: 0.05 do
          sleep 1
          mutex.synchronize { results_received[:slow] = true }
          'slow never'
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError) do |error|
        expect(error.step_name).to eq(:slow_parallel)
      end
    end

    it 'handles multiple timeouts in parallel' do
      pipeline = Flowrb.define do
        step :slow_a, timeout: 0.05 do
          sleep 1
        end

        step :slow_b, timeout: 0.05 do
          sleep 1
        end

        step :slow_c, timeout: 0.05 do
          sleep 1
        end
      end

      start = Time.now
      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError)
      elapsed = Time.now - start

      # All should timeout around the same time (parallel)
      expect(elapsed).to be < 0.3
    end

    it 'applies timeout correctly with max_threads limit' do
      pipeline = Flowrb.define do
        step :timeout_limited, timeout: 0.05 do
          sleep 1
        end
      end

      start = Time.now
      expect { pipeline.run(executor: :parallel, max_threads: 1) }.to raise_error(Flowrb::StepError)
      elapsed = Time.now - start

      expect(elapsed).to be < 0.3
    end
  end

  describe 'timeout edge cases' do
    it 'handles very small timeout values' do
      pipeline = Flowrb.define do
        step :tiny_timeout, timeout: 0.001 do
          # Even simple operations might exceed 1ms
          1 + 1
        end
      end

      # May or may not timeout - just ensure no crash
      begin
        result = pipeline.run
        expect(result).to be_success
      rescue Flowrb::StepError => e
        expect(e.original_error).to be_a(Flowrb::TimeoutError)
      end
    end

    it 'handles timeout of zero (treated as no timeout)' do
      # In Ruby's Timeout.timeout, a value of 0 means no timeout
      pipeline = Flowrb.define do
        step :zero_timeout, timeout: 0 do
          sleep 0.05
          'completed with zero timeout (no timeout)'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:zero_timeout].output).to eq('completed with zero timeout (no timeout)')
    end

    it 'handles nil timeout (no timeout applied)' do
      pipeline = Flowrb.define do
        step :nil_timeout, timeout: nil do
          sleep 0.1
          'completed without timeout'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:nil_timeout].output).to eq('completed without timeout')
    end

    it 'handles step that completes exactly at timeout boundary' do
      # This is inherently racy, but tests boundary behavior
      pipeline = Flowrb.define do
        step :boundary, timeout: 0.1 do
          sleep 0.09 # Just under timeout
          'just made it'
        end
      end

      result = pipeline.run
      expect(result).to be_success
    end
  end

  describe 'timeout vs regular errors' do
    it 'distinguishes timeout from regular exceptions' do
      pipeline = Flowrb.define do
        step :regular_error, timeout: 1 do
          raise 'not a timeout'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error).not_to be_a(Flowrb::TimeoutError)
        expect(error.original_error).to be_a(RuntimeError)
        expect(error.partial_results[:regular_error]).not_to be_timed_out
      end
    end

    it 'handles exception raised just before timeout' do
      pipeline = Flowrb.define do
        step :error_before_timeout, timeout: 0.5 do
          sleep 0.1
          raise 'error after some work'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error.message).to eq('error after some work')
        expect(error.partial_results[:error_before_timeout]).not_to be_timed_out
      end
    end
  end

  describe 'timeout with CPU-intensive operations' do
    it 'times out CPU-bound operations' do
      pipeline = Flowrb.define do
        step :cpu_intensive, timeout: 0.1 do
          # CPU-intensive work
          result = 0
          loop do
            result += 1
            break if result > 1_000_000_000 # Should timeout before this
          end
          result
        end
      end

      start = Time.now
      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error).to be_a(Flowrb::TimeoutError)
      end
      elapsed = Time.now - start

      expect(elapsed).to be < 0.5
    end
  end

  describe 'timeout recording in results' do
    it 'records accurate duration for timed out step' do
      pipeline = Flowrb.define do
        step :timed_duration, timeout: 0.1 do
          sleep 1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        duration = error.partial_results[:timed_duration].duration
        # Duration should be approximately the timeout value
        expect(duration).to be >= 0.09
        expect(duration).to be < 0.3
      end
    end

    it 'records started_at for timed out step' do
      before = Time.now

      pipeline = Flowrb.define do
        step :timed_started, timeout: 0.05 do
          sleep 1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        started_at = error.partial_results[:timed_started].started_at
        expect(started_at).to be >= before
        expect(started_at).to be <= Time.now
      end
    end
  end

  describe 'timeout cleanup' do
    it 'does not leave zombie threads after timeout' do
      initial_thread_count = Thread.list.count

      pipeline = Flowrb.define do
        step :zombie_check, timeout: 0.05 do
          sleep 1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError)

      # Give threads time to clean up
      sleep 0.1

      # Thread count should be close to initial (allow some variance)
      expect(Thread.list.count).to be <= initial_thread_count + 2
    end
  end

  describe 'sequential vs parallel timeout behavior' do
    it 'behaves consistently between sequential and parallel for single step' do
      [nil, :sequential, :parallel].each do |executor|
        pipeline = Flowrb.define do
          step :consistent_timeout, timeout: 0.05 do
            sleep 1
          end
        end

        executor_opts = executor ? { executor: executor } : {}

        expect { pipeline.run(**executor_opts) }.to raise_error(Flowrb::StepError) do |error|
          expect(error.original_error).to be_a(Flowrb::TimeoutError)
          expect(error.step_name).to eq(:consistent_timeout)
        end
      end
    end
  end
end
