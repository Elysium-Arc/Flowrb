# frozen_string_literal: true

RSpec.describe Flowrb::Executor::Sequential do
  def make_step(name, deps = [], &block)
    Flowrb::Step.new(name, depends_on: deps, &block)
  end

  let(:dag) { Flowrb::DAG.new }

  describe '#execute' do
    it 'executes steps in topological order' do
      order = []
      dag.add(make_step(:a) do
        order << :a
        1
      end)
      dag.add(make_step(:b, [:a]) do |_|
        order << :b
        2
      end)
      dag.add(make_step(:c, [:b]) do |_|
        order << :c
        3
      end)

      executor = described_class.new(dag)
      executor.execute

      expect(order).to eq(%i[a b c])
    end

    it 'passes output to single dependent' do
      dag.add(make_step(:fetch) { [1, 2, 3] })
      dag.add(make_step(:double, [:fetch]) { |data| data.map { |n| n * 2 } })

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:double].output).to eq([2, 4, 6])
    end

    it 'passes outputs as kwargs to multiple dependents' do
      dag.add(make_step(:a) { 10 })
      dag.add(make_step(:b) { 20 })
      dag.add(make_step(:c, %i[a b]) { |a:, b:| a + b })

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:c].output).to eq(30)
    end

    it 'passes initial_input to root steps' do
      dag.add(make_step(:process, &:upcase))

      executor = described_class.new(dag)
      result = executor.execute(initial_input: 'hello')

      expect(result[:process].output).to eq('HELLO')
    end

    it 'handles steps with no input' do
      dag.add(make_step(:fetch) { 42 })

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:fetch].output).to eq(42)
    end

    it 'handles nil output' do
      dag.add(make_step(:a) { nil })
      dag.add(make_step(:b, [:a]) { |x| x.nil? ? 'was nil' : 'was not nil' })

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:b].output).to eq('was nil')
    end

    it 'records timing for each step' do
      dag.add(make_step(:slow) do
        sleep(0.01)
        42
      end)

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:slow].duration).to be >= 0.01
      expect(result[:slow].started_at).to be_a(Time)
    end

    it 'records overall timing' do
      dag.add(make_step(:a) { 1 })

      executor = described_class.new(dag)
      result = executor.execute

      expect(result.started_at).to be_a(Time)
      expect(result.finished_at).to be_a(Time)
      expect(result.duration).to be >= 0
    end

    it 'returns empty success for empty DAG' do
      executor = described_class.new(dag)
      result = executor.execute

      expect(result).to be_success
      expect(result.completed_steps).to be_empty
    end

    context 'with diamond dependency' do
      before do
        dag.add(make_step(:a) { 1 })
        dag.add(make_step(:b, [:a]) { |x| x + 10 })
        dag.add(make_step(:c, [:a]) { |x| x + 100 })
        dag.add(make_step(:d, %i[b c]) { |b:, c:| b + c })
      end

      it 'handles diamond dependencies correctly' do
        executor = described_class.new(dag)
        result = executor.execute

        expect(result[:a].output).to eq(1)
        expect(result[:b].output).to eq(11)
        expect(result[:c].output).to eq(101)
        expect(result[:d].output).to eq(112)
      end
    end

    context 'with errors' do
      it 'raises StepError when step fails' do
        dag.add(make_step(:fail) { raise 'boom' })

        executor = described_class.new(dag)

        expect { executor.execute }.to raise_error(Flowrb::StepError) do |error|
          expect(error.step_name).to eq(:fail)
          expect(error.original_error.message).to eq('boom')
        end
      end

      it 'includes partial results in StepError' do
        dag.add(make_step(:a) { 1 })
        dag.add(make_step(:b, [:a]) { |_| raise 'boom' })
        dag.add(make_step(:c, [:b]) { |x| x + 1 })

        executor = described_class.new(dag)

        expect { executor.execute }.to raise_error(Flowrb::StepError) do |error|
          expect(error.partial_results[:a].output).to eq(1)
          expect(error.partial_results[:b]).to be_failed
        end
      end

      it 'stops execution after first failure' do
        executed = []
        dag.add(make_step(:a) do
          executed << :a
          1
        end)
        dag.add(make_step(:b, [:a]) do |_|
          executed << :b
          raise 'boom'
        end)
        dag.add(make_step(:c, [:b]) do |x|
          executed << :c
          x
        end)

        executor = described_class.new(dag)

        expect { executor.execute }.to raise_error(Flowrb::StepError)
        expect(executed).to eq(%i[a b])
      end

      it 'validates DAG before execution' do
        dag.add(make_step(:a, [:missing]) { 1 })

        executor = described_class.new(dag)

        expect { executor.execute }.to raise_error(Flowrb::MissingDependencyError)
      end
    end
  end
end

RSpec.describe Flowrb::Executor::Base do
  describe '#execute' do
    it 'raises NotImplementedError' do
      dag = Flowrb::DAG.new
      executor = described_class.new(dag)

      expect { executor.execute }.to raise_error(NotImplementedError)
    end
  end
end
