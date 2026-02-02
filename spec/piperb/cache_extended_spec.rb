# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass

# Extended cache tests based on patterns from:
# - Luigi (targets, completion checking, idempotent execution)
# - Prefect (cache policies, expiration, refresh)
# - Airflow (XCom patterns, skip handling)
# - Dask (persist behavior, distributed considerations)
# - Joblib (memoization, function change detection)
# - General caching patterns (TTL, stampede prevention, versioning)

RSpec.describe 'Cache Extended Patterns' do
  let(:cache_dir) { File.join(Dir.tmpdir, "piperb_cache_extended_#{Process.pid}_#{rand(10_000)}") }
  let(:cache_store) { Piperb::Cache::MemoryStore.new }

  after do
    FileUtils.rm_rf(cache_dir)
  end

  # ============================================================================
  # Luigi-style patterns: Target existence, completion checking
  # ============================================================================
  describe 'Luigi-style target/completion patterns' do
    it 'treats cached step as "complete" (target exists)' do
      call_count = 0

      pipeline = Piperb.define do
        step :generate_report do
          call_count += 1
          { report: 'data', generated_at: Time.now }
        end
      end

      # First run - "target" doesn't exist, so task runs
      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1)
      expect(cache_store.exist?('generate_report')).to be true

      # Second run - "target" exists, so task is skipped
      result2 = pipeline.run(cache: cache_store)
      expect(call_count).to eq(1) # Not incremented
      expect(result2[:generate_report].output[:report]).to eq('data')
    end

    it 'supports idempotent task pattern (safe to re-run)' do
      file_writes = []

      pipeline = Piperb.define do
        step :write_output do
          # Simulating idempotent file write
          file_writes << Time.now
          { written: true, timestamp: file_writes.last }
        end
      end

      # Multiple runs should produce same logical result
      pipeline.run(cache: cache_store)
      pipeline.run(cache: cache_store)
      pipeline.run(cache: cache_store)

      expect(file_writes.size).to eq(1) # Only written once due to cache
    end

    it 'allows manual cache deletion to force re-run (like deleting Luigi target)' do
      call_count = 0

      pipeline = Piperb.define do
        step :deletable do
          call_count += 1
          "run #{call_count}"
        end
      end

      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1)

      # Delete the "target" (cache entry)
      cache_store.delete('deletable')

      pipeline.run(cache: cache_store)
      expect(call_count).to eq(2)
    end

    it 'handles upstream target deletion causing downstream re-run' do
      calls = { upstream: 0, downstream: 0 }

      pipeline = Piperb.define do
        step :upstream do
          calls[:upstream] += 1
          "upstream_v#{calls[:upstream]}"
        end

        step :downstream, depends_on: :upstream, cache_key: ->(input) { "downstream_#{input}" } do |input|
          calls[:downstream] += 1
          "processed: #{input}"
        end
      end

      # First run
      pipeline.run(cache: cache_store)
      expect(calls).to eq({ upstream: 1, downstream: 1 })

      # Second run - both cached
      pipeline.run(cache: cache_store)
      expect(calls).to eq({ upstream: 1, downstream: 1 })

      # Delete upstream cache - forces upstream re-run which changes downstream input
      cache_store.delete('upstream')

      # Third run - upstream re-runs with new output, downstream cache key changes
      pipeline.run(cache: cache_store)
      expect(calls).to eq({ upstream: 2, downstream: 2 })
    end
  end

  # ============================================================================
  # Prefect-style patterns: Cache policies, expiration
  # ============================================================================
  describe 'Prefect-style cache policy patterns' do
    it 'supports input-based cache key (like Prefect INPUTS policy)' do
      call_count = 0

      pipeline = Piperb.define do
        step :input_cached, cache_key: ->(input) { "result_for_#{input}" } do |input|
          call_count += 1
          input * 2
        end
      end

      # Same input = cache hit
      pipeline.run(cache: cache_store, initial_input: 5)
      pipeline.run(cache: cache_store, initial_input: 5)
      expect(call_count).to eq(1)

      # Different input = cache miss
      pipeline.run(cache: cache_store, initial_input: 10)
      expect(call_count).to eq(2)
    end

    it 'supports composite cache key (like Prefect TASK_SOURCE + INPUTS)' do
      call_count = 0
      version = 'v1'

      pipeline = Piperb.define do
        step :versioned, cache_key: ->(input) { "#{version}_#{input}" } do |input|
          call_count += 1
          "#{version}: #{input}"
        end
      end

      pipeline.run(cache: cache_store, initial_input: 'data')
      expect(call_count).to eq(1)

      # Same version + input = cache hit
      pipeline.run(cache: cache_store, initial_input: 'data')
      expect(call_count).to eq(1)

      # Change version = cache miss (simulates code change)
      version = 'v2'
      pipeline.run(cache: cache_store, initial_input: 'data')
      expect(call_count).to eq(2)
    end

    it 'supports refresh cache option (like Prefect REFRESH_CACHE setting)' do
      call_count = 0

      pipeline = Piperb.define do
        step :refreshable do
          call_count += 1
          "run #{call_count}"
        end
      end

      result1 = pipeline.run(cache: cache_store)
      expect(result1[:refreshable].output).to eq('run 1')

      # Force refresh
      result2 = pipeline.run(cache: cache_store, force: true)
      expect(result2[:refreshable].output).to eq('run 2')

      # Normal run uses new cached value
      result3 = pipeline.run(cache: cache_store)
      expect(result3[:refreshable].output).to eq('run 2')
      expect(call_count).to eq(2)
    end

    it 'handles cache key that depends on multiple inputs (kwargs)' do
      call_count = 0

      pipeline = Piperb.define do
        step :step_a do
          'value_a'
        end

        step :step_b do
          'value_b'
        end

        step :combined, depends_on: %i[step_a step_b],
                        cache_key: ->(step_a:, step_b:) { "combined_#{step_a}_#{step_b}" } do |step_a:, step_b:|
          call_count += 1
          "#{step_a} + #{step_b}"
        end
      end

      pipeline.run(cache: cache_store)
      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1)
    end
  end

  # ============================================================================
  # Joblib-style patterns: Memoization edge cases
  # ============================================================================
  describe 'Joblib-style memoization patterns' do
    it 'caches based on argument values, not object identity' do
      call_count = 0

      pipeline = Piperb.define do
        step :memoized, cache_key: ->(input) { "hash_#{input.hash}" } do |input|
          call_count += 1
          input.sum
        end
      end

      # Same values, different array instances
      pipeline.run(cache: cache_store, initial_input: [1, 2, 3])
      pipeline.run(cache: cache_store, initial_input: [1, 2, 3])
      expect(call_count).to eq(1)

      # Different values
      pipeline.run(cache: cache_store, initial_input: [4, 5, 6])
      expect(call_count).to eq(2)
    end

    it 'handles nil input correctly for cache key' do
      call_count = 0

      pipeline = Piperb.define do
        # When initial_input is nil, no args are passed, so use no-arg lambda
        step :nil_input, cache_key: -> { 'nil_input_key' } do
          call_count += 1
          'no input provided'
        end
      end

      pipeline.run(cache: cache_store, initial_input: nil)
      pipeline.run(cache: cache_store, initial_input: nil)
      expect(call_count).to eq(1)
    end

    it 'supports ignoring certain parts of input for cache key' do
      call_count = 0

      pipeline = Piperb.define do
        # Only cache based on :data, ignore :debug and :timestamp
        step :selective, cache_key: ->(input) { "data_#{input[:data]}" } do |input|
          call_count += 1
          "processed #{input[:data]}"
        end
      end

      pipeline.run(cache: cache_store, initial_input: { data: 'foo', debug: true, timestamp: Time.now })
      pipeline.run(cache: cache_store, initial_input: { data: 'foo', debug: false, timestamp: Time.now + 100 })
      expect(call_count).to eq(1) # Cache hit despite different debug/timestamp

      pipeline.run(cache: cache_store, initial_input: { data: 'bar', debug: true, timestamp: Time.now })
      expect(call_count).to eq(2) # Cache miss due to different data
    end

    it 'handles complex nested data structures in cache key' do
      call_count = 0

      pipeline = Piperb.define do
        step :nested, cache_key: ->(input) { "nested_#{input.to_s.hash}" } do |input|
          call_count += 1
          input
        end
      end

      complex_input = {
        users: [{ id: 1, name: 'Alice' }, { id: 2, name: 'Bob' }],
        config: { nested: { deep: { value: 42 } } },
        tags: %w[a b c]
      }

      pipeline.run(cache: cache_store, initial_input: complex_input)
      pipeline.run(cache: cache_store, initial_input: complex_input.dup)
      expect(call_count).to eq(1)
    end
  end

  # ============================================================================
  # Airflow-style patterns: XCom, skip handling
  # ============================================================================
  describe 'Airflow-style XCom and skip patterns' do
    it 'preserves cached outputs for downstream consumption (XCom pattern)' do
      pipeline = Piperb.define do
        step :producer do
          { key: 'secret_value', count: 42 }
        end

        step :consumer, depends_on: :producer do |xcom|
          "Got #{xcom[:key]} with count #{xcom[:count]}"
        end
      end

      # First run populates cache
      result1 = pipeline.run(cache: cache_store)
      expect(result1[:consumer].output).to eq('Got secret_value with count 42')

      # Clear consumer cache, producer stays cached
      cache_store.delete('consumer')

      # Consumer re-runs using cached producer output (XCom)
      result2 = pipeline.run(cache: cache_store)
      expect(result2[:consumer].output).to eq('Got secret_value with count 42')
    end

    it 'handles cached skipped status correctly' do
      skip_flag = true

      pipeline = Piperb.define do
        step :maybe_skip, if: -> { !skip_flag } do
          'executed'
        end

        step :after_skip, depends_on: :maybe_skip do |input|
          input.nil? ? 'upstream skipped' : "got: #{input}"
        end
      end

      # First run - step is skipped and cached as skipped
      result1 = pipeline.run(cache: cache_store)
      expect(result1[:maybe_skip]).to be_skipped
      expect(result1[:after_skip].output).to eq('upstream skipped')

      # Change condition - but cache still returns skipped
      skip_flag = false
      result2 = pipeline.run(cache: cache_store)
      expect(result2[:maybe_skip]).to be_skipped # Cached skipped status
    end

    it 'handles trigger rule patterns (run if any upstream succeeded)' do
      pipeline = Piperb.define do
        step :branch_a, if: -> { true } do
          'a result'
        end

        step :branch_b, if: -> { false } do
          'b result'
        end

        step :join, depends_on: %i[branch_a branch_b] do |branch_a:, branch_b:|
          # Simulates none_failed_min_one_success: runs if at least one succeeded
          results = [branch_a, branch_b].compact
          "joined: #{results.join(', ')}"
        end
      end

      result = pipeline.run(cache: cache_store)
      expect(result[:branch_a]).not_to be_skipped
      expect(result[:branch_b]).to be_skipped
      expect(result[:join].output).to eq('joined: a result')

      # Second run uses cache
      result2 = pipeline.run(cache: cache_store)
      expect(result2[:join].output).to eq('joined: a result')
    end
  end

  # ============================================================================
  # Dask-style patterns: Persist, distributed considerations
  # ============================================================================
  describe 'Dask-style persist patterns' do
    it 'supports persisting intermediate results' do
      computation_count = 0

      pipeline = Piperb.define do
        step :expensive_compute do
          computation_count += 1
          (1..1000).map { |n| n * 2 }
        end

        step :use_result, depends_on: :expensive_compute, &:sum

        step :use_again, depends_on: :expensive_compute, &:max
      end

      result = pipeline.run(cache: cache_store)
      expect(computation_count).to eq(1)
      expect(result[:use_result].output).to eq(1_001_000)
      expect(result[:use_again].output).to eq(2000)
    end

    it 'handles concurrent access to cache safely', :aggregate_failures do
      file_store = Piperb::Cache::FileStore.new(cache_dir)
      results = []
      errors = []

      # Simulate concurrent pipeline runs
      threads = 5.times.map do |i|
        Thread.new do
          pipeline = Piperb.define do
            step :shared_resource do
              sleep(rand * 0.01) # Small random delay
              "result_#{i}"
            end
          end
          results << pipeline.run(cache: file_store)
        rescue StandardError => e
          errors << e
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty
      expect(results.size).to eq(5)
      expect(results).to all(be_success)
    end
  end

  # ============================================================================
  # Cache versioning and invalidation patterns
  # ============================================================================
  describe 'Cache versioning patterns' do
    it 'supports version-based cache invalidation' do
      call_count = 0
      cache_version = 1

      pipeline = Piperb.define do
        step :versioned_step, cache_key: -> { "step_v#{cache_version}" } do
          call_count += 1
          "computed with v#{cache_version}"
        end
      end

      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1)

      # Same version = cache hit
      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1)

      # Bump version = cache miss
      cache_version = 2
      result = pipeline.run(cache: cache_store)
      expect(call_count).to eq(2)
      expect(result[:versioned_step].output).to eq('computed with v2')
    end

    it 'supports environment-based cache keys' do
      call_count = 0
      environment = 'development'

      pipeline = Piperb.define do
        step :env_aware, cache_key: -> { "step_#{environment}" } do
          call_count += 1
          "result for #{environment}"
        end
      end

      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1)

      # Same environment = cache hit
      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1)

      # Different environment = cache miss
      environment = 'production'
      pipeline.run(cache: cache_store)
      expect(call_count).to eq(2)
    end
  end

  # ============================================================================
  # Cache warming and pre-population
  # ============================================================================
  describe 'Cache warming patterns' do
    it 'allows pre-populating cache before pipeline run' do
      call_count = 0

      # Pre-populate cache
      cached_result = Piperb::Cache::CachedResult.new(
        output: 'pre-warmed value',
        status: :success,
        skipped: false
      )
      cache_store.write('expensive_step', cached_result)

      pipeline = Piperb.define do
        step :expensive_step do
          call_count += 1
          'computed value'
        end
      end

      result = pipeline.run(cache: cache_store)
      expect(call_count).to eq(0) # Never executed
      expect(result[:expensive_step].output).to eq('pre-warmed value')
    end

    it 'supports selective cache warming for critical paths' do
      calls = { critical: 0, optional: 0 }

      # Pre-warm only critical step
      critical_result = Piperb::Cache::CachedResult.new(
        output: 'pre-computed critical',
        status: :success,
        skipped: false
      )
      cache_store.write('critical_step', critical_result)

      pipeline = Piperb.define do
        step :critical_step do
          calls[:critical] += 1
          'computed critical'
        end

        step :optional_step do
          calls[:optional] += 1
          'computed optional'
        end
      end

      result = pipeline.run(cache: cache_store)
      expect(calls[:critical]).to eq(0) # Pre-warmed
      expect(calls[:optional]).to eq(1) # Computed
      expect(result[:critical_step].output).to eq('pre-computed critical')
      expect(result[:optional_step].output).to eq('computed optional')
    end
  end

  # ============================================================================
  # Error handling and recovery patterns
  # ============================================================================
  describe 'Error handling and recovery patterns' do
    it 'preserves partial cache on pipeline failure' do
      calls = { step1: 0, step2: 0, step3: 0 }
      fail_step2 = true

      pipeline = Piperb.define do
        step :step1 do
          calls[:step1] += 1
          'step1 result'
        end

        step :step2, depends_on: :step1 do |_|
          calls[:step2] += 1
          raise 'step2 failed' if fail_step2

          'step2 result'
        end

        step :step3, depends_on: :step2 do |_|
          calls[:step3] += 1
          'step3 result'
        end
      end

      # First run fails at step2
      expect { pipeline.run(cache: cache_store) }.to raise_error(Piperb::StepError)
      expect(calls).to eq({ step1: 1, step2: 1, step3: 0 })
      expect(cache_store.exist?('step1')).to be true
      expect(cache_store.exist?('step2')).to be false

      # Fix the error
      fail_step2 = false

      # Resume - step1 from cache, step2 and step3 execute
      result = pipeline.run(cache: cache_store)
      expect(result).to be_success
      expect(calls).to eq({ step1: 1, step2: 2, step3: 1 })
    end

    it 'handles transient failures with retry and cache' do
      attempt = 0

      pipeline = Piperb.define do
        step :flaky, retries: 3 do
          attempt += 1
          raise 'transient error' if attempt < 3

          "success on attempt #{attempt}"
        end
      end

      result = pipeline.run(cache: cache_store)
      expect(result).to be_success
      expect(result[:flaky].output).to eq('success on attempt 3')

      # Reset counter
      attempt = 0

      # Second run uses cache, no retries needed
      result2 = pipeline.run(cache: cache_store)
      expect(result2[:flaky].output).to eq('success on attempt 3')
      expect(attempt).to eq(0)
    end

    it 'does not cache timeout errors' do
      attempt = 0

      pipeline = Piperb.define do
        step :slow, timeout: 0.1 do
          attempt += 1
          sleep 0.5 if attempt == 1
          'fast result'
        end
      end

      # First run times out
      expect { pipeline.run(cache: cache_store) }.to raise_error(Piperb::StepError)
      expect(cache_store.exist?('slow')).to be false

      # Second run succeeds
      result = pipeline.run(cache: cache_store)
      expect(result).to be_success
      expect(attempt).to eq(2)
    end
  end

  # ============================================================================
  # File store specific patterns
  # ============================================================================
  describe 'FileStore specific patterns' do
    it 'creates cache directory if it does not exist' do
      non_existent_dir = File.join(cache_dir, 'nested', 'deep', 'cache')
      expect(Dir.exist?(non_existent_dir)).to be false

      file_store = Piperb::Cache::FileStore.new(non_existent_dir)
      expect(Dir.exist?(non_existent_dir)).to be true

      file_store.write('test', 'value')
      expect(file_store.read('test')).to eq('value')
    end

    it 'handles special characters in cache keys' do
      file_store = Piperb::Cache::FileStore.new(cache_dir)

      special_keys = [
        'key/with/slashes',
        'key:with:colons',
        'key with spaces',
        'key<with>brackets',
        'key|with|pipes',
        "key\nwith\nnewlines",
        'key_with_émojis_🎉'
      ]

      special_keys.each_with_index do |key, i|
        file_store.write(key, "value_#{i}")
        expect(file_store.read(key)).to eq("value_#{i}")
        expect(file_store.exist?(key)).to be true
      end
    end

    it 'persists complex Ruby objects correctly' do
      file_store = Piperb::Cache::FileStore.new(cache_dir)

      complex_value = {
        string: 'hello',
        integer: 42,
        float: 3.14,
        array: [1, 2, 3],
        nested: { a: { b: { c: 'deep' } } },
        symbol: :test,
        nil_value: nil,
        boolean_true: true,
        boolean_false: false,
        range: 1..10,
        time: Time.new(2024, 1, 1, 12, 0, 0)
      }

      file_store.write('complex', complex_value)

      # Read in new store instance to verify disk persistence
      new_store = Piperb::Cache::FileStore.new(cache_dir)
      retrieved = new_store.read('complex')

      expect(retrieved[:string]).to eq('hello')
      expect(retrieved[:integer]).to eq(42)
      expect(retrieved[:float]).to eq(3.14)
      expect(retrieved[:array]).to eq([1, 2, 3])
      expect(retrieved[:nested][:a][:b][:c]).to eq('deep')
      expect(retrieved[:symbol]).to eq(:test)
      expect(retrieved[:nil_value]).to be_nil
      expect(retrieved[:boolean_true]).to be true
      expect(retrieved[:boolean_false]).to be false
      expect(retrieved[:range]).to eq(1..10)
      expect(retrieved[:time]).to eq(Time.new(2024, 1, 1, 12, 0, 0))
    end

    it 'handles corrupted cache files gracefully' do
      file_store = Piperb::Cache::FileStore.new(cache_dir)

      # Write a valid entry
      file_store.write('valid', 'valid_value')

      # Corrupt the cache file
      cache_files = Dir.glob(File.join(cache_dir, '*.cache'))
      File.write(cache_files.first, 'corrupted data that is not valid marshal')

      # Should return nil for corrupted entry
      expect(file_store.read('valid')).to be_nil
    end
  end

  # ============================================================================
  # Memory store specific patterns
  # ============================================================================
  describe 'MemoryStore specific patterns' do
    it 'isolates cache between different store instances' do
      store1 = Piperb::Cache::MemoryStore.new
      store2 = Piperb::Cache::MemoryStore.new

      store1.write('key', 'value1')
      store2.write('key', 'value2')

      expect(store1.read('key')).to eq('value1')
      expect(store2.read('key')).to eq('value2')
    end

    it 'handles rapid successive writes' do
      store = Piperb::Cache::MemoryStore.new

      1000.times do |i|
        store.write("key_#{i}", "value_#{i}")
      end

      1000.times do |i|
        expect(store.read("key_#{i}")).to eq("value_#{i}")
      end
    end
  end

  # ============================================================================
  # Pipeline composition with cache
  # ============================================================================
  describe 'Pipeline composition patterns' do
    it 'shares cache across similar pipelines' do
      call_count = 0

      # Pipeline 1 computes and caches
      pipeline1 = Piperb.define do
        step :shared_computation do
          call_count += 1
          'shared result'
        end
      end

      # Pipeline 2 has same step name, can use cache
      pipeline2 = Piperb.define do
        step :shared_computation do
          call_count += 1
          'shared result'
        end

        step :additional, depends_on: :shared_computation do |input|
          "extended: #{input}"
        end
      end

      pipeline1.run(cache: cache_store)
      expect(call_count).to eq(1)

      result = pipeline2.run(cache: cache_store)
      expect(call_count).to eq(1) # Reused cache from pipeline1
      expect(result[:additional].output).to eq('extended: shared result')
    end

    it 'isolates cache with unique step names' do
      call_count = 0

      pipeline1 = Piperb.define do
        step :pipeline1_step do
          call_count += 1
          'pipeline1 result'
        end
      end

      pipeline2 = Piperb.define do
        step :pipeline2_step do
          call_count += 1
          'pipeline2 result'
        end
      end

      pipeline1.run(cache: cache_store)
      pipeline2.run(cache: cache_store)
      expect(call_count).to eq(2) # Both executed, different cache keys
    end
  end

  # ============================================================================
  # Edge cases and boundary conditions
  # ============================================================================
  describe 'Edge cases and boundary conditions' do
    it 'handles empty string output' do
      call_count = 0

      pipeline = Piperb.define do
        step :empty_string do
          call_count += 1
          ''
        end
      end

      result1 = pipeline.run(cache: cache_store)
      expect(result1[:empty_string].output).to eq('')

      result2 = pipeline.run(cache: cache_store)
      expect(result2[:empty_string].output).to eq('')
      expect(call_count).to eq(1)
    end

    it 'handles empty array output' do
      call_count = 0

      pipeline = Piperb.define do
        step :empty_array do
          call_count += 1
          []
        end
      end

      pipeline.run(cache: cache_store)
      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1)
    end

    it 'handles empty hash output' do
      call_count = 0

      pipeline = Piperb.define do
        step :empty_hash do
          call_count += 1
          {}
        end
      end

      pipeline.run(cache: cache_store)
      pipeline.run(cache: cache_store)
      expect(call_count).to eq(1)
    end

    it 'handles very large output values' do
      file_store = Piperb::Cache::FileStore.new(cache_dir)
      call_count = 0

      pipeline = Piperb.define do
        step :large_output do
          call_count += 1
          Array.new(10_000) { |i| { id: i, data: 'x' * 100 } }
        end
      end

      result1 = pipeline.run(cache: file_store)
      expect(result1[:large_output].output.size).to eq(10_000)

      result2 = pipeline.run(cache: file_store)
      expect(result2[:large_output].output.size).to eq(10_000)
      expect(call_count).to eq(1)
    end

    it 'handles step with explicit nil return' do
      call_count = 0

      pipeline = Piperb.define do
        step :nil_return do
          call_count += 1
          nil # Explicit nil return
        end
      end

      result1 = pipeline.run(cache: cache_store)
      expect(result1[:nil_return].output).to be_nil

      result2 = pipeline.run(cache: cache_store)
      expect(result2[:nil_return].output).to be_nil
      expect(call_count).to eq(1)
    end

    it 'handles deeply nested pipeline with cache' do
      calls = Hash.new(0)

      pipeline = Piperb.define do
        step :level0 do
          calls[:level0] += 1
          0
        end

        step :level1, depends_on: :level0 do |n|
          calls[:level1] += 1
          n + 1
        end

        step :level2, depends_on: :level1 do |n|
          calls[:level2] += 1
          n + 1
        end

        step :level3, depends_on: :level2 do |n|
          calls[:level3] += 1
          n + 1
        end

        step :level4, depends_on: :level3 do |n|
          calls[:level4] += 1
          n + 1
        end

        step :level5, depends_on: :level4 do |n|
          calls[:level5] += 1
          n + 1
        end
      end

      result1 = pipeline.run(cache: cache_store)
      expect(result1[:level5].output).to eq(5)
      expect(calls.values.sum).to eq(6)

      result2 = pipeline.run(cache: cache_store)
      expect(result2[:level5].output).to eq(5)
      expect(calls.values.sum).to eq(6) # All cached
    end
  end
end

# rubocop:enable RSpec/DescribeClass
