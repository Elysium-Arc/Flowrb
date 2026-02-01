# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass, Style/SymbolProc

# Extended conditional execution tests based on patterns from:
# - Prefect (case/merge, conditional branches)
# - Airflow (trigger rules, BranchPythonOperator, skip propagation)
# - Luigi (soft failures, dependency checking)
# - Celery (chain breaking, workflow state)
# - General workflow orchestration patterns

RSpec.describe 'Step Conditional Execution - Extended Patterns' do
  # ============================================================================
  # Prefect-inspired patterns: merge behavior, nested conditionals
  # ============================================================================
  describe 'Prefect-style merge patterns' do
    it 'returns first non-skipped result in fan-in (merge pattern)' do
      pipeline = Flowrb.define do
        step :condition do
          :path_a
        end

        step :path_a, depends_on: :condition, if: ->(cond) { cond == :path_a } do |_|
          'result from A'
        end

        step :path_b, depends_on: :condition, if: ->(cond) { cond == :path_b } do |_|
          'result from B'
        end

        step :path_c, depends_on: :condition, if: ->(cond) { cond == :path_c } do |_|
          'result from C'
        end

        step :merge, depends_on: %i[path_a path_b path_c] do |path_a:, path_b:, path_c:|
          # Merge: return first non-nil result
          [path_a, path_b, path_c].compact.first || 'all skipped'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:path_a].output).to eq('result from A')
      expect(result[:path_b]).to be_skipped
      expect(result[:path_c]).to be_skipped
      expect(result[:merge].output).to eq('result from A')
    end

    it 'handles all branches skipped in merge' do
      pipeline = Flowrb.define do
        step :condition do
          :none
        end

        step :path_a, depends_on: :condition, if: ->(cond) { cond == :path_a } do |_|
          'A'
        end

        step :path_b, depends_on: :condition, if: ->(cond) { cond == :path_b } do |_|
          'B'
        end

        step :merge, depends_on: %i[path_a path_b] do |path_a:, path_b:|
          [path_a, path_b].compact.first || 'default'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:path_a]).to be_skipped
      expect(result[:path_b]).to be_skipped
      expect(result[:merge].output).to eq('default')
    end

    it 'supports switch-like branching with multiple conditions' do
      pipeline = Flowrb.define do
        step :get_type do
          'premium'
        end

        step :free_tier, depends_on: :get_type, if: ->(type) { type == 'free' } do |_|
          { discount: 0, features: %w[basic] }
        end

        step :basic_tier, depends_on: :get_type, if: ->(type) { type == 'basic' } do |_|
          { discount: 10, features: %w[basic support] }
        end

        step :premium_tier, depends_on: :get_type, if: ->(type) { type == 'premium' } do |_|
          { discount: 25, features: %w[basic support priority analytics] }
        end

        step :apply_pricing, depends_on: %i[free_tier basic_tier premium_tier] do |free_tier:, basic_tier:, premium_tier:|
          tier = [free_tier, basic_tier, premium_tier].compact.first
          "Applied #{tier[:discount]}% discount with features: #{tier[:features].join(', ')}"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:free_tier]).to be_skipped
      expect(result[:basic_tier]).to be_skipped
      expect(result[:premium_tier]).not_to be_skipped
      expect(result[:apply_pricing].output).to include('25%')
      expect(result[:apply_pricing].output).to include('analytics')
    end

    it 'handles nested conditional branches' do
      pipeline = Flowrb.define do
        step :outer_condition do
          { run_inner: true, inner_path: :a }
        end

        step :inner_gate, depends_on: :outer_condition, if: ->(cfg) { cfg[:run_inner] } do |cfg|
          cfg[:inner_path]
        end

        step :inner_a, depends_on: :inner_gate, if: ->(path) { path == :a } do |_|
          'nested A'
        end

        step :inner_b, depends_on: :inner_gate, if: ->(path) { path == :b } do |_|
          'nested B'
        end

        step :collect, depends_on: %i[inner_a inner_b] do |inner_a:, inner_b:|
          inner_a || inner_b || 'nothing'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:inner_gate].output).to eq(:a)
      expect(result[:inner_a].output).to eq('nested A')
      expect(result[:inner_b]).to be_skipped
      expect(result[:collect].output).to eq('nested A')
    end
  end

  # ============================================================================
  # Airflow-inspired patterns: trigger rules, skip propagation
  # ============================================================================
  describe 'Airflow-style trigger rule patterns' do
    it 'simulates none_failed_min_one_success: runs if at least one upstream succeeds' do
      pipeline = Flowrb.define do
        step :branch_decider do
          :path_a
        end

        step :path_a, depends_on: :branch_decider, if: ->(d) { d == :path_a } do |_|
          'A executed'
        end

        step :path_b, depends_on: :branch_decider, if: ->(d) { d == :path_b } do |_|
          'B executed'
        end

        # This step should run as long as at least one path succeeded (not skipped)
        step :join, depends_on: %i[path_a path_b] do |path_a:, path_b:|
          results = [path_a, path_b].compact
          results.empty? ? 'no paths executed' : results.join(' + ')
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:path_a]).not_to be_skipped
      expect(result[:path_b]).to be_skipped
      expect(result[:join].output).to eq('A executed')
    end

    it 'simulates branching with downstream task continuation' do
      pipeline = Flowrb.define do
        step :start do
          { use_cache: true }
        end

        step :fetch_from_cache, depends_on: :start, if: ->(cfg) { cfg[:use_cache] } do |_|
          { source: 'cache', data: [1, 2, 3] }
        end

        step :fetch_from_api, depends_on: :start, unless: ->(cfg) { cfg[:use_cache] } do |_|
          { source: 'api', data: [4, 5, 6] }
        end

        step :process, depends_on: %i[fetch_from_cache fetch_from_api] do |fetch_from_cache:, fetch_from_api:|
          data = fetch_from_cache || fetch_from_api
          { processed: data[:data].map { |n| n * 2 }, source: data[:source] }
        end

        step :save, depends_on: :process do |processed|
          "Saved #{processed[:processed].size} items from #{processed[:source]}"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:fetch_from_cache]).not_to be_skipped
      expect(result[:fetch_from_api]).to be_skipped
      expect(result[:process].output[:source]).to eq('cache')
      expect(result[:save].output).to eq('Saved 3 items from cache')
    end

    it 'handles skip propagation through multiple levels' do
      execution_order = []

      pipeline = Flowrb.define do
        step :gate, if: -> { false } do
          execution_order << :gate
          'gate output'
        end

        step :level_1, depends_on: :gate, if: ->(input) { !input.nil? } do |_|
          execution_order << :level_1
          'level 1'
        end

        step :level_2, depends_on: :level_1, if: ->(input) { !input.nil? } do |_|
          execution_order << :level_2
          'level 2'
        end

        step :level_3, depends_on: :level_2, if: ->(input) { !input.nil? } do |_|
          execution_order << :level_3
          'level 3'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(execution_order).to be_empty
      expect(result[:gate]).to be_skipped
      expect(result[:level_1]).to be_skipped
      expect(result[:level_2]).to be_skipped
      expect(result[:level_3]).to be_skipped
    end

    it 'handles partial skip propagation (some branches continue)' do
      pipeline = Flowrb.define do
        step :source do
          { enable_a: false, enable_b: true }
        end

        step :branch_a, depends_on: :source, if: ->(cfg) { cfg[:enable_a] } do |_|
          'A'
        end

        step :branch_b, depends_on: :source, if: ->(cfg) { cfg[:enable_b] } do |_|
          'B'
        end

        step :process_a, depends_on: :branch_a, if: ->(input) { !input.nil? } do |input|
          "processed #{input}"
        end

        step :process_b, depends_on: :branch_b, if: ->(input) { !input.nil? } do |input|
          "processed #{input}"
        end

        step :final, depends_on: %i[process_a process_b] do |process_a:, process_b:|
          [process_a, process_b].compact.join(', ')
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:branch_a]).to be_skipped
      expect(result[:branch_b]).not_to be_skipped
      expect(result[:process_a]).to be_skipped
      expect(result[:process_b]).not_to be_skipped
      expect(result[:final].output).to eq('processed B')
    end
  end

  # ============================================================================
  # Luigi-inspired patterns: soft failures, dependency status checking
  # ============================================================================
  describe 'Luigi-style dependency status patterns' do
    it 'allows downstream to check if dependency was skipped vs executed with nil' do
      pipeline = Flowrb.define do
        step :maybe_skip, if: -> { false } do
          nil # Would return nil if executed
        end

        step :check_status, depends_on: :maybe_skip do |input|
          # In a real scenario, you might want to distinguish between
          # "skipped" and "executed but returned nil"
          # Here we just handle nil input gracefully
          input.nil? ? 'dependency did not produce output' : "got: #{input}"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:maybe_skip]).to be_skipped
      expect(result[:check_status].output).to eq('dependency did not produce output')
    end

    it 'handles optional dependencies pattern' do
      pipeline = Flowrb.define do
        step :required_data do
          { id: 1, name: 'test' }
        end

        step :optional_enrichment, depends_on: :required_data, if: ->(data) { data[:enrich] } do |data|
          data.merge(enriched: true)
        end

        step :process, depends_on: %i[required_data optional_enrichment] do |required_data:, optional_enrichment:|
          # Use enriched data if available, otherwise use base data
          data = optional_enrichment || required_data
          "Processing #{data[:name]} (enriched: #{data[:enriched] || false})"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:optional_enrichment]).to be_skipped
      expect(result[:process].output).to eq('Processing test (enriched: false)')
    end

    it 'supports graceful degradation pattern' do
      pipeline = Flowrb.define do
        step :primary_source, if: -> { false } do
          { source: 'primary', data: [1, 2, 3] }
        end

        step :fallback_source, depends_on: :primary_source, if: ->(primary) { primary.nil? } do |_primary|
          { source: 'fallback', data: [10, 20] }
        end

        step :use_data, depends_on: %i[primary_source fallback_source] do |primary_source:, fallback_source:|
          data = primary_source || fallback_source
          "Using #{data[:data].size} items from #{data[:source]}"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:primary_source]).to be_skipped
      expect(result[:fallback_source]).not_to be_skipped
      expect(result[:use_data].output).to eq('Using 2 items from fallback')
    end
  end

  # ============================================================================
  # Celery-inspired patterns: chain behavior, workflow state
  # ============================================================================
  describe 'Celery-style chain patterns' do
    it 'supports breaking chain based on intermediate result' do
      pipeline = Flowrb.define do
        step :validate do
          { valid: false, reason: 'missing required field' }
        end

        step :transform, depends_on: :validate, if: ->(v) { v[:valid] } do |_|
          'transformed'
        end

        step :save, depends_on: :transform, if: ->(input) { !input.nil? } do |input|
          "saved: #{input}"
        end

        step :notify, depends_on: :save, if: ->(input) { !input.nil? } do |input|
          "notified: #{input}"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:validate]).not_to be_skipped
      expect(result[:transform]).to be_skipped
      expect(result[:save]).to be_skipped
      expect(result[:notify]).to be_skipped
    end

    it 'supports immutable-like steps that ignore upstream output' do
      counter = 0

      pipeline = Flowrb.define do
        step :producer do
          counter += 1
          "produced #{counter}"
        end

        # This step runs unconditionally, ignoring producer output
        step :independent, depends_on: :producer do |_input|
          counter += 10
          "independent: #{counter}"
        end

        # This step only runs if producer returned specific value
        step :dependent, depends_on: :producer, if: ->(input) { input.include?('special') } do |input|
          "dependent on: #{input}"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:producer].output).to eq('produced 1')
      expect(result[:independent].output).to eq('independent: 11')
      expect(result[:dependent]).to be_skipped
    end
  end

  # ============================================================================
  # Diamond and complex DAG patterns with conditionals
  # ============================================================================
  describe 'Diamond pattern with conditionals' do
    it 'handles diamond with conditional branches' do
      pipeline = Flowrb.define do
        step :root do
          { enable_left: true, enable_right: false }
        end

        step :left, depends_on: :root, if: ->(cfg) { cfg[:enable_left] } do |_|
          'left result'
        end

        step :right, depends_on: :root, if: ->(cfg) { cfg[:enable_right] } do |_|
          'right result'
        end

        step :join, depends_on: %i[left right] do |left:, right:|
          { left: left, right: right }
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:left]).not_to be_skipped
      expect(result[:right]).to be_skipped
      expect(result[:join].output).to eq({ left: 'left result', right: nil })
    end

    it 'handles multiple diamonds with mixed conditions' do
      pipeline = Flowrb.define do
        step :config do
          { diamond1: { left: true, right: true }, diamond2: { left: false, right: true } }
        end

        # Diamond 1
        step :d1_left, depends_on: :config, if: ->(c) { c[:diamond1][:left] } do |_|
          'd1 left'
        end

        step :d1_right, depends_on: :config, if: ->(c) { c[:diamond1][:right] } do |_|
          'd1 right'
        end

        step :d1_join, depends_on: %i[d1_left d1_right] do |d1_left:, d1_right:|
          [d1_left, d1_right].compact.join(' + ')
        end

        # Diamond 2
        step :d2_left, depends_on: :config, if: ->(c) { c[:diamond2][:left] } do |_|
          'd2 left'
        end

        step :d2_right, depends_on: :config, if: ->(c) { c[:diamond2][:right] } do |_|
          'd2 right'
        end

        step :d2_join, depends_on: %i[d2_left d2_right] do |d2_left:, d2_right:|
          [d2_left, d2_right].compact.join(' + ')
        end

        step :final, depends_on: %i[d1_join d2_join] do |d1_join:, d2_join:|
          "Diamond1: #{d1_join}, Diamond2: #{d2_join}"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:d1_left]).not_to be_skipped
      expect(result[:d1_right]).not_to be_skipped
      expect(result[:d2_left]).to be_skipped
      expect(result[:d2_right]).not_to be_skipped
      expect(result[:d1_join].output).to eq('d1 left + d1 right')
      expect(result[:d2_join].output).to eq('d2 right')
      expect(result[:final].output).to eq('Diamond1: d1 left + d1 right, Diamond2: d2 right')
    end
  end

  # ============================================================================
  # Fan-out/Fan-in patterns with conditions
  # ============================================================================
  describe 'Fan-out/Fan-in patterns' do
    it 'handles selective fan-out based on data' do
      pipeline = Flowrb.define do
        step :splitter do
          { items: [1, 2, 3, 4, 5], process_even: true, process_odd: false }
        end

        step :even_processor, depends_on: :splitter, if: ->(data) { data[:process_even] } do |data|
          data[:items].select(&:even?).map { |n| n * 2 }
        end

        step :odd_processor, depends_on: :splitter, if: ->(data) { data[:process_odd] } do |data|
          data[:items].select(&:odd?).map { |n| n * 3 }
        end

        step :collector, depends_on: %i[even_processor odd_processor] do |even_processor:, odd_processor:|
          even_results = even_processor || []
          odd_results = odd_processor || []
          { even: even_results, odd: odd_results, total: even_results.size + odd_results.size }
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:even_processor].output).to eq([4, 8])
      expect(result[:odd_processor]).to be_skipped
      expect(result[:collector].output).to eq({ even: [4, 8], odd: [], total: 2 })
    end

    it 'handles dynamic fan-out count' do
      pipeline = Flowrb.define do
        step :config do
          { workers: 3 }
        end

        step :worker_0, depends_on: :config, if: ->(c) { c[:workers] > 0 } do |_|
          'worker 0 done'
        end

        step :worker_1, depends_on: :config, if: ->(c) { c[:workers] > 1 } do |_|
          'worker 1 done'
        end

        step :worker_2, depends_on: :config, if: ->(c) { c[:workers] > 2 } do |_|
          'worker 2 done'
        end

        step :worker_3, depends_on: :config, if: ->(c) { c[:workers] > 3 } do |_|
          'worker 3 done'
        end

        step :gather, depends_on: %i[worker_0 worker_1 worker_2 worker_3] do |worker_0:, worker_1:, worker_2:, worker_3:|
          [worker_0, worker_1, worker_2, worker_3].compact
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:worker_0]).not_to be_skipped
      expect(result[:worker_1]).not_to be_skipped
      expect(result[:worker_2]).not_to be_skipped
      expect(result[:worker_3]).to be_skipped
      expect(result[:gather].output).to eq(['worker 0 done', 'worker 1 done', 'worker 2 done'])
    end
  end

  # ============================================================================
  # Data-driven conditional patterns
  # ============================================================================
  describe 'Data-driven conditional execution' do
    it 'handles type-based routing' do
      pipeline = Flowrb.define do
        step :get_request do
          { type: 'json', payload: '{"key": "value"}' }
        end

        step :parse_json, depends_on: :get_request, if: ->(req) { req[:type] == 'json' } do |req|
          # Simulate JSON parsing
          { parsed: true, format: 'json', data: req[:payload] }
        end

        step :parse_xml, depends_on: :get_request, if: ->(req) { req[:type] == 'xml' } do |req|
          { parsed: true, format: 'xml', data: req[:payload] }
        end

        step :parse_csv, depends_on: :get_request, if: ->(req) { req[:type] == 'csv' } do |req|
          { parsed: true, format: 'csv', data: req[:payload] }
        end

        step :process_parsed, depends_on: %i[parse_json parse_xml parse_csv] do |parse_json:, parse_xml:, parse_csv:|
          result = [parse_json, parse_xml, parse_csv].compact.first
          result ? "Processed #{result[:format]} data" : 'Unknown format'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:parse_json]).not_to be_skipped
      expect(result[:parse_xml]).to be_skipped
      expect(result[:parse_csv]).to be_skipped
      expect(result[:process_parsed].output).to eq('Processed json data')
    end

    it 'handles threshold-based conditions' do
      pipeline = Flowrb.define do
        step :get_metrics do
          { cpu: 75, memory: 45, disk: 90 }
        end

        step :cpu_alert, depends_on: :get_metrics, if: ->(m) { m[:cpu] > 80 } do |m|
          "CPU alert: #{m[:cpu]}%"
        end

        step :memory_alert, depends_on: :get_metrics, if: ->(m) { m[:memory] > 80 } do |m|
          "Memory alert: #{m[:memory]}%"
        end

        step :disk_alert, depends_on: :get_metrics, if: ->(m) { m[:disk] > 80 } do |m|
          "Disk alert: #{m[:disk]}%"
        end

        step :send_alerts, depends_on: %i[cpu_alert memory_alert disk_alert] do |cpu_alert:, memory_alert:, disk_alert:|
          alerts = [cpu_alert, memory_alert, disk_alert].compact
          alerts.empty? ? 'No alerts' : alerts.join('; ')
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:cpu_alert]).to be_skipped
      expect(result[:memory_alert]).to be_skipped
      expect(result[:disk_alert]).not_to be_skipped
      expect(result[:send_alerts].output).to eq('Disk alert: 90%')
    end

    it 'handles list-based conditional processing' do
      pipeline = Flowrb.define do
        step :get_items do
          [
            { id: 1, status: 'pending' },
            { id: 2, status: 'approved' },
            { id: 3, status: 'rejected' }
          ]
        end

        step :process_pending, depends_on: :get_items, if: ->(items) { items.any? { |i| i[:status] == 'pending' } } do |items|
          items.select { |i| i[:status] == 'pending' }.map { |i| i[:id] }
        end

        step :process_approved, depends_on: :get_items, if: ->(items) { items.any? { |i| i[:status] == 'approved' } } do |items|
          items.select { |i| i[:status] == 'approved' }.map { |i| i[:id] }
        end

        step :summarize, depends_on: %i[process_pending process_approved] do |process_pending:, process_approved:|
          {
            pending_ids: process_pending || [],
            approved_ids: process_approved || []
          }
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:process_pending].output).to eq([1])
      expect(result[:process_approved].output).to eq([2])
      expect(result[:summarize].output).to eq({ pending_ids: [1], approved_ids: [2] })
    end
  end

  # ============================================================================
  # Error recovery and resilience patterns
  # ============================================================================
  describe 'Error recovery patterns' do
    it 'supports error recovery with conditional fallback' do
      primary_failed = true

      pipeline = Flowrb.define do
        step :primary, if: -> { !primary_failed } do
          'primary result'
        end

        step :fallback, depends_on: :primary, if: ->(primary) { primary.nil? } do |_primary|
          'fallback result'
        end

        step :use_result, depends_on: %i[primary fallback] do |primary:, fallback:|
          primary || fallback
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:primary]).to be_skipped
      expect(result[:fallback]).not_to be_skipped
      expect(result[:use_result].output).to eq('fallback result')
    end

    it 'supports circuit breaker pattern' do
      circuit_open = true

      pipeline = Flowrb.define do
        step :check_circuit do
          { open: circuit_open }
        end

        step :call_service, depends_on: :check_circuit, unless: ->(circuit) { circuit[:open] } do |_circuit|
          'service response'
        end

        step :use_cached, depends_on: %i[check_circuit call_service], if: ->(check_circuit:, call_service:) { call_service.nil? && check_circuit } do |check_circuit:, call_service:| # rubocop:disable Lint/UnusedBlockArgument
          'cached response'
        end

        step :respond, depends_on: %i[call_service use_cached] do |call_service:, use_cached:|
          call_service || use_cached
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:call_service]).to be_skipped
      expect(result[:use_cached]).not_to be_skipped
      expect(result[:respond].output).to eq('cached response')
    end
  end

  # ============================================================================
  # Parallel execution with complex conditions
  # ============================================================================
  describe 'Parallel execution with conditions' do
    it 'handles parallel conditional branches correctly' do
      pipeline = Flowrb.define do
        step :config do
          { run_a: true, run_b: true, run_c: false }
        end

        step :branch_a, depends_on: :config, if: ->(c) { c[:run_a] } do |_|
          sleep 0.01
          'A'
        end

        step :branch_b, depends_on: :config, if: ->(c) { c[:run_b] } do |_|
          sleep 0.01
          'B'
        end

        step :branch_c, depends_on: :config, if: ->(c) { c[:run_c] } do |_|
          sleep 0.01
          'C'
        end

        step :collect, depends_on: %i[branch_a branch_b branch_c] do |branch_a:, branch_b:, branch_c:|
          [branch_a, branch_b, branch_c].compact.sort.join
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:branch_a]).not_to be_skipped
      expect(result[:branch_b]).not_to be_skipped
      expect(result[:branch_c]).to be_skipped
      expect(result[:collect].output).to eq('AB')
    end

    it 'handles thread-safe condition evaluation' do
      counter = 0
      mutex = Mutex.new

      pipeline = Flowrb.define do
        step :init do
          10
        end

        # These run in parallel and check same counter
        step :worker_1, depends_on: :init, if: ->(_) { mutex.synchronize { counter += 1 } && true } do |n|
          n + 1
        end

        step :worker_2, depends_on: :init, if: ->(_) { mutex.synchronize { counter += 1 } && true } do |n|
          n + 2
        end

        step :worker_3, depends_on: :init, if: ->(_) { mutex.synchronize { counter += 1 } && true } do |n|
          n + 3
        end

        step :sum, depends_on: %i[worker_1 worker_2 worker_3] do |worker_1:, worker_2:, worker_3:|
          worker_1 + worker_2 + worker_3
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(counter).to eq(3) # All conditions evaluated
      expect(result[:sum].output).to eq(36) # 11 + 12 + 13
    end
  end

  # ============================================================================
  # Complex real-world scenarios
  # ============================================================================
  describe 'Real-world scenarios' do
    it 'implements feature flag controlled pipeline' do
      feature_flags = {
        enable_caching: true,
        enable_logging: false,
        enable_metrics: true,
        enable_notifications: false
      }

      pipeline = Flowrb.define do
        step :load_config do
          feature_flags
        end

        step :process_data, depends_on: :load_config do |_|
          { processed: true, count: 100 }
        end

        step :cache_results, depends_on: %i[load_config process_data], if: ->(load_config:, process_data:) { load_config[:enable_caching] && process_data } do |load_config:, process_data:| # rubocop:disable Lint/UnusedBlockArgument
          "Cached #{process_data[:count]} items"
        end

        step :log_results, depends_on: %i[load_config process_data], if: ->(load_config:, process_data:) { load_config[:enable_logging] && process_data } do |load_config:, process_data:| # rubocop:disable Lint/UnusedBlockArgument
          "Logged #{process_data[:count]} items"
        end

        step :send_metrics, depends_on: %i[load_config process_data], if: ->(load_config:, process_data:) { load_config[:enable_metrics] && process_data } do |load_config:, process_data:| # rubocop:disable Lint/UnusedBlockArgument
          "Sent metrics for #{process_data[:count]} items"
        end

        step :notify, depends_on: %i[load_config process_data], if: ->(load_config:, process_data:) { load_config[:enable_notifications] && process_data } do |load_config:, process_data:| # rubocop:disable Lint/UnusedBlockArgument
          "Notified about #{process_data[:count]} items"
        end

        step :summary, depends_on: %i[cache_results log_results send_metrics notify] do |cache_results:, log_results:, send_metrics:, notify:|
          enabled = [cache_results, log_results, send_metrics, notify].compact
          "Completed with #{enabled.size} optional steps"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:cache_results]).not_to be_skipped
      expect(result[:log_results]).to be_skipped
      expect(result[:send_metrics]).not_to be_skipped
      expect(result[:notify]).to be_skipped
      expect(result[:summary].output).to eq('Completed with 2 optional steps')
    end

    it 'implements A/B testing pipeline' do
      # Simulate A/B test assignment
      user_bucket = 'B'

      pipeline = Flowrb.define do
        step :get_user do
          { id: 123, bucket: user_bucket }
        end

        step :experience_a, depends_on: :get_user, if: ->(user) { user[:bucket] == 'A' } do |user|
          { user_id: user[:id], experience: 'A', layout: 'classic' }
        end

        step :experience_b, depends_on: :get_user, if: ->(user) { user[:bucket] == 'B' } do |user|
          { user_id: user[:id], experience: 'B', layout: 'modern' }
        end

        step :experience_control, depends_on: :get_user, if: ->(user) { user[:bucket] == 'control' } do |user|
          { user_id: user[:id], experience: 'control', layout: 'default' }
        end

        step :render, depends_on: %i[experience_a experience_b experience_control] do |experience_a:, experience_b:, experience_control:|
          config = [experience_a, experience_b, experience_control].compact.first
          "Rendering #{config[:layout]} layout for experience #{config[:experience]}"
        end

        step :track_impression, depends_on: :render do |_|
          'impression tracked'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:experience_a]).to be_skipped
      expect(result[:experience_b]).not_to be_skipped
      expect(result[:experience_control]).to be_skipped
      expect(result[:render].output).to eq('Rendering modern layout for experience B')
    end

    it 'implements ETL pipeline with optional transformations' do
      pipeline = Flowrb.define do
        step :extract do
          {
            source: 'database',
            records: [
              { id: 1, value: 100, needs_normalization: true },
              { id: 2, value: 200, needs_normalization: false }
            ]
          }
        end

        step :normalize, depends_on: :extract, if: ->(data) { data[:records].any? { |r| r[:needs_normalization] } } do |data|
          data[:records].map do |r|
            r[:needs_normalization] ? r.merge(value: r[:value] / 100.0) : r
          end
        end

        step :validate, depends_on: %i[extract normalize] do |extract:, normalize:|
          records = normalize || extract[:records]
          { valid: records, invalid: [] }
        end

        step :load, depends_on: :validate do |validated|
          "Loaded #{validated[:valid].size} records"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:normalize]).not_to be_skipped
      expect(result[:normalize].output.first[:value]).to eq(1.0)
      expect(result[:load].output).to eq('Loaded 2 records')
    end
  end

  # ============================================================================
  # Edge cases and boundary conditions
  # ============================================================================
  describe 'Additional edge cases' do
    it 'handles condition returning 0 (falsy in some languages, truthy in Ruby)' do
      pipeline = Flowrb.define do
        step :zero_condition, if: -> { 0 } do
          'zero is truthy in Ruby'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:zero_condition]).not_to be_skipped
      expect(result[:zero_condition].output).to eq('zero is truthy in Ruby')
    end

    it 'handles condition returning empty string (truthy in Ruby)' do
      pipeline = Flowrb.define do
        step :empty_string_condition, if: -> { '' } do
          'empty string is truthy in Ruby'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:empty_string_condition]).not_to be_skipped
    end

    it 'handles condition returning empty array (truthy in Ruby)' do
      pipeline = Flowrb.define do
        step :empty_array_condition, if: -> { [] } do
          'empty array is truthy in Ruby'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:empty_array_condition]).not_to be_skipped
    end

    it 'handles deeply nested hash access in condition' do
      pipeline = Flowrb.define do
        step :nested_data do
          { level1: { level2: { level3: { enabled: true } } } }
        end

        step :conditional, depends_on: :nested_data, if: ->(data) { data.dig(:level1, :level2, :level3, :enabled) } do |_|
          'deep condition passed'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:conditional].output).to eq('deep condition passed')
    end

    it 'handles condition with method call on input' do
      pipeline = Flowrb.define do
        step :get_string do
          'hello world'
        end

        step :if_long, depends_on: :get_string, if: ->(s) { s.length > 5 } do |str|
          str.upcase
        end

        step :if_short, depends_on: :get_string, if: ->(s) { s.length <= 5 } do |str|
          str.downcase
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:if_long].output).to eq('HELLO WORLD')
      expect(result[:if_short]).to be_skipped
    end

    it 'handles unless with complex boolean expression' do
      pipeline = Flowrb.define do
        step :get_user do
          { admin: false, verified: true, banned: false }
        end

        # Skip if user is banned OR (not admin AND not verified)
        step :access_granted, depends_on: :get_user, unless: ->(u) { u[:banned] || (!u[:admin] && !u[:verified]) } do |_|
          'access granted'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:access_granted]).not_to be_skipped
      expect(result[:access_granted].output).to eq('access granted')
    end

    it 'handles all steps skipped in pipeline' do
      pipeline = Flowrb.define do
        step :a, if: -> { false } do
          'a'
        end

        step :b, if: -> { false } do
          'b'
        end

        step :c, if: -> { false } do
          'c'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:a]).to be_skipped
      expect(result[:b]).to be_skipped
      expect(result[:c]).to be_skipped
    end

    it 'handles condition that checks step result type' do
      pipeline = Flowrb.define do
        step :producer do
          { type: :hash, data: { key: 'value' } }
        end

        step :handle_hash, depends_on: :producer, if: ->(r) { r.is_a?(Hash) && r[:type] == :hash } do |r|
          "Hash with key: #{r[:data][:key]}"
        end

        step :handle_array, depends_on: :producer, if: ->(r) { r.is_a?(Array) } do |r|
          "Array with #{r.size} elements"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:handle_hash].output).to eq('Hash with key: value')
      expect(result[:handle_array]).to be_skipped
    end
  end
end

# rubocop:enable RSpec/DescribeClass, Style/SymbolProc
