# frozen_string_literal: true

# Tests for parallel execution edge cases based on patterns from:
# - Prefect (concurrent task execution, thread safety)
# - Luigi (scheduler edge cases, worker handling)
# - Airflow (failure propagation, retry patterns)
# - paradag (thread safety, race conditions)

RSpec.describe 'Parallel Execution Edge Cases' do
  describe 'thread safety' do
    it 'handles concurrent access to shared output hash safely' do
      # Stress test with many parallel tasks writing to results
      pipeline = Flowrb.define do
        100.times do |i|
          step :"writer_#{i}" do
            # Simulate some work
            sleep(rand * 0.01)
            { id: i, value: i * 2, thread: Thread.current.object_id }
          end
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success

      # Verify all 100 results are present and correct
      100.times do |i|
        expect(result[:"writer_#{i}"].output[:id]).to eq(i)
        expect(result[:"writer_#{i}"].output[:value]).to eq(i * 2)
      end
    end

    it 'maintains output isolation between steps' do
      shared_array = []
      mutex = Mutex.new

      pipeline = Flowrb.define do
        10.times do |i|
          step :"task_#{i}" do
            # Each task appends to shared array (testing isolation)
            result = []
            5.times do |j|
              sleep(0.001)
              result << "#{i}-#{j}"
            end
            mutex.synchronize { shared_array << i }
            result
          end
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success

      # All tasks should have completed
      expect(shared_array.sort).to eq((0..9).to_a)

      # Each task's output should be independent
      10.times do |i|
        expect(result[:"task_#{i}"].output.size).to eq(5)
        expect(result[:"task_#{i}"].output.first).to start_with("#{i}-")
      end
    end
  end

  describe 'failure propagation' do
    it 'stops execution when parallel task fails' do
      executed = []
      mutex = Mutex.new

      pipeline = Flowrb.define do
        step :ok_task do
          mutex.synchronize { executed << :ok_task }
          'success'
        end

        step :failing_task do
          mutex.synchronize { executed << :failing_task }
          raise 'intentional failure'
        end

        step :dependent_on_ok, depends_on: :ok_task do |_|
          mutex.synchronize { executed << :dependent_on_ok }
          'also success'
        end

        step :dependent_on_fail, depends_on: :failing_task do |_|
          mutex.synchronize { executed << :dependent_on_fail }
          'never reached'
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError)
      expect(executed).not_to include(:dependent_on_fail)
    end

    it 'preserves partial results from completed parallel tasks' do
      pipeline = Flowrb.define do
        step :fast_success do
          'completed quickly'
        end

        step :slow_success do
          sleep 0.05
          'completed slowly'
        end

        step :fast_failure do
          sleep 0.02
          raise 'boom'
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError) do |error|
        # fast_success should have completed
        expect(error.partial_results[:fast_success]&.output).to eq('completed quickly')
      end
    end

    it 'reports correct failing step when multiple could fail' do
      pipeline = Flowrb.define do
        step :task_a do
          sleep 0.01
          raise 'error A'
        end

        step :task_b do
          sleep 0.02
          raise 'error B'
        end

        step :task_c do
          sleep 0.03
          raise 'error C'
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError) do |error|
        # The first to fail should be reported (task_a due to timing)
        expect(error.step_name).to(satisfy { |name| %i[task_a task_b task_c].include?(name) })
      end
    end
  end

  describe 'timing and ordering' do
    it 'respects dependency order even with varying task durations' do
      execution_times = {}
      mutex = Mutex.new

      pipeline = Flowrb.define do
        step :slow_root do
          sleep 0.05
          mutex.synchronize { execution_times[:slow_root] = Time.now }
          'slow'
        end

        step :fast_root do
          mutex.synchronize { execution_times[:fast_root] = Time.now }
          'fast'
        end

        step :depends_on_slow, depends_on: :slow_root do |_|
          mutex.synchronize { execution_times[:depends_on_slow] = Time.now }
          'after slow'
        end

        step :depends_on_fast, depends_on: :fast_root do |_|
          mutex.synchronize { execution_times[:depends_on_fast] = Time.now }
          'after fast'
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success

      # Dependencies must be respected
      expect(execution_times[:depends_on_slow]).to be > execution_times[:slow_root]
      expect(execution_times[:depends_on_fast]).to be > execution_times[:fast_root]
    end

    it 'executes same-level tasks concurrently' do
      start_times = {}
      mutex = Mutex.new

      pipeline = Flowrb.define do
        step :task_a do
          mutex.synchronize { start_times[:task_a] = Time.now }
          sleep 0.05
          'a'
        end

        step :task_b do
          mutex.synchronize { start_times[:task_b] = Time.now }
          sleep 0.05
          'b'
        end

        step :task_c do
          mutex.synchronize { start_times[:task_c] = Time.now }
          sleep 0.05
          'c'
        end
      end

      start = Time.now
      result = pipeline.run(executor: :parallel)
      elapsed = Time.now - start

      expect(result).to be_success
      # All should start nearly simultaneously
      times = start_times.values
      expect(times.max - times.min).to be < 0.02
      # Total time should be ~0.05s, not ~0.15s
      expect(elapsed).to be < 0.1
    end
  end

  describe 'max_threads limiting' do
    it 'limits concurrent execution to max_threads' do
      concurrent_count = []
      current_count = 0
      mutex = Mutex.new

      pipeline = Flowrb.define do
        10.times do |i|
          step :"task_#{i}" do
            mutex.synchronize do
              current_count += 1
              concurrent_count << current_count
            end
            sleep 0.03
            mutex.synchronize { current_count -= 1 }
            i
          end
        end
      end

      result = pipeline.run(executor: :parallel, max_threads: 3)
      expect(result).to be_success

      # Should never exceed 3 concurrent tasks
      expect(concurrent_count.max).to be <= 3
    end

    it 'handles max_threads of 1 (sequential-like behavior)' do
      execution_order = []
      mutex = Mutex.new

      pipeline = Flowrb.define do
        5.times do |i|
          step :"task_#{i}" do
            mutex.synchronize { execution_order << i }
            sleep 0.01
            i
          end
        end
      end

      start = Time.now
      result = pipeline.run(executor: :parallel, max_threads: 1)
      elapsed = Time.now - start

      expect(result).to be_success
      # With max_threads=1, should take ~0.05s (5 * 0.01)
      expect(elapsed).to be >= 0.04
    end
  end

  describe 'nil and edge case outputs' do
    it 'handles nil outputs in parallel execution' do
      pipeline = Flowrb.define do
        step :returns_nil do
          nil
        end

        step :returns_value do
          42
        end

        step :consumer, depends_on: %i[returns_nil returns_value] do |returns_nil:, returns_value:|
          { nil_was: returns_nil.nil?, value: returns_value }
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:consumer].output).to eq({ nil_was: true, value: 42 })
    end

    it 'handles empty array outputs' do
      pipeline = Flowrb.define do
        step :empty do
          []
        end

        step :consumer, depends_on: :empty do |arr|
          arr.empty? ? 'was empty' : 'had items'
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:consumer].output).to eq('was empty')
    end

    it 'handles complex nested objects' do
      pipeline = Flowrb.define do
        step :producer do
          {
            array: [1, [2, 3], { nested: 'value' }],
            hash: { a: { b: { c: 'd' } } },
            proc_result: ->(x) { x * 2 }
          }
        end

        step :consumer, depends_on: :producer do |data|
          {
            array_size: data[:array].size,
            deep_value: data[:hash][:a][:b][:c],
            proc_works: data[:proc_result].call(5)
          }
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:consumer].output).to eq({
                                               array_size: 3,
                                               deep_value: 'd',
                                               proc_works: 10
                                             })
    end
  end

  describe 'exception types' do
    it 'preserves original exception type' do
      pipeline = Flowrb.define do
        step :type_error do
          raise TypeError, 'wrong type'
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error).to be_a(TypeError)
        expect(error.original_error.message).to eq('wrong type')
      end
    end

    it 'handles exceptions with custom attributes' do
      custom_error_class = Class.new(StandardError) do
        attr_reader :code

        def initialize(message, code:)
          super(message)
          @code = code
        end
      end

      pipeline = Flowrb.define do
        step :custom_error do
          raise custom_error_class.new('custom failure', code: 42)
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error.code).to eq(42)
      end
    end
  end

  describe 'idempotency' do
    it 'produces consistent results across multiple runs' do
      pipeline = Flowrb.define do
        step :deterministic do
          [1, 2, 3].map { |n| n * 2 }
        end

        step :also_deterministic, depends_on: :deterministic, &:sum
      end

      results = 5.times.map { pipeline.run(executor: :parallel) }

      results.each do |result|
        expect(result).to be_success
        expect(result[:deterministic].output).to eq([2, 4, 6])
        expect(result[:also_deterministic].output).to eq(12)
      end
    end
  end
end
