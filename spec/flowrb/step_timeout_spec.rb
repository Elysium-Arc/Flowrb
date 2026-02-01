# frozen_string_literal: true

RSpec.describe 'Step Timeouts' do
  describe 'timeout option' do
    it 'allows step to complete within timeout' do
      pipeline = Flowrb.define do
        step :fast, timeout: 1 do
          sleep 0.05
          'completed'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:fast].output).to eq('completed')
    end

    it 'raises TimeoutError when step exceeds timeout' do
      pipeline = Flowrb.define do
        step :slow, timeout: 0.1 do
          sleep 1
          'never returned'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.step_name).to eq(:slow)
        expect(error.original_error).to be_a(Flowrb::TimeoutError)
      end
    end

    it 'includes timeout duration in error message' do
      pipeline = Flowrb.define do
        step :timed_out, timeout: 0.1 do
          sleep 1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error.message).to include('0.1')
      end
    end

    it 'works with parallel executor' do
      pipeline = Flowrb.define do
        step :fast_parallel, timeout: 1 do
          sleep 0.05
          'fast'
        end

        step :also_fast, timeout: 1 do
          sleep 0.05
          'also fast'
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
    end

    it 'times out individual step in parallel execution' do
      pipeline = Flowrb.define do
        step :fast_one, timeout: 1 do
          'quick'
        end

        step :slow_one, timeout: 0.1 do
          sleep 1
          'never'
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError) do |error|
        expect(error.step_name).to eq(:slow_one)
      end
    end
  end

  describe 'timeout with retries' do
    it 'retries after timeout' do
      attempts = 0

      pipeline = Flowrb.define do
        step :timeout_retry, timeout: 0.1, retries: 2 do
          attempts += 1
          if attempts < 3
            sleep 1 # Will timeout
          else
            'success after retries'
          end
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:timeout_retry].output).to eq('success after retries')
      expect(attempts).to eq(3)
    end

    it 'fails after all retries timeout' do
      attempts = 0

      pipeline = Flowrb.define do
        step :always_timeout, timeout: 0.1, retries: 2 do
          attempts += 1
          sleep 1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error).to be_a(Flowrb::TimeoutError)
      end
      expect(attempts).to eq(3) # 1 initial + 2 retries
    end

    it 'respects retry_delay between timeout retries' do
      attempts = 0
      timestamps = []

      pipeline = Flowrb.define do
        step :delayed_timeout_retry, timeout: 0.05, retries: 2, retry_delay: 0.1 do
          timestamps << Time.now
          attempts += 1
          if attempts < 3
            sleep 1 # Will timeout
          else
            'success'
          end
        end
      end

      result = pipeline.run
      expect(result).to be_success

      # Check retry delays
      delay1 = timestamps[1] - timestamps[0]
      delay2 = timestamps[2] - timestamps[1]

      # Each delay should be at least retry_delay (0.1) + timeout (0.05)
      expect(delay1).to be >= 0.1
      expect(delay2).to be >= 0.1
    end
  end

  describe 'step result timeout information' do
    it 'records that step timed out in partial results' do
      pipeline = Flowrb.define do
        step :timed_out_step, timeout: 0.1 do
          sleep 1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        step_result = error.partial_results[:timed_out_step]
        expect(step_result).to be_timed_out
      end
    end

    it 'records successful step as not timed out' do
      pipeline = Flowrb.define do
        step :success, timeout: 1 do
          'done'
        end
      end

      result = pipeline.run
      expect(result[:success]).not_to be_timed_out
    end
  end

  describe 'no timeout (default behavior)' do
    it 'runs without timeout when not specified' do
      pipeline = Flowrb.define do
        step :no_timeout do
          sleep 0.1
          'completed'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:no_timeout].output).to eq('completed')
    end
  end
end
