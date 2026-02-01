# frozen_string_literal: true

RSpec.describe 'Edge Cases' do
  describe 'unusual step names' do
    it 'handles step names with numbers' do
      pipeline = Flowline.define do
        step :step1 do
          1
        end

        step :step2, depends_on: :step1 do |n|
          n + 1
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:step2].output).to eq(2)
    end

    it 'handles step names with underscores' do
      pipeline = Flowline.define do
        step :fetch_user_data do
          { id: 1 }
        end

        step :process_user_data, depends_on: :fetch_user_data do |data|
          data.merge(processed: true)
        end
      end

      result = pipeline.run
      expect(result).to be_success
    end

    it 'handles single character step names' do
      pipeline = Flowline.define do
        step :a do
          1
        end

        step :b, depends_on: :a do |n|
          n + 1
        end

        step :c, depends_on: :b do |n|
          n + 1
        end
      end

      result = pipeline.run
      expect(result[:c].output).to eq(3)
    end

    it 'handles string step names (converted to symbols)' do
      pipeline = Flowline.define do
        step 'string_name' do
          'result'
        end
      end

      result = pipeline.run
      expect(result[:string_name].output).to eq('result')
    end
  end

  describe 'dependency edge cases' do
    it 'handles step depending on all previous steps' do
      pipeline = Flowline.define do
        step :a do
          1
        end

        step :b do
          2
        end

        step :c do
          3
        end

        step :d, depends_on: %i[a b c] do |a:, b:, c:|
          a + b + c
        end
      end

      result = pipeline.run
      expect(result[:d].output).to eq(6)
    end

    it 'handles long dependency chain with branching' do
      pipeline = Flowline.define do
        step :root do
          1
        end

        step :left1, depends_on: :root do |n|
          n * 2
        end

        step :left2, depends_on: :left1 do |n|
          n * 2
        end

        step :right1, depends_on: :root do |n|
          n * 3
        end

        step :right2, depends_on: :right1 do |n|
          n * 3
        end

        step :merge, depends_on: %i[left2 right2] do |left2:, right2:|
          left2 + right2
        end
      end

      result = pipeline.run
      expect(result[:left2].output).to eq(4)  # 1 * 2 * 2
      expect(result[:right2].output).to eq(9) # 1 * 3 * 3
      expect(result[:merge].output).to eq(13)
    end

    it 'handles re-convergent paths' do
      pipeline = Flowline.define do
        step :source do
          10
        end

        step :path_a, depends_on: :source do |n|
          n + 1
        end

        step :path_b, depends_on: :source do |n|
          n + 2
        end

        step :merge1, depends_on: %i[path_a path_b] do |path_a:, path_b:|
          path_a + path_b
        end

        step :path_c, depends_on: :merge1 do |n|
          n * 2
        end

        step :path_d, depends_on: :merge1 do |n|
          n * 3
        end

        step :final, depends_on: %i[path_c path_d] do |path_c:, path_d:|
          path_c + path_d
        end
      end

      result = pipeline.run
      # source=10, path_a=11, path_b=12, merge1=23
      # path_c=46, path_d=69, final=115
      expect(result[:final].output).to eq(115)
    end
  end

  describe 'callable edge cases' do
    it 'handles proc that returns proc' do
      pipeline = Flowline.define do
        step :create_multiplier do
          ->(n) { n * 5 }
        end

        step :use_multiplier, depends_on: :create_multiplier do |multiplier|
          multiplier.call(10)
        end
      end

      result = pipeline.run
      expect(result[:use_multiplier].output).to eq(50)
    end

    it 'handles step returning class instance' do
      result_class = Struct.new(:value, :metadata)

      pipeline = Flowline.define do
        step :create_object do
          result_class.new(42, { processed: true })
        end

        step :extract_value, depends_on: :create_object, &:value
      end

      result = pipeline.run
      expect(result[:create_object].output).to be_a(result_class)
      expect(result[:extract_value].output).to eq(42)
    end

    it 'handles step with stateful callable' do
      counter_class = Class.new do
        def initialize
          @count = 0
        end

        def call
          @count += 1
        end
      end

      counter = counter_class.new

      pipeline = Flowline.define do
        step :count, callable: counter
      end

      result1 = pipeline.run
      result2 = pipeline.run
      result3 = pipeline.run

      expect(result1[:count].output).to eq(1)
      expect(result2[:count].output).to eq(2)
      expect(result3[:count].output).to eq(3)
    end
  end

  describe 'initial input edge cases' do
    it 'handles nil initial input explicitly' do
      pipeline = Flowline.define do
        step :handle_nil do |input|
          input.nil? ? 'was nil' : 'was not nil'
        end
      end

      result = pipeline.run(initial_input: nil)
      expect(result[:handle_nil].output).to eq('was nil')
    end

    it 'handles complex initial input' do
      pipeline = Flowline.define do
        step :process do |input|
          input[:data].map { |d| d * input[:multiplier] }
        end
      end

      result = pipeline.run(initial_input: { data: [1, 2, 3], multiplier: 10 })
      expect(result[:process].output).to eq([10, 20, 30])
    end

    it 'initial input only goes to root steps' do
      pipeline = Flowline.define do
        step :root do |input|
          input * 2
        end

        step :child, depends_on: :root do |from_parent|
          from_parent + 1
        end
      end

      result = pipeline.run(initial_input: 5)
      expect(result[:root].output).to eq(10)
      expect(result[:child].output).to eq(11)
    end

    it 'multiple roots each receive initial input' do
      pipeline = Flowline.define do
        step :root_a do |input|
          "#{input}A"
        end

        step :root_b do |input|
          "#{input}B"
        end

        step :merge, depends_on: %i[root_a root_b] do |root_a:, root_b:|
          "#{root_a}-#{root_b}"
        end
      end

      result = pipeline.run(initial_input: 'X')
      expect(result[:root_a].output).to eq('XA')
      expect(result[:root_b].output).to eq('XB')
      expect(result[:merge].output).to eq('XA-XB')
    end
  end

  describe 'result edge cases' do
    it 'result to_h includes all information' do
      pipeline = Flowline.define do
        step :only do
          42
        end
      end

      result = pipeline.run
      hash = result.to_h

      expect(hash[:success]).to be true
      expect(hash[:duration]).to be_a(Float)
      expect(hash[:started_at]).to be_a(Time)
      expect(hash[:finished_at]).to be_a(Time)
      expect(hash[:steps][:only][:output]).to eq(42)
    end

    it 'step result includes error details on failure' do
      pipeline = Flowline.define do
        step :fail do
          raise ArgumentError, 'test error'
        end
      end

      expect { pipeline.run }.to raise_error(Flowline::StepError) do |error|
        step_result = error.partial_results[:fail]
        expect(step_result.error).to be_a(ArgumentError)
        expect(step_result.error.message).to eq('test error')
        expect(step_result).to be_failed
      end
    end

    it 'accessing non-existent step returns nil' do
      pipeline = Flowline.define do
        step :exists do
          1
        end
      end

      result = pipeline.run
      expect(result[:nonexistent]).to be_nil
    end
  end

  describe 'mermaid generation edge cases' do
    it 'mermaid handles single standalone step' do
      pipeline = Flowline.define do
        step :alone do
          1
        end
      end

      mermaid = pipeline.to_mermaid
      expect(mermaid).to include('graph TD')
      expect(mermaid).to include('alone')
    end

    it 'mermaid handles many parallel steps' do
      pipeline = Flowline.define do
        5.times do |i|
          step :"parallel_#{i}" do
            i
          end
        end
      end

      mermaid = pipeline.to_mermaid
      expect(mermaid).to include('parallel_0')
      expect(mermaid).to include('parallel_4')
    end
  end

  describe 'validation edge cases' do
    it 'empty pipeline validates successfully' do
      pipeline = Flowline.define {}
      expect(pipeline.validate!).to be true
    end

    it 'single step validates successfully' do
      pipeline = Flowline.define do
        step :only do
          1
        end
      end
      expect(pipeline.validate!).to be true
    end

    it 'validates dependency order in definition does not matter' do
      # Define dependent step before its dependency
      pipeline = Flowline.define do
        step :child, depends_on: :parent do |n|
          n + 1
        end

        step :parent do
          1
        end
      end

      expect(pipeline.validate!).to be true
      result = pipeline.run
      expect(result[:child].output).to eq(2)
    end
  end
end
