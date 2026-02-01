# frozen_string_literal: true

RSpec.describe Flowrb::Executor::Parallel do
  let(:dag) { Flowrb::DAG.new }
  let(:executor) { described_class.new(dag) }

  def make_step(name, deps = [], &block)
    block ||= proc { "result_#{name}" }
    Flowrb::Step.new(name, depends_on: deps, &block)
  end

  describe '#execute' do
    it 'executes empty DAG successfully' do
      result = executor.execute
      expect(result).to be_success
      expect(result.outputs).to eq({})
    end

    it 'executes single step' do
      dag.add(make_step(:only) { 42 })

      result = executor.execute
      expect(result).to be_success
      expect(result[:only].output).to eq(42)
    end

    it 'executes steps in correct dependency order' do
      execution_order = []
      mutex = Mutex.new

      dag.add(make_step(:a) do
        mutex.synchronize { execution_order << :a }
        1
      end)

      dag.add(make_step(:b, [:a]) do |n|
        mutex.synchronize { execution_order << :b }
        n + 1
      end)

      dag.add(make_step(:c, [:b]) do |n|
        mutex.synchronize { execution_order << :c }
        n + 1
      end)

      result = executor.execute
      expect(result).to be_success
      expect(result[:c].output).to eq(3)
      expect(execution_order).to eq(%i[a b c])
    end

    it 'executes independent steps in parallel' do
      # Use timing to verify parallel execution
      dag.add(make_step(:slow1) do
        sleep 0.1
        'slow1'
      end)

      dag.add(make_step(:slow2) do
        sleep 0.1
        'slow2'
      end)

      dag.add(make_step(:combine, %i[slow1 slow2]) do |slow1:, slow2:|
        "#{slow1}-#{slow2}"
      end)

      start_time = Time.now
      result = executor.execute
      elapsed = Time.now - start_time

      expect(result).to be_success
      expect(result[:combine].output).to eq('slow1-slow2')
      # If parallel, should take ~0.1s. If sequential, ~0.2s
      expect(elapsed).to be < 0.18
    end

    it 'passes initial_input to root steps' do
      dag.add(make_step(:root) { |n| n * 2 })

      result = executor.execute(initial_input: 5)
      expect(result[:root].output).to eq(10)
    end

    it 'passes output from single dependency' do
      dag.add(make_step(:source) { 10 })
      dag.add(make_step(:sink, [:source]) { |n| n * 2 })

      result = executor.execute
      expect(result[:sink].output).to eq(20)
    end

    it 'passes outputs from multiple dependencies as kwargs' do
      dag.add(make_step(:a) { 1 })
      dag.add(make_step(:b) { 2 })
      dag.add(make_step(:c, %i[a b]) { |a:, b:| a + b })

      result = executor.execute
      expect(result[:c].output).to eq(3)
    end

    context 'with errors' do
      it 'raises StepError when step fails' do
        dag.add(make_step(:fail) { raise 'boom' })

        expect { executor.execute }.to raise_error(Flowrb::StepError) do |error|
          expect(error.step_name).to eq(:fail)
          expect(error.original_error.message).to eq('boom')
        end
      end

      it 'includes partial results in StepError' do
        dag.add(make_step(:ok) { 'success' })
        dag.add(make_step(:fail, [:ok]) { raise 'boom' })

        expect { executor.execute }.to raise_error(Flowrb::StepError) do |error|
          expect(error.partial_results[:ok].output).to eq('success')
        end
      end

      it 'stops execution when step fails' do
        executed = []
        mutex = Mutex.new

        dag.add(make_step(:a) do
          mutex.synchronize { executed << :a }
          'a'
        end)

        dag.add(make_step(:b, [:a]) do
          mutex.synchronize { executed << :b }
          raise 'boom'
        end)

        dag.add(make_step(:c, [:b]) do
          mutex.synchronize { executed << :c }
          'c'
        end)

        expect { executor.execute }.to raise_error(Flowrb::StepError)
        expect(executed).not_to include(:c)
      end
    end

    context 'with max_threads limit' do
      it 'respects max_threads parameter' do
        executor_limited = described_class.new(dag, max_threads: 1)
        execution_times = {}
        mutex = Mutex.new

        5.times do |i|
          dag.add(make_step(:"step_#{i}") do
            mutex.synchronize { execution_times[:"step_#{i}"] = Time.now }
            sleep 0.05
            i
          end)
        end

        start = Time.now
        result = executor_limited.execute
        elapsed = Time.now - start

        expect(result).to be_success
        # With max_threads: 1, should take ~0.25s (5 * 0.05)
        # Without limit would be ~0.05s
        expect(elapsed).to be >= 0.2
      end
    end

    context 'with diamond dependency pattern' do
      it 'handles diamond correctly' do
        dag.add(make_step(:source) { 1 })
        dag.add(make_step(:left, [:source]) { |n| n * 2 })
        dag.add(make_step(:right, [:source]) { |n| n * 3 })
        dag.add(make_step(:sink, %i[left right]) { |left:, right:| left + right })

        result = executor.execute
        expect(result[:sink].output).to eq(5) # (1*2) + (1*3)
      end
    end

    context 'with result timing' do
      it 'records started_at and finished_at' do
        dag.add(make_step(:only) { 1 })

        result = executor.execute
        expect(result.started_at).to be_a(Time)
        expect(result.finished_at).to be_a(Time)
        expect(result.finished_at).to be >= result.started_at
      end

      it 'records step timing' do
        dag.add(make_step(:slow) do
          sleep 0.05
          'done'
        end)

        result = executor.execute
        expect(result[:slow].duration).to be >= 0.05
        expect(result[:slow].started_at).to be_a(Time)
      end
    end
  end
end
