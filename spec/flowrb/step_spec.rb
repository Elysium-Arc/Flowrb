# frozen_string_literal: true

RSpec.describe Flowrb::Step do
  describe '#initialize' do
    it 'creates a step with a block' do
      step = described_class.new(:fetch) { 'result' }
      expect(step.name).to eq(:fetch)
      expect(step.dependencies).to eq([])
    end

    it 'creates a step with a callable' do
      callable = ->(x) { x * 2 }
      step = described_class.new(:double, callable: callable)
      expect(step.callable).to eq(callable)
    end

    it 'creates a step with an object responding to #call' do
      processor = Class.new do
        def call(input)
          input.upcase
        end
      end.new

      step = described_class.new(:process, callable: processor)
      expect(step.call('hello')).to eq('HELLO')
    end

    it 'converts name to symbol' do
      step = described_class.new('fetch') { 'result' }
      expect(step.name).to eq(:fetch)
    end

    it 'normalizes single dependency to array' do
      step = described_class.new(:process, depends_on: :fetch) { 'result' }
      expect(step.dependencies).to eq([:fetch])
    end

    it 'normalizes multiple dependencies' do
      step = described_class.new(:process, depends_on: %i[a b c]) { 'result' }
      expect(step.dependencies).to eq(%i[a b c])
    end

    it 'converts string dependencies to symbols' do
      step = described_class.new(:process, depends_on: %w[a b]) { 'result' }
      expect(step.dependencies).to eq(%i[a b])
    end

    it 'freezes the step after creation' do
      step = described_class.new(:fetch) { 'result' }
      expect(step).to be_frozen
    end

    it 'freezes dependencies' do
      step = described_class.new(:process, depends_on: [:a]) { 'result' }
      expect(step.dependencies).to be_frozen
    end

    it 'freezes options' do
      step = described_class.new(:fetch, timeout: 30) { 'result' }
      expect(step.options).to be_frozen
    end

    it 'raises ArgumentError when no callable provided' do
      expect { described_class.new(:fetch) }.to raise_error(
        ArgumentError,
        /must have a callable/
      )
    end

    it "raises ArgumentError when callable doesn't respond to #call" do
      expect { described_class.new(:fetch, callable: 'not callable') }.to raise_error(
        ArgumentError,
        /must respond to #call/
      )
    end
  end

  describe '#call' do
    it 'executes the block with no arguments' do
      step = described_class.new(:fetch) { 42 }
      expect(step.call).to eq(42)
    end

    it 'executes the block with positional arguments' do
      step = described_class.new(:double) { |x| x * 2 }
      expect(step.call(5)).to eq(10)
    end

    it 'executes the block with keyword arguments' do
      step = described_class.new(:combine) { |a:, b:| a + b }
      expect(step.call(a: 1, b: 2)).to eq(3)
    end

    it 'executes the block with mixed arguments' do
      step = described_class.new(:process) { |x, multiplier:| x * multiplier }
      expect(step.call(5, multiplier: 3)).to eq(15)
    end
  end

  describe '#to_s' do
    it 'returns a readable string representation' do
      step = described_class.new(:fetch) { 'result' }
      expect(step.to_s).to eq('Step(fetch)')
    end
  end

  describe '#inspect' do
    it 'returns detailed inspection' do
      step = described_class.new(:process, depends_on: [:fetch]) { 'result' }
      expect(step.inspect).to eq('#<Flowrb::Step name=:process dependencies=[:fetch]>')
    end
  end

  describe 'options' do
    it 'stores custom options' do
      step = described_class.new(:fetch, timeout: 30, retries: 3) { 'result' }
      expect(step.options).to eq({ timeout: 30, retries: 3 })
    end
  end
end
