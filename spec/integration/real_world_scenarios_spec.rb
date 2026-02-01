# frozen_string_literal: true

RSpec.describe 'Real World Scenarios' do
  describe 'user registration pipeline' do
    it 'processes user registration with validation and notification' do
      pipeline = Flowrb.define do
        step :validate_input do |input|
          errors = []
          errors << 'Email required' if input[:email].nil? || input[:email].empty?
          errors << 'Name required' if input[:name].nil? || input[:name].empty?
          errors << 'Invalid age' if input[:age].nil? || input[:age] < 18

          { valid: errors.empty?, errors: errors, data: input }
        end

        step :normalize_data, depends_on: :validate_input do |result|
          raise 'Validation failed' unless result[:valid]

          {
            email: result[:data][:email].downcase.strip,
            name: result[:data][:name].strip.split.map(&:capitalize).join(' '),
            age: result[:data][:age]
          }
        end

        step :generate_username, depends_on: :normalize_data do |user|
          base = user[:name].downcase.gsub(' ', '_')
          "#{base}_#{rand(1000..9999)}"
        end

        step :create_user_record, depends_on: %i[normalize_data generate_username] do |normalize_data:, generate_username:|
          normalize_data.merge(
            username: generate_username,
            created_at: '2024-01-01T00:00:00Z',
            status: 'active'
          )
        end

        step :prepare_welcome_email, depends_on: :create_user_record do |user|
          {
            to: user[:email],
            subject: "Welcome, #{user[:name]}!",
            body: "Your username is: #{user[:username]}"
          }
        end
      end

      result = pipeline.run(initial_input: {
                              email: '  JOHN@EXAMPLE.COM  ',
                              name: 'john doe',
                              age: 25
                            })

      expect(result).to be_success
      expect(result[:normalize_data].output[:email]).to eq('john@example.com')
      expect(result[:normalize_data].output[:name]).to eq('John Doe')
      expect(result[:create_user_record].output[:status]).to eq('active')
      expect(result[:prepare_welcome_email].output[:subject]).to eq('Welcome, John Doe!')
    end

    it 'fails gracefully on validation error' do
      pipeline = Flowrb.define do
        step :validate do |input|
          raise ArgumentError, 'Email is required' if input[:email].nil?

          input
        end
      end

      expect { pipeline.run(initial_input: { name: 'Test' }) }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error).to be_a(ArgumentError)
        expect(error.original_error.message).to eq('Email is required')
      end
    end
  end

  describe 'data export pipeline' do
    it 'exports data to multiple formats' do
      pipeline = Flowrb.define do
        step :fetch_data do
          [
            { id: 1, name: 'Alice', score: 95 },
            { id: 2, name: 'Bob', score: 87 },
            { id: 3, name: 'Charlie', score: 92 }
          ]
        end

        step :to_csv, depends_on: :fetch_data do |data|
          headers = data.first.keys.join(',')
          rows = data.map { |row| row.values.join(',') }
          [headers, *rows].join("\n")
        end

        step :to_json, depends_on: :fetch_data do |data|
          require 'json'
          JSON.pretty_generate(data)
        end

        step :calculate_summary, depends_on: :fetch_data do |data|
          scores = data.map { |d| d[:score] }
          {
            count: data.size,
            average: scores.sum.to_f / scores.size,
            highest: data.max_by { |d| d[:score] }[:name],
            lowest: data.min_by { |d| d[:score] }[:name]
          }
        end

        step :generate_report, depends_on: %i[to_csv to_json calculate_summary] do |to_csv:, to_json:, calculate_summary:|
          {
            csv_export: to_csv,
            json_export: to_json,
            summary: calculate_summary,
            generated_at: '2024-01-01'
          }
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:to_csv].output).to include('id,name,score')
      expect(result[:to_csv].output).to include('1,Alice,95')
      expect(result[:calculate_summary].output[:count]).to eq(3)
      expect(result[:calculate_summary].output[:highest]).to eq('Alice')
      expect(result[:generate_report].output[:summary][:average]).to eq(91.33333333333333)
    end
  end

  describe 'order processing pipeline' do
    it 'processes an e-commerce order' do
      pipeline = Flowrb.define do
        step :validate_order do |order|
          raise 'Empty cart' if order[:items].empty?
          raise 'Invalid customer' unless order[:customer_id]

          order
        end

        step :calculate_subtotal, depends_on: :validate_order do |order|
          order[:items].sum { |item| item[:price] * item[:quantity] }
        end

        step :apply_discount, depends_on: %i[validate_order calculate_subtotal] do |validate_order:, calculate_subtotal:|
          discount_rate = validate_order[:discount_code] == 'SAVE10' ? 0.10 : 0
          {
            subtotal: calculate_subtotal,
            discount: (calculate_subtotal * discount_rate).round(2),
            discount_rate: discount_rate
          }
        end

        step :calculate_tax, depends_on: :apply_discount do |pricing|
          after_discount = pricing[:subtotal] - pricing[:discount]
          tax_rate = 0.08
          {
            **pricing,
            taxable_amount: after_discount,
            tax: (after_discount * tax_rate).round(2),
            tax_rate: tax_rate
          }
        end

        step :calculate_shipping, depends_on: :validate_order do |order|
          base_rate = 5.00
          per_item = 1.50
          total_items = order[:items].sum { |i| i[:quantity] }
          (base_rate + (total_items * per_item)).round(2)
        end

        step :finalize_order, depends_on: %i[validate_order calculate_tax calculate_shipping] do |validate_order:, calculate_tax:, calculate_shipping:|
          total = calculate_tax[:taxable_amount] + calculate_tax[:tax] + calculate_shipping

          {
            order_id: "ORD-#{rand(10_000..99_999)}",
            customer_id: validate_order[:customer_id],
            items: validate_order[:items],
            pricing: {
              subtotal: calculate_tax[:subtotal],
              discount: calculate_tax[:discount],
              tax: calculate_tax[:tax],
              shipping: calculate_shipping,
              total: total.round(2)
            },
            status: 'confirmed'
          }
        end
      end

      order = {
        customer_id: 'CUST-123',
        discount_code: 'SAVE10',
        items: [
          { name: 'Widget', price: 10.00, quantity: 3 },
          { name: 'Gadget', price: 25.00, quantity: 2 }
        ]
      }

      result = pipeline.run(initial_input: order)

      expect(result).to be_success
      expect(result[:calculate_subtotal].output).to eq(80.00) # 30 + 50
      expect(result[:apply_discount].output[:discount]).to eq(8.00) # 10% of 80
      expect(result[:calculate_shipping].output).to eq(12.50) # 5 + (5 * 1.50)
      expect(result[:finalize_order].output[:status]).to eq('confirmed')
    end
  end

  describe 'log analysis pipeline' do
    it 'analyzes log entries' do
      pipeline = Flowrb.define do
        step :parse_logs do
          # Simulated log entries
          [
            { timestamp: '2024-01-01T10:00:00', level: 'INFO', message: 'Server started' },
            { timestamp: '2024-01-01T10:05:00', level: 'ERROR', message: 'Connection failed' },
            { timestamp: '2024-01-01T10:05:01', level: 'WARN', message: 'Retrying connection' },
            { timestamp: '2024-01-01T10:05:02', level: 'INFO', message: 'Connection restored' },
            { timestamp: '2024-01-01T10:10:00', level: 'ERROR', message: 'Timeout occurred' },
            { timestamp: '2024-01-01T10:15:00', level: 'INFO', message: 'Request processed' }
          ]
        end

        step :filter_errors, depends_on: :parse_logs do |logs|
          logs.select { |log| log[:level] == 'ERROR' }
        end

        step :filter_warnings, depends_on: :parse_logs do |logs|
          logs.select { |log| log[:level] == 'WARN' }
        end

        step :count_by_level, depends_on: :parse_logs do |logs|
          logs.group_by { |log| log[:level] }.transform_values(&:count)
        end

        step :generate_summary, depends_on: %i[filter_errors filter_warnings count_by_level] do |filter_errors:, filter_warnings:, count_by_level:|
          {
            total_errors: filter_errors.size,
            total_warnings: filter_warnings.size,
            breakdown: count_by_level,
            error_messages: filter_errors.map { |e| e[:message] },
            needs_attention: !filter_errors.empty? || filter_warnings.size > 1
          }
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:filter_errors].output.size).to eq(2)
      expect(result[:count_by_level].output).to eq({ 'INFO' => 3, 'ERROR' => 2, 'WARN' => 1 })
      expect(result[:generate_summary].output[:needs_attention]).to be true
      expect(result[:generate_summary].output[:error_messages]).to include('Connection failed')
    end
  end

  describe 'configuration validation pipeline' do
    it 'validates and merges configuration from multiple sources' do
      pipeline = Flowrb.define do
        step :load_defaults do
          {
            database: { host: 'localhost', port: 5432, pool_size: 5 },
            cache: { enabled: false, ttl: 300 },
            logging: { level: 'info', format: 'json' }
          }
        end

        step :load_environment do
          # Simulated environment config
          {
            database: { host: 'db.example.com', pool_size: 10 },
            cache: { enabled: true }
          }
        end

        step :load_overrides do
          # Simulated command-line overrides
          {
            logging: { level: 'debug' }
          }
        end

        step :deep_merge, depends_on: %i[load_defaults load_environment load_overrides] do |load_defaults:, load_environment:, load_overrides:|
          result = load_defaults.dup

          [load_environment, load_overrides].each do |source|
            source.each do |key, value|
              result[key] = if value.is_a?(Hash) && result[key].is_a?(Hash)
                              result[key].merge(value)
                            else
                              value
                            end
            end
          end

          result
        end

        step :validate_config, depends_on: :deep_merge do |config|
          errors = []
          errors << 'Database host required' if config.dig(:database, :host).nil?
          errors << 'Invalid log level' unless %w[debug info warn error].include?(config.dig(:logging, :level))

          raise "Configuration errors: #{errors.join(', ')}" if errors.any?

          config.merge(validated: true)
        end
      end

      result = pipeline.run

      expect(result).to be_success
      config = result[:validate_config].output

      expect(config[:database][:host]).to eq('db.example.com')
      expect(config[:database][:port]).to eq(5432)
      expect(config[:database][:pool_size]).to eq(10)
      expect(config[:cache][:enabled]).to be true
      expect(config[:logging][:level]).to eq('debug')
      expect(config[:validated]).to be true
    end
  end

  describe 'data migration pipeline' do
    it 'migrates and transforms data between schemas' do
      pipeline = Flowrb.define do
        step :extract_legacy_data do
          # Old schema
          [
            { user_id: 1, full_name: 'John Doe', mail: 'john@old.com', created: '2020-01-15' },
            { user_id: 2, full_name: 'Jane Smith', mail: 'jane@old.com', created: '2020-02-20' }
          ]
        end

        step :transform_schema, depends_on: :extract_legacy_data do |data|
          data.map do |record|
            names = record[:full_name].split(' ', 2)
            {
              id: record[:user_id],
              first_name: names[0],
              last_name: names[1] || '',
              email: record[:mail],
              created_at: "#{record[:created]}T00:00:00Z",
              migrated_at: '2024-01-01T00:00:00Z',
              source: 'legacy_system'
            }
          end
        end

        step :validate_transformed, depends_on: :transform_schema do |data|
          data.each do |record|
            raise "Missing email for user #{record[:id]}" if record[:email].nil?
            raise "Missing first name for user #{record[:id]}" if record[:first_name].nil?
          end
          data
        end

        step :generate_migration_report, depends_on: %i[extract_legacy_data validate_transformed] do |extract_legacy_data:, validate_transformed:|
          {
            source_records: extract_legacy_data.size,
            migrated_records: validate_transformed.size,
            success: extract_legacy_data.size == validate_transformed.size,
            sample: validate_transformed.first
          }
        end
      end

      result = pipeline.run

      expect(result).to be_success
      report = result[:generate_migration_report].output

      expect(report[:source_records]).to eq(2)
      expect(report[:migrated_records]).to eq(2)
      expect(report[:success]).to be true
      expect(report[:sample][:first_name]).to eq('John')
      expect(report[:sample][:last_name]).to eq('Doe')
      expect(report[:sample][:source]).to eq('legacy_system')
    end
  end
end
