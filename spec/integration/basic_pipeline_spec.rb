# frozen_string_literal: true

RSpec.describe 'Basic Pipeline Integration' do
  describe 'ETL-style pipeline' do
    it 'executes fetch -> transform -> load pipeline' do
      pipeline = Flowline.define do
        step :fetch do
          [1, 2, 3, 4, 5]
        end

        step :transform, depends_on: :fetch do |data|
          data.map { |n| n * 2 }
        end

        step :load, depends_on: :transform, &:sum
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:fetch].output).to eq([1, 2, 3, 4, 5])
      expect(result[:transform].output).to eq([2, 4, 6, 8, 10])
      expect(result[:load].output).to eq(30)
    end
  end

  describe 'fan-out pipeline' do
    it 'executes one-to-many dependencies' do
      pipeline = Flowline.define do
        step :fetch do
          { users: [1, 2, 3], products: [10, 20] }
        end

        step :process_users, depends_on: :fetch do |data|
          data[:users].map { |id| "user_#{id}" }
        end

        step :process_products, depends_on: :fetch do |data|
          data[:products].map { |id| "product_#{id}" }
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:process_users].output).to eq(%w[user_1 user_2 user_3])
      expect(result[:process_products].output).to eq(%w[product_10 product_20])
    end
  end

  describe 'fan-in pipeline' do
    it 'executes many-to-one dependencies with keyword arguments' do
      pipeline = Flowline.define do
        step :fetch_users do
          %w[alice bob]
        end

        step :fetch_orders do
          [{ id: 1 }, { id: 2 }]
        end

        step :merge, depends_on: %i[fetch_users fetch_orders] do |fetch_users:, fetch_orders:|
          { users: fetch_users, orders: fetch_orders }
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:merge].output).to eq({
                                            users: %w[alice bob],
                                            orders: [{ id: 1 }, { id: 2 }]
                                          })
    end
  end

  describe 'diamond dependency pattern' do
    it 'correctly handles diamond dependencies (A -> B, A -> C, B -> D, C -> D)' do
      pipeline = Flowline.define do
        step :source do
          100
        end

        step :add_ten, depends_on: :source do |n|
          n + 10
        end

        step :multiply_two, depends_on: :source do |n|
          n * 2
        end

        step :combine, depends_on: %i[add_ten multiply_two] do |add_ten:, multiply_two:|
          add_ten + multiply_two
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:source].output).to eq(100)
      expect(result[:add_ten].output).to eq(110)
      expect(result[:multiply_two].output).to eq(200)
      expect(result[:combine].output).to eq(310) # 110 + 200
    end
  end

  describe 'complex multi-level pipeline' do
    it 'handles multiple levels of dependencies' do
      pipeline = Flowline.define do
        step :level1 do
          1
        end

        step :level2a, depends_on: :level1 do |n|
          n + 1
        end

        step :level2b, depends_on: :level1 do |n|
          n + 2
        end

        step :level3, depends_on: %i[level2a level2b] do |level2a:, level2b:|
          level2a + level2b
        end

        step :level4, depends_on: :level3 do |n|
          n * 10
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:level1].output).to eq(1)
      expect(result[:level2a].output).to eq(2)
      expect(result[:level2b].output).to eq(3)
      expect(result[:level3].output).to eq(5)
      expect(result[:level4].output).to eq(50)
    end
  end

  describe 'initial input' do
    it 'passes initial input to root steps' do
      pipeline = Flowline.define do
        step :uppercase, &:upcase

        step :add_exclaim, depends_on: :uppercase do |text|
          "#{text}!"
        end
      end

      result = pipeline.run(initial_input: 'hello')

      expect(result).to be_success
      expect(result[:uppercase].output).to eq('HELLO')
      expect(result[:add_exclaim].output).to eq('HELLO!')
    end

    it 'passes initial input to multiple roots' do
      pipeline = Flowline.define do
        step :double do |n|
          n * 2
        end

        step :triple do |n|
          n * 3
        end

        step :sum, depends_on: %i[double triple] do |double:, triple:|
          double + triple
        end
      end

      result = pipeline.run(initial_input: 10)

      expect(result[:double].output).to eq(20)
      expect(result[:triple].output).to eq(30)
      expect(result[:sum].output).to eq(50)
    end
  end

  describe 'nil outputs' do
    it 'handles nil output from steps' do
      pipeline = Flowline.define do
        step :return_nil do
          nil
        end

        step :check_nil, depends_on: :return_nil do |value|
          value.nil? ? 'received nil' : 'received something'
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:return_nil].output).to be_nil
      expect(result[:check_nil].output).to eq('received nil')
    end
  end

  describe 'empty pipeline' do
    it 'runs successfully with no steps' do
      pipeline = Flowline.define {}

      result = pipeline.run

      expect(result).to be_success
      expect(result.completed_steps).to be_empty
    end
  end

  describe 'single step pipeline' do
    it 'runs a single step with no dependencies' do
      pipeline = Flowline.define do
        step :only_one do
          'only result'
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:only_one].output).to eq('only result')
    end
  end

  describe 'result inspection' do
    it 'provides duration information' do
      pipeline = Flowline.define do
        step :slow do
          sleep(0.01)
          'done'
        end
      end

      result = pipeline.run

      expect(result.duration).to be >= 0.01
      expect(result[:slow].duration).to be >= 0.01
      expect(result[:slow].started_at).to be_a(Time)
    end

    it 'provides output access via outputs method' do
      pipeline = Flowline.define do
        step :a do
          1
        end

        step :b do
          2
        end
      end

      result = pipeline.run

      expect(result.outputs).to eq({ a: 1, b: 2 })
    end
  end

  describe 'mermaid diagram generation' do
    it 'generates correct mermaid diagram' do
      pipeline = Flowline.define do
        step :fetch do
          []
        end

        step :process, depends_on: :fetch do |_|
          []
        end

        step :save, depends_on: :process do |_|
          true
        end
      end

      mermaid = pipeline.to_mermaid

      expect(mermaid).to include('graph TD')
      expect(mermaid).to include('fetch --> process')
      expect(mermaid).to include('process --> save')
    end
  end

  describe 'validation' do
    it 'can validate before running' do
      pipeline = Flowline.define do
        step :a do
          1
        end

        step :b, depends_on: :a do |n|
          n + 1
        end
      end

      expect(pipeline.validate!).to be true
    end
  end
end
