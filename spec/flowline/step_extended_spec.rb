# frozen_string_literal: true

RSpec.describe Flowline::Step do
  describe 'edge cases' do
    it 'handles empty dependencies array' do
      step = described_class.new(:fetch, depends_on: []) { 'result' }
      expect(step.dependencies).to eq([])
    end

    it 'handles nil dependencies (treats as empty)' do
      step = described_class.new(:fetch, depends_on: nil) { 'result' }
      expect(step.dependencies).to eq([])
    end

    it 'handles mixed string and symbol dependencies' do
      step = described_class.new(:process, depends_on: ['a', :b, 'c']) { 'result' }
      expect(step.dependencies).to eq(%i[a b c])
    end

    it 'preserves dependency order' do
      step = described_class.new(:process, depends_on: %i[z a m b]) { 'result' }
      expect(step.dependencies).to eq(%i[z a m b])
    end

    it 'allows numeric-like step names' do
      step = described_class.new('step_1') { 'result' }
      expect(step.name).to eq(:step_1)
    end

    it 'allows underscore-only names' do
      step = described_class.new(:_) { 'result' }
      expect(step.name).to eq(:_)
    end
  end

  describe 'callable types' do
    it 'works with Proc' do
      proc = proc(&:upcase)
      step = described_class.new(:process, callable: proc)
      expect(step.call('hello')).to eq('HELLO')
    end

    it 'works with lambda' do
      lam = lambda(&:reverse)
      step = described_class.new(:process, callable: lam)
      expect(step.call('hello')).to eq('olleh')
    end

    it 'works with Method object' do
      def self.my_method(x)
        x * 2
      end
      step = described_class.new(:process, callable: method(:my_method))
      expect(step.call(5)).to eq(10)
    end

    it 'works with custom callable class' do
      callable_class = Class.new do
        def initialize(multiplier)
          @multiplier = multiplier
        end

        def call(value)
          value * @multiplier
        end
      end

      step = described_class.new(:process, callable: callable_class.new(3))
      expect(step.call(7)).to eq(21)
    end

    it 'uses callable option over block when both provided' do
      # When both are provided, callable option takes precedence
      step = described_class.new(:process, callable: ->(x) { "callable: #{x}" }) { 'block' }
      expect(step.call('test')).to eq('callable: test')
    end
  end

  describe 'return value handling' do
    it 'returns nil from step' do
      step = described_class.new(:fetch) { nil }
      expect(step.call).to be_nil
    end

    it 'returns false from step' do
      step = described_class.new(:check) { false }
      expect(step.call).to be false
    end

    it 'returns complex objects' do
      step = described_class.new(:fetch) { { nested: { data: [1, 2, 3] } } }
      expect(step.call).to eq({ nested: { data: [1, 2, 3] } })
    end

    it 'returns arrays' do
      step = described_class.new(:fetch) { [1, [2, 3], { a: 4 }] }
      expect(step.call).to eq([1, [2, 3], { a: 4 }])
    end
  end

  describe 'error propagation' do
    it 'propagates StandardError' do
      step = described_class.new(:fail) { raise StandardError, 'boom' }
      expect { step.call }.to raise_error(StandardError, 'boom')
    end

    it 'propagates custom errors' do
      custom_error = Class.new(StandardError)
      step = described_class.new(:fail) { raise custom_error, 'custom' }
      expect { step.call }.to raise_error(custom_error, 'custom')
    end

    it 'propagates ArgumentError' do
      step = described_class.new(:fail) { raise ArgumentError, 'bad arg' }
      expect { step.call }.to raise_error(ArgumentError, 'bad arg')
    end

    it 'propagates RuntimeError' do
      step = described_class.new(:fail) { raise 'runtime' }
      expect { step.call }.to raise_error(RuntimeError, 'runtime')
    end
  end

  describe 'immutability' do
    it 'cannot modify name after creation' do
      step = described_class.new(:fetch) { 'result' }
      expect { step.instance_variable_set(:@name, :other) }.to raise_error(FrozenError)
    end

    it 'cannot modify dependencies array' do
      step = described_class.new(:process, depends_on: [:a]) { 'result' }
      expect { step.dependencies << :b }.to raise_error(FrozenError)
    end

    it 'cannot modify options hash' do
      step = described_class.new(:fetch, timeout: 30) { 'result' }
      expect { step.options[:timeout] = 60 }.to raise_error(FrozenError)
    end
  end

  describe 'options handling' do
    it 'handles empty options' do
      step = described_class.new(:fetch) { 'result' }
      expect(step.options).to eq({})
    end

    it 'handles multiple custom options' do
      step = described_class.new(:fetch, timeout: 30, retries: 3, cache: true) { 'result' }
      expect(step.options).to eq({ timeout: 30, retries: 3, cache: true })
    end

    it 'handles nested option values' do
      step = described_class.new(:fetch, config: { host: 'localhost', port: 3000 }) { 'result' }
      expect(step.options[:config]).to eq({ host: 'localhost', port: 3000 })
    end
  end

  describe 'argument handling edge cases' do
    it 'handles splat args' do
      step = described_class.new(:combine) { |*args| args.sum }
      expect(step.call(1, 2, 3, 4)).to eq(10)
    end

    it 'handles double splat kwargs' do
      step = described_class.new(:combine) { |**kwargs| kwargs.values.sum }
      expect(step.call(a: 1, b: 2, c: 3)).to eq(6)
    end

    it 'handles callable receiving a proc as argument' do
      doubler = ->(n) { n * 2 }
      step = described_class.new(:transform) { |arr, transformer| arr.map(&transformer) }
      result = step.call([1, 2, 3], doubler)
      expect(result).to eq([2, 4, 6])
    end

    it 'handles optional arguments with defaults' do
      step = described_class.new(:greet) { |name, greeting = 'Hello'| "#{greeting}, #{name}!" }
      expect(step.call('World')).to eq('Hello, World!')
      expect(step.call('World', 'Hi')).to eq('Hi, World!')
    end

    it 'handles optional keyword arguments' do
      step = described_class.new(:greet) { |name:, greeting: 'Hello'| "#{greeting}, #{name}!" }
      expect(step.call(name: 'World')).to eq('Hello, World!')
      expect(step.call(name: 'World', greeting: 'Hi')).to eq('Hi, World!')
    end
  end
end
