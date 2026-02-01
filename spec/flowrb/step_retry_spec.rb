# frozen_string_literal: true

RSpec.describe 'Step Retries' do
  describe 'retry option' do
    it 'retries failed step up to specified count' do
      attempts = 0

      pipeline = Flowrb.define do
        step :flaky, retries: 3 do
          attempts += 1
          raise 'failed' if attempts < 3

          'success'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:flaky].output).to eq('success')
      expect(attempts).to eq(3)
    end

    it 'fails after exhausting all retries' do
      attempts = 0

      pipeline = Flowrb.define do
        step :always_fails, retries: 3 do
          attempts += 1
          raise 'permanent failure'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.step_name).to eq(:always_fails)
        expect(error.original_error.message).to eq('permanent failure')
      end
      expect(attempts).to eq(4) # 1 initial + 3 retries
    end

    it 'does not retry when retries is 0' do
      attempts = 0

      pipeline = Flowrb.define do
        step :no_retry, retries: 0 do
          attempts += 1
          raise 'failed'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError)
      expect(attempts).to eq(1)
    end

    it 'does not retry successful steps' do
      attempts = 0

      pipeline = Flowrb.define do
        step :succeeds, retries: 3 do
          attempts += 1
          'success'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(attempts).to eq(1)
    end

    it 'works with parallel executor' do
      attempts = { a: 0, b: 0 }
      mutex = Mutex.new

      pipeline = Flowrb.define do
        step :flaky_a, retries: 2 do
          mutex.synchronize { attempts[:a] += 1 }
          raise 'fail a' if attempts[:a] < 2

          'a done'
        end

        step :flaky_b, retries: 2 do
          mutex.synchronize { attempts[:b] += 1 }
          raise 'fail b' if attempts[:b] < 2

          'b done'
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(attempts[:a]).to eq(2)
      expect(attempts[:b]).to eq(2)
    end
  end

  describe 'retry_delay option' do
    it 'waits between retries' do
      attempts = 0
      timestamps = []

      pipeline = Flowrb.define do
        step :delayed_retry, retries: 2, retry_delay: 0.1 do
          timestamps << Time.now
          attempts += 1
          raise 'failed' if attempts < 3

          'success'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(timestamps.size).to eq(3)

      # Check delays between attempts
      delay1 = timestamps[1] - timestamps[0]
      delay2 = timestamps[2] - timestamps[1]
      expect(delay1).to be >= 0.09
      expect(delay2).to be >= 0.09
    end

    it 'defaults to no delay when retry_delay not specified' do
      attempts = 0
      timestamps = []

      pipeline = Flowrb.define do
        step :no_delay, retries: 2 do
          timestamps << Time.now
          attempts += 1
          raise 'failed' if attempts < 3

          'success'
        end
      end

      start = Time.now
      result = pipeline.run
      elapsed = Time.now - start

      expect(result).to be_success
      # Should complete quickly without delays
      expect(elapsed).to be < 0.1
    end
  end

  describe 'retry_backoff option' do
    it 'applies exponential backoff to retry delays' do
      attempts = 0
      timestamps = []

      pipeline = Flowrb.define do
        step :backoff_retry, retries: 3, retry_delay: 0.05, retry_backoff: :exponential do
          timestamps << Time.now
          attempts += 1
          raise 'failed' if attempts < 4

          'success'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(timestamps.size).to eq(4)

      # Delays should increase: 0.05, 0.1, 0.2 (exponential)
      delay1 = timestamps[1] - timestamps[0]
      delay2 = timestamps[2] - timestamps[1]
      delay3 = timestamps[3] - timestamps[2]

      expect(delay1).to be >= 0.04
      expect(delay2).to be >= 0.08 # ~2x first delay
      expect(delay3).to be >= 0.16 # ~2x second delay
    end

    it 'applies linear backoff when specified' do
      attempts = 0
      timestamps = []

      pipeline = Flowrb.define do
        step :linear_retry, retries: 3, retry_delay: 0.05, retry_backoff: :linear do
          timestamps << Time.now
          attempts += 1
          raise 'failed' if attempts < 4

          'success'
        end
      end

      result = pipeline.run
      expect(result).to be_success

      # Delays should increase linearly: 0.05, 0.1, 0.15
      delay1 = timestamps[1] - timestamps[0]
      delay2 = timestamps[2] - timestamps[1]
      delay3 = timestamps[3] - timestamps[2]

      expect(delay1).to be >= 0.04
      expect(delay2).to be >= 0.09  # ~2x base
      expect(delay3).to be >= 0.14  # ~3x base
    end
  end

  describe 'retry_if option' do
    it 'only retries when condition is met' do
      attempts = 0

      pipeline = Flowrb.define do
        step :conditional_retry, retries: 3, retry_if: ->(error) { error.is_a?(IOError) } do
          attempts += 1
          raise IOError, 'transient' if attempts < 3

          'success'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(attempts).to eq(3)
    end

    it 'does not retry when condition is not met' do
      attempts = 0

      pipeline = Flowrb.define do
        step :no_retry_condition, retries: 3, retry_if: ->(error) { error.is_a?(IOError) } do
          attempts += 1
          raise ArgumentError, 'permanent'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error).to be_a(ArgumentError)
      end
      expect(attempts).to eq(1) # No retries for ArgumentError
    end
  end

  describe 'step result retry information' do
    it 'includes retry count in step result' do
      attempts = 0

      pipeline = Flowrb.define do
        step :tracked_retries, retries: 2 do
          attempts += 1
          raise 'failed' if attempts < 3

          'success'
        end
      end

      result = pipeline.run
      expect(result[:tracked_retries].retries).to eq(2)
    end

    it 'records zero retries for successful first attempt' do
      pipeline = Flowrb.define do
        step :first_try, retries: 3 do
          'immediate success'
        end
      end

      result = pipeline.run
      expect(result[:first_try].retries).to eq(0)
    end
  end
end
