# frozen_string_literal: true

# Tests based on common DAG patterns from Python libraries:
# - Prefect (task dependencies, parallel execution)
# - Luigi (dependency resolution, failure handling)
# - Dask (task graphs, fan-out/fan-in)
# - paradag (cycle detection, topological sorting)

RSpec.describe 'DAG Patterns' do
  describe 'diamond dependency pattern' do
    # Classic diamond: A → B, A → C, B → D, C → D
    # Common in ETL: fetch → (transform_a, transform_b) → merge
    it 'executes diamond pattern correctly with sequential executor' do
      execution_order = []

      pipeline = Piperb.define do
        step :fetch do
          execution_order << :fetch
          { data: [1, 2, 3] }
        end

        step :transform_a, depends_on: :fetch do |input|
          execution_order << :transform_a
          input[:data].map { |n| n * 2 }
        end

        step :transform_b, depends_on: :fetch do |input|
          execution_order << :transform_b
          input[:data].map { |n| n + 10 }
        end

        step :merge, depends_on: %i[transform_a transform_b] do |transform_a:, transform_b:|
          execution_order << :merge
          { doubled: transform_a, shifted: transform_b }
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:merge].output).to eq({ doubled: [2, 4, 6], shifted: [11, 12, 13] })

      # Verify dependency order
      expect(execution_order.index(:fetch)).to be < execution_order.index(:transform_a)
      expect(execution_order.index(:fetch)).to be < execution_order.index(:transform_b)
      expect(execution_order.index(:transform_a)).to be < execution_order.index(:merge)
      expect(execution_order.index(:transform_b)).to be < execution_order.index(:merge)
    end

    it 'executes diamond pattern correctly with parallel executor' do
      pipeline = Piperb.define do
        step :fetch do
          { data: [1, 2, 3] }
        end

        step :transform_a, depends_on: :fetch do |input|
          sleep 0.05
          input[:data].map { |n| n * 2 }
        end

        step :transform_b, depends_on: :fetch do |input|
          sleep 0.05
          input[:data].map { |n| n + 10 }
        end

        step :merge, depends_on: %i[transform_a transform_b] do |transform_a:, transform_b:|
          { doubled: transform_a, shifted: transform_b }
        end
      end

      start = Time.now
      result = pipeline.run(executor: :parallel)
      elapsed = Time.now - start

      expect(result).to be_success
      expect(result[:merge].output).to eq({ doubled: [2, 4, 6], shifted: [11, 12, 13] })
      # Parallel should take ~0.05s, sequential would take ~0.1s
      expect(elapsed).to be < 0.09
    end
  end

  describe 'fan-out pattern' do
    # One source feeding multiple independent consumers
    # Common in: data export to multiple formats, multi-channel notifications
    it 'handles fan-out to many consumers' do
      pipeline = Piperb.define do
        step :source do
          { users: %w[alice bob charlie] }
        end

        step :export_csv, depends_on: :source do |data|
          data[:users].join(',')
        end

        step :export_json, depends_on: :source do |data|
          require 'json'
          JSON.generate(data)
        end

        step :export_xml, depends_on: :source do |data|
          "<users>#{data[:users].map { |u| "<user>#{u}</user>" }.join}</users>"
        end

        step :send_email, depends_on: :source do |data|
          "Sending to #{data[:users].size} users"
        end

        step :send_slack, depends_on: :source do |data|
          "Slack: #{data[:users].join(', ')}"
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:export_csv].output).to eq('alice,bob,charlie')
      expect(result[:export_json].output).to include('"users"')
      expect(result[:export_xml].output).to include('<user>alice</user>')
    end
  end

  describe 'fan-in pattern' do
    # Multiple independent sources merging into one
    # Common in: data aggregation, report generation
    it 'handles fan-in from many sources' do
      pipeline = Piperb.define do
        step :fetch_users do
          [{ id: 1, name: 'Alice' }, { id: 2, name: 'Bob' }]
        end

        step :fetch_orders do
          [{ user_id: 1, total: 100 }, { user_id: 2, total: 200 }]
        end

        step :fetch_products do
          [{ id: 'A', price: 50 }, { id: 'B', price: 75 }]
        end

        step :fetch_inventory do
          { 'A' => 10, 'B' => 5 }
        end

        step :generate_report, depends_on: %i[fetch_users fetch_orders fetch_products fetch_inventory] do |fetch_users:, fetch_orders:, fetch_products:, fetch_inventory:|
          {
            user_count: fetch_users.size,
            order_total: fetch_orders.sum { |o| o[:total] },
            product_count: fetch_products.size,
            total_inventory: fetch_inventory.values.sum
          }
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:generate_report].output).to eq({
                                                      user_count: 2,
                                                      order_total: 300,
                                                      product_count: 2,
                                                      total_inventory: 15
                                                    })
    end
  end

  describe 'tree reduction pattern' do
    # Binary tree reduction (like MapReduce)
    # Common in: aggregation, parallel sum/merge operations
    it 'handles tree reduction' do
      pipeline = Piperb.define do
        # Level 0: leaf nodes
        step :leaf_1 do
          [1, 2]
        end

        step :leaf_2 do
          [3, 4]
        end

        step :leaf_3 do
          [5, 6]
        end

        step :leaf_4 do
          [7, 8]
        end

        # Level 1: first reduction
        step :reduce_1, depends_on: %i[leaf_1 leaf_2] do |leaf_1:, leaf_2:|
          leaf_1 + leaf_2
        end

        step :reduce_2, depends_on: %i[leaf_3 leaf_4] do |leaf_3:, leaf_4:|
          leaf_3 + leaf_4
        end

        # Level 2: final reduction
        step :final_reduce, depends_on: %i[reduce_1 reduce_2] do |reduce_1:, reduce_2:|
          (reduce_1 + reduce_2).sum
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:final_reduce].output).to eq(36) # 1+2+3+4+5+6+7+8
    end
  end

  describe 'pipeline/chain pattern' do
    # Long sequential chain
    # Common in: data transformation pipelines, processing stages
    it 'handles long sequential chain' do
      pipeline = Piperb.define do
        step :stage_1 do
          1
        end

        step :stage_2, depends_on: :stage_1 do |n|
          n + 1
        end

        step :stage_3, depends_on: :stage_2 do |n|
          n * 2
        end

        step :stage_4, depends_on: :stage_3 do |n|
          n + 10
        end

        step :stage_5, depends_on: :stage_4 do |n|
          n * 3
        end

        step :stage_6, depends_on: :stage_5 do |n|
          n - 5
        end

        step :stage_7, depends_on: :stage_6 do |n|
          n / 2
        end

        step :stage_8, depends_on: :stage_7 do |n|
          "Final: #{n}"
        end
      end

      result = pipeline.run
      # 1 -> 2 -> 4 -> 14 -> 42 -> 37 -> 18 -> "Final: 18"
      expect(result).to be_success
      expect(result[:stage_8].output).to eq('Final: 18')
    end
  end

  describe 'multi-root convergence pattern' do
    # Multiple independent starting points converging
    # Common in: multi-source data integration
    it 'handles multiple roots converging through intermediate steps' do
      pipeline = Piperb.define do
        # Roots (level 0)
        step :api_source do
          { source: 'api', data: [1, 2, 3] }
        end

        step :db_source do
          { source: 'db', data: [4, 5, 6] }
        end

        step :file_source do
          { source: 'file', data: [7, 8, 9] }
        end

        # Intermediate processing (level 1)
        step :validate_api, depends_on: :api_source do |input|
          input[:data].select(&:positive?)
        end

        step :validate_db, depends_on: :db_source do |input|
          input[:data].select(&:positive?)
        end

        step :validate_file, depends_on: :file_source do |input|
          input[:data].select(&:positive?)
        end

        # First merge (level 2)
        step :merge_api_db, depends_on: %i[validate_api validate_db] do |validate_api:, validate_db:|
          validate_api + validate_db
        end

        # Final merge (level 3)
        step :final_merge, depends_on: %i[merge_api_db validate_file] do |merge_api_db:, validate_file:|
          (merge_api_db + validate_file).sort
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:final_merge].output).to eq([1, 2, 3, 4, 5, 6, 7, 8, 9])
    end
  end

  describe 'complex mesh topology' do
    # Irregular graph with cross-dependencies
    # Tests that the executor handles arbitrary valid DAGs
    it 'handles complex mesh with cross-dependencies' do
      pipeline = Piperb.define do
        step :a do
          'a'
        end

        step :b, depends_on: :a do |v|
          "#{v}b"
        end

        step :c, depends_on: :a do |v|
          "#{v}c"
        end

        step :d, depends_on: %i[a b] do |a:, b:|
          "#{a}#{b}d"
        end

        step :e, depends_on: %i[b c] do |b:, c:|
          "#{b}#{c}e"
        end

        step :f, depends_on: %i[c d e] do |c:, d:, e:|
          "#{c}#{d}#{e}f"
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      # a="a", b="ab", c="ac", d="a"+"ab"+"d"="aabd", e="ab"+"ac"+"e"="abace"
      # f="ac"+"aabd"+"abace"+"f"="acaabdabacef"
      expect(result[:f].output).to eq('acaabdabacef')
    end
  end

  describe 'wide graph pattern' do
    # Many independent parallel tasks
    # Tests scalability and thread handling
    it 'handles wide graph with many parallel tasks' do
      pipeline = Piperb.define do
        50.times do |i|
          step :"task_#{i}" do
            i * 2
          end
        end

        step :aggregate, depends_on: (0...50).map { |i| :"task_#{i}" } do |**results|
          results.values.sum
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      # Sum of 0*2 + 1*2 + ... + 49*2 = 2 * (0+1+...+49) = 2 * 1225 = 2450
      expect(result[:aggregate].output).to eq(2450)
    end
  end

  describe 'deep graph pattern' do
    # Very deep chain
    # Tests stack handling and long dependency chains
    it 'handles deep graph with many levels' do
      pipeline = Piperb.define do
        step :level_0 do
          0
        end

        (1..20).each do |i|
          step :"level_#{i}", depends_on: :"level_#{i - 1}" do |n|
            n + 1
          end
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:level_20].output).to eq(20)
    end
  end
end
