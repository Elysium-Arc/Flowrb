# frozen_string_literal: true

RSpec.describe 'Data Transformation Pipelines' do
  describe 'string processing pipeline' do
    it 'processes strings through multiple transformations' do
      pipeline = Piperb.define do
        step :input do
          '  Hello World  '
        end

        step :trim, depends_on: :input, &:strip

        step :downcase, depends_on: :trim, &:downcase

        step :replace_spaces, depends_on: :downcase do |s|
          s.gsub(' ', '_')
        end

        step :add_prefix, depends_on: :replace_spaces do |s|
          "processed_#{s}"
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:trim].output).to eq('Hello World')
      expect(result[:downcase].output).to eq('hello world')
      expect(result[:replace_spaces].output).to eq('hello_world')
      expect(result[:add_prefix].output).to eq('processed_hello_world')
    end
  end

  describe 'numeric processing pipeline' do
    it 'performs mathematical operations in sequence' do
      pipeline = Piperb.define do
        step :numbers do
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        end

        step :filter_even, depends_on: :numbers do |nums|
          nums.select(&:even?)
        end

        step :square, depends_on: :filter_even do |nums|
          nums.map { |n| n**2 }
        end

        step :sum, depends_on: :square, &:sum

        step :average, depends_on: :square do |nums|
          nums.sum.to_f / nums.size
        end

        step :statistics, depends_on: %i[sum average] do |sum:, average:|
          { total: sum, mean: average, count: sum / average }
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:filter_even].output).to eq([2, 4, 6, 8, 10])
      expect(result[:square].output).to eq([4, 16, 36, 64, 100])
      expect(result[:sum].output).to eq(220)
      expect(result[:average].output).to eq(44.0)
      expect(result[:statistics].output).to eq({ total: 220, mean: 44.0, count: 5.0 })
    end
  end

  describe 'hash transformation pipeline' do
    it 'transforms and merges hash data' do
      pipeline = Piperb.define do
        step :user_data do
          { name: 'John Doe', email: 'john@example.com', age: 30 }
        end

        step :preferences do
          { theme: 'dark', language: 'en', notifications: true }
        end

        step :normalize_user, depends_on: :user_data do |user|
          user.transform_keys(&:to_s)
        end

        step :normalize_prefs, depends_on: :preferences do |prefs|
          prefs.transform_keys(&:to_s)
        end

        step :merge_profile, depends_on: %i[normalize_user normalize_prefs] do |normalize_user:, normalize_prefs:|
          normalize_user.merge('preferences' => normalize_prefs)
        end

        step :add_metadata, depends_on: :merge_profile do |profile|
          profile.merge('created_at' => '2024-01-01', 'version' => 1)
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:add_metadata].output).to include(
        'name' => 'John Doe',
        'email' => 'john@example.com',
        'preferences' => { 'theme' => 'dark', 'language' => 'en', 'notifications' => true },
        'version' => 1
      )
    end
  end

  describe 'array processing with aggregation' do
    it 'processes arrays with multiple aggregations' do
      pipeline = Piperb.define do
        step :raw_data do
          [
            { name: 'Alice', score: 85 },
            { name: 'Bob', score: 92 },
            { name: 'Charlie', score: 78 },
            { name: 'Diana', score: 95 },
            { name: 'Eve', score: 88 }
          ]
        end

        step :extract_scores, depends_on: :raw_data do |data|
          data.map { |d| d[:score] }
        end

        step :extract_names, depends_on: :raw_data do |data|
          data.map { |d| d[:name] }
        end

        step :calculate_stats, depends_on: :extract_scores do |scores|
          {
            min: scores.min,
            max: scores.max,
            sum: scores.sum,
            avg: scores.sum.to_f / scores.size
          }
        end

        step :top_performer, depends_on: :raw_data do |data|
          data.max_by { |d| d[:score] }
        end

        step :report, depends_on: %i[calculate_stats top_performer extract_names] do |calculate_stats:, top_performer:, extract_names:|
          {
            participants: extract_names,
            statistics: calculate_stats,
            winner: top_performer[:name]
          }
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:report].output[:winner]).to eq('Diana')
      expect(result[:report].output[:statistics][:max]).to eq(95)
      expect(result[:report].output[:participants]).to eq(%w[Alice Bob Charlie Diana Eve])
    end
  end

  describe 'conditional-like processing' do
    it 'handles conditional-like branching via data' do
      pipeline = Piperb.define do
        step :input do
          { value: 42, threshold: 50 }
        end

        step :check_threshold, depends_on: :input do |data|
          {
            original: data[:value],
            above_threshold: data[:value] > data[:threshold],
            difference: (data[:value] - data[:threshold]).abs
          }
        end

        step :process_result, depends_on: :check_threshold do |result|
          if result[:above_threshold]
            "Value #{result[:original]} exceeds threshold by #{result[:difference]}"
          else
            "Value #{result[:original]} is below threshold by #{result[:difference]}"
          end
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:process_result].output).to eq('Value 42 is below threshold by 8')
    end
  end

  describe 'nested data structure processing' do
    it 'handles deeply nested structures' do
      pipeline = Piperb.define do
        step :nested_input do
          {
            level1: {
              level2: {
                level3: {
                  values: [1, 2, 3]
                }
              }
            }
          }
        end

        step :extract_deep, depends_on: :nested_input do |data|
          data.dig(:level1, :level2, :level3, :values)
        end

        step :process_values, depends_on: :extract_deep do |values|
          values.map { |v| v * 10 }
        end

        step :rebuild_structure, depends_on: :process_values do |values|
          {
            processed: true,
            result: {
              data: values,
              count: values.size
            }
          }
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:extract_deep].output).to eq([1, 2, 3])
      expect(result[:process_values].output).to eq([10, 20, 30])
      expect(result[:rebuild_structure].output).to eq({
                                                        processed: true,
                                                        result: { data: [10, 20, 30], count: 3 }
                                                      })
    end
  end

  describe 'type conversion pipeline' do
    it 'converts between different data types' do
      pipeline = Piperb.define do
        step :string_numbers do
          '1,2,3,4,5'
        end

        step :to_array, depends_on: :string_numbers do |s|
          s.split(',')
        end

        step :to_integers, depends_on: :to_array do |arr|
          arr.map(&:to_i)
        end

        step :to_hash, depends_on: :to_integers do |arr|
          arr.each_with_index.to_h { |v, i| [:"item_#{i}", v] }
        end

        step :to_json_string, depends_on: :to_hash do |hash|
          require 'json'
          JSON.generate(hash)
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:to_array].output).to eq(%w[1 2 3 4 5])
      expect(result[:to_integers].output).to eq([1, 2, 3, 4, 5])
      expect(result[:to_hash].output).to eq({ item_0: 1, item_1: 2, item_2: 3, item_3: 4, item_4: 5 })
      expect(result[:to_json_string].output).to include('"item_0":1')
    end
  end
end
