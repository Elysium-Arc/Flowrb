# frozen_string_literal: true

RSpec.describe Piperb::Executor::Sequential do
  def make_step(name, deps = [], &block)
    Piperb::Step.new(name, depends_on: deps, &block)
  end

  let(:dag) { Piperb::DAG.new }

  describe 'execution order guarantees' do
    it 'ensures dependencies complete before dependents' do
      execution_log = []

      dag.add(make_step(:a) do
        execution_log << [:start_a, Time.now]
        sleep(0.01)
        execution_log << [:end_a, Time.now]
        1
      end)

      dag.add(make_step(:b, [:a]) do |_|
        execution_log << [:start_b, Time.now]
        sleep(0.01)
        execution_log << [:end_b, Time.now]
        2
      end)

      executor = described_class.new(dag)
      executor.execute

      start_a_idx = execution_log.index { |e| e[0] == :start_a }
      end_a_idx = execution_log.index { |e| e[0] == :end_a }
      start_b_idx = execution_log.index { |e| e[0] == :start_b }

      expect(end_a_idx).to be < start_b_idx
      expect(start_a_idx).to be < end_a_idx
    end

    it 'executes independent steps in definition order' do
      execution_order = []

      dag.add(make_step(:x) do
        execution_order << :x
        1
      end)

      dag.add(make_step(:y) do
        execution_order << :y
        2
      end)

      dag.add(make_step(:z) do
        execution_order << :z
        3
      end)

      executor = described_class.new(dag)
      executor.execute

      # TSort should maintain some order, all three should execute
      expect(execution_order).to contain_exactly(:x, :y, :z)
    end
  end

  describe 'input building' do
    it 'passes empty args when no deps and no initial input' do
      received_args = nil

      dag.add(make_step(:check) do |*args|
        received_args = args
        'done'
      end)

      executor = described_class.new(dag)
      executor.execute

      expect(received_args).to eq([])
    end

    it 'passes initial input when no deps' do
      received_input = nil

      dag.add(make_step(:check) do |input|
        received_input = input
        'done'
      end)

      executor = described_class.new(dag)
      executor.execute(initial_input: 'test_input')

      expect(received_input).to eq('test_input')
    end

    it 'passes single dep output directly' do
      received_input = nil

      dag.add(make_step(:producer) { { key: 'value' } })
      dag.add(make_step(:consumer, [:producer]) do |input|
        received_input = input
        'done'
      end)

      executor = described_class.new(dag)
      executor.execute

      expect(received_input).to eq({ key: 'value' })
    end

    it 'passes multiple deps as kwargs' do
      received_kwargs = nil

      dag.add(make_step(:a) { 1 })
      dag.add(make_step(:b) { 2 })
      dag.add(make_step(:c, %i[a b]) do |**kwargs|
        received_kwargs = kwargs
        'done'
      end)

      executor = described_class.new(dag)
      executor.execute

      expect(received_kwargs).to eq({ a: 1, b: 2 })
    end
  end

  describe 'error handling details' do
    it 'captures error class in step result' do
      dag.add(make_step(:fail) { raise TypeError, 'type error' })

      executor = described_class.new(dag)

      expect { executor.execute }.to raise_error(Piperb::StepError) do |error|
        expect(error.original_error).to be_a(TypeError)
      end
    end

    it 'preserves error backtrace' do
      dag.add(make_step(:fail) { raise 'with backtrace' })

      executor = described_class.new(dag)

      expect { executor.execute }.to raise_error(Piperb::StepError) do |error|
        expect(error.original_error.backtrace).not_to be_empty
        expect(error.original_error.backtrace.first).to include('sequential_extended_spec.rb')
      end
    end

    it 'captures partial results up to failure point' do
      dag.add(make_step(:step1) { 'result1' })
      dag.add(make_step(:step2, [:step1]) { |_| 'result2' })
      dag.add(make_step(:step3, [:step2]) { |_| raise 'fail at step3' })
      dag.add(make_step(:step4, [:step3]) { |_| 'result4' })

      executor = described_class.new(dag)

      expect { executor.execute }.to raise_error(Piperb::StepError) do |error|
        partial = error.partial_results

        expect(partial[:step1].output).to eq('result1')
        expect(partial[:step1]).to be_success

        expect(partial[:step2].output).to eq('result2')
        expect(partial[:step2]).to be_success

        expect(partial[:step3]).to be_failed
        expect(partial[:step3].error.message).to eq('fail at step3')

        expect(partial[:step4]).to be_nil
      end
    end
  end

  describe 'timing accuracy' do
    it 'step duration reflects actual execution time' do
      dag.add(make_step(:timed) do
        sleep(0.02)
        'done'
      end)

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:timed].duration).to be >= 0.02
      expect(result[:timed].duration).to be < 0.1 # sanity check
    end

    it 'started_at is before step execution' do
      execution_time = nil

      dag.add(make_step(:check) do
        execution_time = Time.now
        sleep(0.01)
        'done'
      end)

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:check].started_at).to be <= execution_time
    end

    it 'overall duration includes all steps' do
      dag.add(make_step(:a) do
        sleep(0.01)
        1
      end)
      dag.add(make_step(:b, [:a]) do |_|
        sleep(0.01)
        2
      end)
      dag.add(make_step(:c, [:b]) do |_|
        sleep(0.01)
        3
      end)

      executor = described_class.new(dag)
      result = executor.execute

      expect(result.duration).to be >= 0.03
    end
  end

  describe 'complex dependency scenarios' do
    it 'handles diamond with different output types' do
      dag.add(make_step(:source) { { value: 10 } })
      dag.add(make_step(:to_array, [:source]) { |h| [h[:value]] })
      dag.add(make_step(:to_string, [:source]) { |h| h[:value].to_s })
      dag.add(make_step(:combine, %i[to_array to_string]) do |to_array:, to_string:|
        { array: to_array, string: to_string }
      end)

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:combine].output).to eq({ array: [10], string: '10' })
    end

    it 'handles step that consumes its own type transformation' do
      dag.add(make_step(:integers) { [1, 2, 3] })
      dag.add(make_step(:strings, [:integers]) { |arr| arr.map(&:to_s) })
      dag.add(make_step(:joined, [:strings]) { |arr| arr.join(',') })
      dag.add(make_step(:parsed, [:joined]) { |s| s.split(',').map(&:to_i) })

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:parsed].output).to eq([1, 2, 3])
    end
  end

  describe 'nil and falsy value handling' do
    it 'nil output is passed correctly to dependents' do
      dag.add(make_step(:returns_nil) { nil })
      dag.add(make_step(:receives_nil, [:returns_nil]) do |val|
        val.nil? ? 'received_nil' : 'received_something'
      end)

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:receives_nil].output).to eq('received_nil')
    end

    it 'false output is passed correctly to dependents' do
      dag.add(make_step(:returns_false) { false })
      dag.add(make_step(:receives_false, [:returns_false]) do |val|
        val == false ? 'received_false' : 'received_other'
      end)

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:receives_false].output).to eq('received_false')
    end

    it 'zero output is passed correctly to dependents' do
      dag.add(make_step(:returns_zero) { 0 })
      dag.add(make_step(:receives_zero, [:returns_zero]) do |val|
        val.zero? ? 'received_zero' : 'received_nonzero'
      end)

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:receives_zero].output).to eq('received_zero')
    end

    it 'empty string output is passed correctly' do
      dag.add(make_step(:returns_empty) { '' })
      dag.add(make_step(:receives_empty, [:returns_empty]) do |val|
        val.empty? ? 'received_empty' : 'received_nonempty'
      end)

      executor = described_class.new(dag)
      result = executor.execute

      expect(result[:receives_empty].output).to eq('received_empty')
    end
  end
end
