# frozen_string_literal: true

RSpec.describe 'Parallel Execution' do
  describe 'pipeline with executor option' do
    it 'runs with sequential executor by default' do
      pipeline = Flowrb.define do
        step :a do
          1
        end

        step :b, depends_on: :a do |n|
          n + 1
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:b].output).to eq(2)
    end

    it 'runs with parallel executor when specified' do
      pipeline = Flowrb.define do
        step :a do
          1
        end

        step :b, depends_on: :a do |n|
          n + 1
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:b].output).to eq(2)
    end

    it 'runs independent steps in parallel' do
      execution_times = {}
      mutex = Mutex.new

      pipeline = Flowrb.define do
        step :slow1 do
          start = Time.now
          sleep 0.1
          mutex.synchronize { execution_times[:slow1] = start }
          'slow1'
        end

        step :slow2 do
          start = Time.now
          sleep 0.1
          mutex.synchronize { execution_times[:slow2] = start }
          'slow2'
        end

        step :combine, depends_on: %i[slow1 slow2] do |slow1:, slow2:|
          "#{slow1}-#{slow2}"
        end
      end

      start_time = Time.now
      result = pipeline.run(executor: :parallel)
      elapsed = Time.now - start_time

      expect(result).to be_success
      expect(result[:combine].output).to eq('slow1-slow2')
      # Parallel should take ~0.1s, sequential would take ~0.2s
      expect(elapsed).to be < 0.18
      # Both slow steps should have started around the same time
      expect((execution_times[:slow1] - execution_times[:slow2]).abs).to be < 0.05
    end

    it 'respects max_threads option' do
      pipeline = Flowrb.define do
        5.times do |i|
          step :"step_#{i}" do
            sleep 0.05
            i
          end
        end
      end

      # With max_threads: 1, should run sequentially
      start = Time.now
      result = pipeline.run(executor: :parallel, max_threads: 1)
      elapsed = Time.now - start

      expect(result).to be_success
      # Sequential would take ~0.25s (5 * 0.05)
      expect(elapsed).to be >= 0.2
    end
  end

  describe 'error handling in parallel execution' do
    it 'raises StepError when a parallel step fails' do
      pipeline = Flowrb.define do
        step :ok do
          'success'
        end

        step :fail do
          raise 'parallel failure'
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError) do |error|
        expect(error.step_name).to eq(:fail)
        expect(error.original_error.message).to eq('parallel failure')
      end
    end

    it 'stops subsequent levels after failure' do
      executed = []
      mutex = Mutex.new

      pipeline = Flowrb.define do
        step :a do
          mutex.synchronize { executed << :a }
          'a'
        end

        step :b, depends_on: :a do
          mutex.synchronize { executed << :b }
          raise 'fail'
        end

        step :c, depends_on: :b do
          mutex.synchronize { executed << :c }
          'c'
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError)
      expect(executed).not_to include(:c)
    end

    it 'preserves partial results on failure' do
      pipeline = Flowrb.define do
        step :ok do
          'completed'
        end

        step :fail, depends_on: :ok do
          raise 'boom'
        end
      end

      expect { pipeline.run(executor: :parallel) }.to raise_error(Flowrb::StepError) do |error|
        expect(error.partial_results[:ok].output).to eq('completed')
      end
    end
  end

  describe 'real-world parallel scenario' do
    it 'processes data with parallel transformations' do
      pipeline = Flowrb.define do
        step :fetch_data do
          { users: [1, 2, 3], orders: [10, 20, 30] }
        end

        # These two can run in parallel
        step :process_users, depends_on: :fetch_data do |data|
          sleep 0.05
          data[:users].map { |id| "user_#{id}" }
        end

        step :process_orders, depends_on: :fetch_data do |data|
          sleep 0.05
          data[:orders].map { |id| "order_#{id}" }
        end

        step :generate_report, depends_on: %i[process_users process_orders] do |process_users:, process_orders:|
          {
            user_count: process_users.size,
            order_count: process_orders.size,
            summary: "#{process_users.size} users, #{process_orders.size} orders"
          }
        end
      end

      start = Time.now
      result = pipeline.run(executor: :parallel)
      elapsed = Time.now - start

      expect(result).to be_success
      expect(result[:generate_report].output[:summary]).to eq('3 users, 3 orders')
      # Parallel processing should take ~0.05s not ~0.1s
      expect(elapsed).to be < 0.09
    end

    it 'handles complex multi-level parallel execution' do
      pipeline = Flowrb.define do
        # Level 0: roots
        step :fetch_a do
          sleep 0.02
          'a'
        end

        step :fetch_b do
          sleep 0.02
          'b'
        end

        step :fetch_c do
          sleep 0.02
          'c'
        end

        # Level 1: depend on roots
        step :process_ab, depends_on: %i[fetch_a fetch_b] do |fetch_a:, fetch_b:|
          sleep 0.02
          "#{fetch_a}#{fetch_b}"
        end

        step :process_bc, depends_on: %i[fetch_b fetch_c] do |fetch_b:, fetch_c:|
          sleep 0.02
          "#{fetch_b}#{fetch_c}"
        end

        # Level 2: final merge
        step :merge, depends_on: %i[process_ab process_bc] do |process_ab:, process_bc:|
          "#{process_ab}-#{process_bc}"
        end
      end

      start = Time.now
      result = pipeline.run(executor: :parallel)
      elapsed = Time.now - start

      expect(result).to be_success
      expect(result[:merge].output).to eq('ab-bc')
      # 3 levels * ~0.02s each = ~0.06s parallel vs ~0.12s sequential
      expect(elapsed).to be < 0.1
    end
  end

  describe 'thread safety' do
    it 'handles many parallel steps safely' do
      pipeline = Flowrb.define do
        100.times do |i|
          step :"step_#{i}" do
            i * 2
          end
        end

        step :sum, depends_on: (0...100).map { |i| :"step_#{i}" } do |**results|
          results.values.sum
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      # Sum of 0*2 + 1*2 + ... + 99*2 = 2 * (0+1+...+99) = 2 * 4950 = 9900
      expect(result[:sum].output).to eq(9900)
    end
  end
end
