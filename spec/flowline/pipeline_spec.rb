# frozen_string_literal: true

RSpec.describe Flowline::Pipeline do
  describe '#initialize' do
    it 'creates an empty pipeline' do
      pipeline = described_class.new
      expect(pipeline).to be_empty
    end

    it 'accepts a block for DSL' do
      pipeline = described_class.new do
        step :fetch do
          [1, 2, 3]
        end
      end

      expect(pipeline.size).to eq(1)
    end
  end

  describe '#step' do
    it 'adds a step to the pipeline' do
      pipeline = described_class.new
      pipeline.step(:fetch) { 'result' }
      expect(pipeline[:fetch]).not_to be_nil
    end

    it 'returns self for chaining' do
      pipeline = described_class.new
      result = pipeline.step(:fetch) { 'result' }
      expect(result).to eq(pipeline)
    end

    it 'accepts dependencies' do
      pipeline = described_class.new do
        step :a do
          1
        end
        step :b, depends_on: :a do |x|
          x + 1
        end
      end

      expect(pipeline[:b].dependencies).to eq([:a])
    end

    it 'accepts multiple dependencies' do
      pipeline = described_class.new do
        step :a do
          1
        end
        step :b do
          2
        end
        step :c, depends_on: %i[a b] do |a:, b:|
          a + b
        end
      end

      expect(pipeline[:c].dependencies).to eq(%i[a b])
    end
  end

  describe '#run' do
    it 'executes a simple pipeline' do
      pipeline = described_class.new do
        step :fetch do
          [1, 2, 3]
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:fetch].output).to eq([1, 2, 3])
    end

    it 'passes output to dependent steps' do
      pipeline = described_class.new do
        step :fetch do
          [1, 2, 3]
        end
        step :double, depends_on: :fetch do |data|
          data.map { |n| n * 2 }
        end
      end

      result = pipeline.run
      expect(result[:double].output).to eq([2, 4, 6])
    end

    it 'passes initial_input to root steps' do
      pipeline = described_class.new do
        step :process, &:upcase
      end

      result = pipeline.run(initial_input: 'hello')
      expect(result[:process].output).to eq('HELLO')
    end

    it 'returns empty success for empty pipeline' do
      pipeline = described_class.new
      result = pipeline.run
      expect(result).to be_success
      expect(result.completed_steps).to be_empty
    end
  end

  describe '#validate!' do
    it 'validates the pipeline' do
      pipeline = described_class.new do
        step :a do
          1
        end
        step :b, depends_on: :a do |x|
          x + 1
        end
      end

      expect(pipeline.validate!).to be true
    end

    it 'raises CycleError for circular dependencies' do
      pipeline = described_class.new do
        step :a, depends_on: :b do
          1
        end
        step :b, depends_on: :a do
          2
        end
      end

      expect { pipeline.validate! }.to raise_error(Flowline::CycleError)
    end

    it 'raises MissingDependencyError for unknown dependencies' do
      pipeline = described_class.new do
        step :process, depends_on: :unknown do |x|
          x
        end
      end

      expect { pipeline.validate! }.to raise_error(Flowline::MissingDependencyError)
    end
  end

  describe '#to_mermaid' do
    it 'generates mermaid diagram' do
      pipeline = described_class.new do
        step :a do
          1
        end
        step :b, depends_on: :a do |x|
          x + 1
        end
      end

      mermaid = pipeline.to_mermaid
      expect(mermaid).to include('graph TD')
      expect(mermaid).to include('a --> b')
    end
  end

  describe '#steps' do
    it 'returns all steps' do
      pipeline = described_class.new do
        step :a do
          1
        end
        step :b do
          2
        end
      end

      expect(pipeline.steps.map(&:name)).to contain_exactly(:a, :b)
    end
  end

  describe '#[]' do
    it 'accesses steps by name' do
      pipeline = described_class.new do
        step :fetch do
          [1, 2, 3]
        end
      end

      expect(pipeline[:fetch].name).to eq(:fetch)
    end
  end

  describe '#empty?' do
    it 'returns true for empty pipeline' do
      expect(described_class.new).to be_empty
    end

    it 'returns false for non-empty pipeline' do
      pipeline = described_class.new do
        step :a do
          1
        end
      end
      expect(pipeline).not_to be_empty
    end
  end

  describe '#size' do
    it 'returns the number of steps' do
      pipeline = described_class.new do
        step :a do
          1
        end
        step :b do
          2
        end
      end
      expect(pipeline.size).to eq(2)
    end
  end
end

RSpec.describe Flowline do
  describe '.define' do
    it 'creates a pipeline' do
      pipeline = described_class.define do
        step :fetch do
          [1, 2, 3]
        end
      end

      expect(pipeline).to be_a(Flowline::Pipeline)
      expect(pipeline[:fetch]).not_to be_nil
    end
  end
end
