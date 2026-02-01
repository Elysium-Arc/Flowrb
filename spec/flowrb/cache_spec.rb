# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

RSpec.describe Flowrb::Cache do
  describe Flowrb::Cache::MemoryStore do
    subject(:store) { described_class.new }

    describe '#write and #read' do
      it 'stores and retrieves values' do
        store.write('key1', { data: 'value1' })
        expect(store.read('key1')).to eq({ data: 'value1' })
      end

      it 'returns nil for non-existent keys' do
        expect(store.read('nonexistent')).to be_nil
      end

      it 'overwrites existing values' do
        store.write('key1', 'first')
        store.write('key1', 'second')
        expect(store.read('key1')).to eq('second')
      end
    end

    describe '#exist?' do
      it 'returns true for existing keys' do
        store.write('key1', 'value')
        expect(store.exist?('key1')).to be true
      end

      it 'returns false for non-existent keys' do
        expect(store.exist?('nonexistent')).to be false
      end

      it 'returns true for nil values' do
        store.write('nil_key', nil)
        expect(store.exist?('nil_key')).to be true
      end
    end

    describe '#delete' do
      it 'removes existing keys' do
        store.write('key1', 'value')
        store.delete('key1')
        expect(store.exist?('key1')).to be false
      end

      it 'does nothing for non-existent keys' do
        expect { store.delete('nonexistent') }.not_to raise_error
      end
    end

    describe '#clear' do
      it 'removes all keys' do
        store.write('key1', 'value1')
        store.write('key2', 'value2')
        store.clear
        expect(store.exist?('key1')).to be false
        expect(store.exist?('key2')).to be false
      end
    end
  end

  describe Flowrb::Cache::FileStore do
    subject(:store) { described_class.new(cache_dir) }

    let(:cache_dir) { File.join(Dir.tmpdir, "flowrb_cache_test_#{Process.pid}") }

    before do
      FileUtils.rm_rf(cache_dir)
    end

    after do
      FileUtils.rm_rf(cache_dir)
    end

    describe '#initialize' do
      it 'creates the cache directory if it does not exist' do
        expect(Dir.exist?(cache_dir)).to be false
        described_class.new(cache_dir)
        expect(Dir.exist?(cache_dir)).to be true
      end

      it 'works with existing directory' do
        FileUtils.mkdir_p(cache_dir)
        expect { described_class.new(cache_dir) }.not_to raise_error
      end
    end

    describe '#write and #read' do
      it 'stores and retrieves values' do
        store.write('key1', { data: 'value1' })
        expect(store.read('key1')).to eq({ data: 'value1' })
      end

      it 'returns nil for non-existent keys' do
        expect(store.read('nonexistent')).to be_nil
      end

      it 'persists values to disk' do
        store.write('persistent', 'data')
        new_store = described_class.new(cache_dir)
        expect(new_store.read('persistent')).to eq('data')
      end

      it 'handles complex Ruby objects' do
        complex = {
          array: [1, 2, 3],
          nested: { a: 1, b: 2 },
          symbol: :test,
          string: 'hello'
        }
        store.write('complex', complex)
        expect(store.read('complex')).to eq(complex)
      end

      it 'handles nil values' do
        store.write('nil_key', nil)
        expect(store.read('nil_key')).to be_nil
        expect(store.exist?('nil_key')).to be true
      end

      it 'sanitizes keys with special characters' do
        store.write('key/with:special*chars', 'value')
        expect(store.read('key/with:special*chars')).to eq('value')
      end
    end

    describe '#exist?' do
      it 'returns true for existing keys' do
        store.write('key1', 'value')
        expect(store.exist?('key1')).to be true
      end

      it 'returns false for non-existent keys' do
        expect(store.exist?('nonexistent')).to be false
      end
    end

    describe '#delete' do
      it 'removes existing keys' do
        store.write('key1', 'value')
        store.delete('key1')
        expect(store.exist?('key1')).to be false
      end

      it 'removes the file from disk' do
        store.write('key1', 'value')
        store.delete('key1')
        expect(Dir.glob(File.join(cache_dir, '*'))).to be_empty
      end
    end

    describe '#clear' do
      it 'removes all cached values' do
        store.write('key1', 'value1')
        store.write('key2', 'value2')
        store.clear
        expect(store.exist?('key1')).to be false
        expect(store.exist?('key2')).to be false
      end
    end
  end
end

RSpec.describe 'Pipeline Caching' do # rubocop:disable RSpec/DescribeClass
  let(:cache_dir) { File.join(Dir.tmpdir, "flowrb_pipeline_cache_#{Process.pid}") }
  let(:cache_store) { Flowrb::Cache::MemoryStore.new }

  after do
    FileUtils.rm_rf(cache_dir)
  end

  describe 'basic caching behavior' do
    it 'caches step results when cache option is provided' do
      call_count = 0

      pipeline = Flowrb.define do
        step :expensive do
          call_count += 1
          'expensive result'
        end
      end

      # First run - executes step
      result1 = pipeline.run(cache: cache_store)
      expect(result1).to be_success
      expect(result1[:expensive].output).to eq('expensive result')
      expect(call_count).to eq(1)

      # Second run - uses cache
      result2 = pipeline.run(cache: cache_store)
      expect(result2).to be_success
      expect(result2[:expensive].output).to eq('expensive result')
      expect(call_count).to eq(1) # Not incremented
    end

    it 'does not cache when cache option is not provided' do
      call_count = 0

      pipeline = Flowrb.define do
        step :normal do
          call_count += 1
          'result'
        end
      end

      pipeline.run
      pipeline.run
      expect(call_count).to eq(2)
    end

    it 'caches each step independently' do
      calls = { a: 0, b: 0 }

      pipeline = Flowrb.define do
        step :step_a do
          calls[:a] += 1
          'A'
        end

        step :step_b, depends_on: :step_a do |input|
          calls[:b] += 1
          "#{input} -> B"
        end
      end

      pipeline.run(cache: cache_store)
      expect(calls).to eq({ a: 1, b: 1 })

      result2 = pipeline.run(cache: cache_store)
      expect(calls).to eq({ a: 1, b: 1 }) # Neither incremented
      expect(result2[:step_b].output).to eq('A -> B')
    end
  end

  describe 'cache with file store' do
    it 'persists cache across pipeline instances' do
      call_count = 0

      pipeline1 = Flowrb.define do
        step :persistent do
          call_count += 1
          'persisted'
        end
      end

      file_store = Flowrb::Cache::FileStore.new(cache_dir)
      pipeline1.run(cache: file_store)
      expect(call_count).to eq(1)

      # New pipeline instance, same cache directory
      pipeline2 = Flowrb.define do
        step :persistent do
          call_count += 1
          'persisted'
        end
      end

      new_file_store = Flowrb::Cache::FileStore.new(cache_dir)
      pipeline2.run(cache: new_file_store)
      expect(call_count).to eq(1) # Still 1 - loaded from disk
    end

    it 'accepts cache directory path as shorthand' do
      call_count = 0

      pipeline = Flowrb.define do
        step :shorthand do
          call_count += 1
          'result'
        end
      end

      pipeline.run(cache: cache_dir)
      pipeline.run(cache: cache_dir)
      expect(call_count).to eq(1)
    end
  end

  describe 'cache invalidation' do
    it 'allows forcing re-execution with force option' do
      call_count = 0

      pipeline = Flowrb.define do
        step :forced do
          call_count += 1
          "run #{call_count}"
        end
      end

      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1)

      pipeline.run(cache: cache_store, force: true)
      expect(call_count).to eq(2)
    end

    it 'allows clearing specific step cache' do
      calls = { a: 0, b: 0 }

      pipeline = Flowrb.define do
        step :step_a do
          calls[:a] += 1
          'A'
        end

        step :step_b do
          calls[:b] += 1
          'B'
        end
      end

      pipeline.run(cache: cache_store)
      expect(calls).to eq({ a: 1, b: 1 })

      cache_store.delete('step_a')
      pipeline.run(cache: cache_store)
      expect(calls).to eq({ a: 2, b: 1 }) # Only step_a re-ran
    end
  end

  describe 'cache with dependencies' do
    it 'uses cached dependency output for downstream steps' do
      calls = { producer: 0, consumer: 0 }
      received_input = nil

      pipeline = Flowrb.define do
        step :producer do
          calls[:producer] += 1
          { data: 'from producer' }
        end

        step :consumer, depends_on: :producer do |input|
          calls[:consumer] += 1
          received_input = input
          "consumed: #{input[:data]}"
        end
      end

      # First run
      pipeline.run(cache: cache_store)
      expect(calls).to eq({ producer: 1, consumer: 1 })

      # Clear only consumer cache
      cache_store.delete('consumer')

      # Second run - producer from cache, consumer re-executes
      pipeline.run(cache: cache_store)
      expect(calls).to eq({ producer: 1, consumer: 2 })
      expect(received_input).to eq({ data: 'from producer' })
    end

    it 'handles multiple dependencies with cache' do
      calls = { a: 0, b: 0, c: 0 }

      pipeline = Flowrb.define do
        step :step_a do
          calls[:a] += 1
          'A'
        end

        step :step_b do
          calls[:b] += 1
          'B'
        end

        step :step_c, depends_on: %i[step_a step_b] do |step_a:, step_b:|
          calls[:c] += 1
          "#{step_a} + #{step_b}"
        end
      end

      pipeline.run(cache: cache_store)
      expect(calls).to eq({ a: 1, b: 1, c: 1 })

      cache_store.delete('step_c')
      pipeline.run(cache: cache_store)
      expect(calls).to eq({ a: 1, b: 1, c: 2 })
    end
  end

  describe 'cache with failed steps' do
    it 'does not cache failed step results' do
      call_count = 0

      pipeline = Flowrb.define do
        step :failing do
          call_count += 1
          raise 'intentional failure' if call_count == 1

          'success on retry'
        end
      end

      # First run fails
      expect { pipeline.run(cache: cache_store) }.to raise_error(Flowrb::StepError)
      expect(call_count).to eq(1)
      expect(cache_store.exist?('failing')).to be false

      # Second run succeeds
      result = pipeline.run(cache: cache_store)
      expect(result).to be_success
      expect(call_count).to eq(2)
      expect(cache_store.exist?('failing')).to be true
    end

    it 'preserves successful step caches when later step fails' do
      calls = { first: 0, second: 0 }

      pipeline = Flowrb.define do
        step :first do
          calls[:first] += 1
          'first result'
        end

        step :second, depends_on: :first do |_|
          calls[:second] += 1
          raise 'second fails' if calls[:second] == 1

          'second result'
        end
      end

      # First run - first succeeds, second fails
      expect { pipeline.run(cache: cache_store) }.to raise_error(Flowrb::StepError)
      expect(calls).to eq({ first: 1, second: 1 })
      expect(cache_store.exist?('first')).to be true
      expect(cache_store.exist?('second')).to be false

      # Second run - first from cache, second re-runs and succeeds
      result = pipeline.run(cache: cache_store)
      expect(result).to be_success
      expect(calls).to eq({ first: 1, second: 2 }) # first not re-run
    end
  end

  describe 'cache with skipped steps' do
    it 'caches skipped step status' do
      condition_calls = 0

      pipeline = Flowrb.define do
        step :conditional, if: lambda {
          condition_calls += 1
          false
        } do
          'never'
        end
      end

      pipeline.run(cache: cache_store)
      expect(condition_calls).to eq(1)

      # Second run - skipped status is cached, condition not re-evaluated
      result = pipeline.run(cache: cache_store)
      expect(condition_calls).to eq(1)
      expect(result[:conditional]).to be_skipped
    end
  end

  describe 'cache with parallel execution' do
    it 'works correctly with parallel executor' do
      calls = { a: 0, b: 0, c: 0 }

      pipeline = Flowrb.define do
        step :step_a do
          calls[:a] += 1
          sleep 0.01
          'A'
        end

        step :step_b do
          calls[:b] += 1
          sleep 0.01
          'B'
        end

        step :step_c, depends_on: %i[step_a step_b] do |step_a:, step_b:|
          calls[:c] += 1
          "#{step_a} + #{step_b}"
        end
      end

      pipeline.run(cache: cache_store, executor: :parallel)
      expect(calls).to eq({ a: 1, b: 1, c: 1 })

      pipeline.run(cache: cache_store, executor: :parallel)
      expect(calls).to eq({ a: 1, b: 1, c: 1 })
    end
  end

  describe 'cache with retries' do
    it 'caches final successful result after retries' do
      attempt = 0

      pipeline = Flowrb.define do
        step :flaky, retries: 2 do
          attempt += 1
          raise 'temporary failure' if attempt < 3

          "success on attempt #{attempt}"
        end
      end

      result = pipeline.run(cache: cache_store)
      expect(result).to be_success
      expect(result[:flaky].output).to eq('success on attempt 3')

      # Reset attempt counter
      attempt = 0

      # Second run - uses cached result
      result2 = pipeline.run(cache: cache_store)
      expect(result2[:flaky].output).to eq('success on attempt 3')
      expect(attempt).to eq(0) # Step not called
    end
  end

  describe 'step-level cache control' do
    it 'allows disabling cache for specific steps' do
      calls = { cached: 0, uncached: 0 }

      pipeline = Flowrb.define do
        step :cached_step do
          calls[:cached] += 1
          'cached'
        end

        step :uncached_step, cache: false do
          calls[:uncached] += 1
          'uncached'
        end
      end

      pipeline.run(cache: cache_store)
      pipeline.run(cache: cache_store)

      expect(calls[:cached]).to eq(1)   # Cached
      expect(calls[:uncached]).to eq(2) # Not cached
    end
  end

  describe 'cache key generation' do
    it 'uses step name as default cache key' do
      pipeline = Flowrb.define do
        step :my_step do
          'result'
        end
      end

      pipeline.run(cache: cache_store)
      expect(cache_store.exist?('my_step')).to be true
    end

    it 'supports custom cache key function' do
      pipeline = Flowrb.define do
        step :dynamic, cache_key: ->(input) { "dynamic_#{input[:id]}" } do |input|
          "result for #{input[:id]}"
        end
      end

      pipeline.run(cache: cache_store, initial_input: { id: 1 })
      pipeline.run(cache: cache_store, initial_input: { id: 2 })

      expect(cache_store.exist?('dynamic_1')).to be true
      expect(cache_store.exist?('dynamic_2')).to be true
    end

    it 'custom cache key allows input-based cache invalidation' do
      call_count = 0

      pipeline = Flowrb.define do
        step :input_based, cache_key: ->(input) { "input_#{input[:version]}" } do |input|
          call_count += 1
          "v#{input[:version]} result"
        end
      end

      # Same version - uses cache
      pipeline.run(cache: cache_store, initial_input: { version: 1 })
      pipeline.run(cache: cache_store, initial_input: { version: 1 })
      expect(call_count).to eq(1)

      # Different version - re-executes
      pipeline.run(cache: cache_store, initial_input: { version: 2 })
      expect(call_count).to eq(2)
    end
  end

  describe 'edge cases' do
    it 'handles empty pipeline with cache' do
      pipeline = Flowrb.define {}
      result = pipeline.run(cache: cache_store)
      expect(result).to be_success
    end

    it 'handles step returning nil with cache' do
      call_count = 0

      pipeline = Flowrb.define do
        step :nil_step do
          call_count += 1
          nil
        end
      end

      result1 = pipeline.run(cache: cache_store)
      expect(result1[:nil_step].output).to be_nil

      result2 = pipeline.run(cache: cache_store)
      expect(result2[:nil_step].output).to be_nil
      expect(call_count).to eq(1) # Cached
    end

    it 'handles step returning false with cache' do
      call_count = 0

      pipeline = Flowrb.define do
        step :false_step do
          call_count += 1
          false
        end
      end

      pipeline.run(cache: cache_store)
      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1) # Cached even though value is falsy
    end
  end
end
