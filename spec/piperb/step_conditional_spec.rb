# frozen_string_literal: true

RSpec.describe 'Step Conditional Execution' do # rubocop:disable RSpec/DescribeClass
  describe 'if: condition' do
    it 'runs step when if condition returns true' do
      executed = false

      pipeline = Piperb.define do
        step :conditional, if: -> { true } do
          executed = true
          'executed'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(executed).to be true
      expect(result[:conditional].output).to eq('executed')
    end

    it 'skips step when if condition returns false' do
      executed = false

      pipeline = Piperb.define do
        step :conditional, if: -> { false } do
          executed = true
          'executed'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(executed).to be false
      expect(result[:conditional].output).to be_nil
      expect(result[:conditional]).to be_skipped
    end

    it 'passes input to if condition' do
      received_input = nil

      pipeline = Piperb.define do
        step :conditional, if: lambda { |input|
          received_input = input
          input[:run]
        } do |input|
          input[:value]
        end
      end

      result = pipeline.run(initial_input: { run: true, value: 42 })
      expect(result).to be_success
      expect(received_input).to eq({ run: true, value: 42 })
      expect(result[:conditional].output).to eq(42)
    end

    it 'passes dependency output to if condition' do
      pipeline = Piperb.define do
        step :producer do
          { should_run: true, data: 'hello' }
        end

        step :consumer, depends_on: :producer, if: ->(input) { input[:should_run] } do |input|
          input[:data].upcase
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:consumer].output).to eq('HELLO')
    end

    it 'skips step based on dependency output' do
      pipeline = Piperb.define do
        step :producer do
          { should_run: false, data: 'hello' }
        end

        step :consumer, depends_on: :producer, if: ->(input) { input[:should_run] } do |input|
          input[:data].upcase
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:consumer]).to be_skipped
      expect(result[:consumer].output).to be_nil
    end
  end

  describe 'unless: condition' do
    it 'runs step when unless condition returns false' do
      executed = false

      pipeline = Piperb.define do
        step :conditional, unless: -> { false } do
          executed = true
          'executed'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(executed).to be true
      expect(result[:conditional].output).to eq('executed')
    end

    it 'skips step when unless condition returns true' do
      executed = false

      pipeline = Piperb.define do
        step :conditional, unless: -> { true } do
          executed = true
          'executed'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(executed).to be false
      expect(result[:conditional]).to be_skipped
    end

    it 'passes input to unless condition' do
      pipeline = Piperb.define do
        step :conditional, unless: ->(input) { input[:skip] } do |input|
          input[:value]
        end
      end

      result = pipeline.run(initial_input: { skip: false, value: 42 })
      expect(result).to be_success
      expect(result[:conditional].output).to eq(42)
    end
  end

  describe 'skipped step behavior' do
    it 'marks skipped step with skipped status' do
      pipeline = Piperb.define do
        step :skipped_step, if: -> { false } do
          'never'
        end
      end

      result = pipeline.run
      expect(result[:skipped_step].status).to eq(:skipped)
      expect(result[:skipped_step]).to be_skipped
      expect(result[:skipped_step]).not_to be_success
      expect(result[:skipped_step]).not_to be_failed
    end

    it 'records zero duration for skipped steps' do
      pipeline = Piperb.define do
        step :skipped_step, if: -> { false } do
          sleep 1
          'never'
        end
      end

      result = pipeline.run
      expect(result[:skipped_step].duration).to eq(0)
    end

    it 'records zero retries for skipped steps' do
      pipeline = Piperb.define do
        step :skipped_step, if: -> { false }, retries: 3 do
          'never'
        end
      end

      result = pipeline.run
      expect(result[:skipped_step].retries).to eq(0)
    end
  end

  describe 'dependent steps with skipped dependencies' do
    it 'passes nil for skipped single dependency' do
      received_input = nil

      pipeline = Piperb.define do
        step :skipped, if: -> { false } do
          'skipped output'
        end

        step :consumer, depends_on: :skipped do |input|
          received_input = input
          "received: #{input.inspect}"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(received_input).to be_nil
      expect(result[:consumer].output).to eq('received: nil')
    end

    it 'passes nil in kwargs for skipped multiple dependencies' do
      received_kwargs = nil

      pipeline = Piperb.define do
        step :step_a do
          'a value'
        end

        step :step_b, if: -> { false } do
          'b value'
        end

        step :consumer, depends_on: %i[step_a step_b] do |step_a:, step_b:|
          received_kwargs = { step_a: step_a, step_b: step_b }
          "a=#{step_a}, b=#{step_b.inspect}"
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(received_kwargs[:step_a]).to eq('a value')
      expect(received_kwargs[:step_b]).to be_nil
    end

    it 'allows conditional check on skipped dependency' do
      pipeline = Piperb.define do
        step :maybe_skip, if: -> { false } do
          'data'
        end

        step :handler, depends_on: :maybe_skip do |input|
          if input.nil?
            'dependency was skipped'
          else
            "got: #{input}"
          end
        end
      end

      result = pipeline.run
      expect(result[:handler].output).to eq('dependency was skipped')
    end
  end

  describe 'chained conditional steps' do
    it 'handles chain of conditional steps' do
      pipeline = Piperb.define do
        step :first, if: -> { true } do
          'first'
        end

        step :second, depends_on: :first, if: ->(input) { !input.nil? } do |input|
          "#{input} -> second"
        end

        step :third, depends_on: :second, if: ->(input) { !input.nil? } do |input|
          "#{input} -> third"
        end
      end

      result = pipeline.run
      expect(result[:third].output).to eq('first -> second -> third')
    end

    it 'stops chain when condition fails' do
      pipeline = Piperb.define do
        step :first, if: -> { true } do
          nil # returns nil
        end

        step :second, depends_on: :first, if: ->(input) { !input.nil? } do |_input|
          'second'
        end

        step :third, depends_on: :second, if: ->(input) { !input.nil? } do |_input|
          'third'
        end
      end

      result = pipeline.run
      expect(result[:first].output).to be_nil
      expect(result[:first]).not_to be_skipped # executed but returned nil
      expect(result[:second]).to be_skipped
      expect(result[:third]).to be_skipped
    end
  end

  describe 'parallel execution with conditions' do
    it 'evaluates conditions correctly in parallel' do
      pipeline = Piperb.define do
        step :run_this, if: -> { true } do
          'executed'
        end

        step :skip_this, if: -> { false } do
          'skipped'
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:run_this].output).to eq('executed')
      expect(result[:skip_this]).to be_skipped
    end

    it 'handles parallel steps with dependency-based conditions' do
      pipeline = Piperb.define do
        step :config do
          { feature_a: true, feature_b: false }
        end

        step :feature_a, depends_on: :config, if: ->(cfg) { cfg[:feature_a] } do |_cfg|
          'feature A result'
        end

        step :feature_b, depends_on: :config, if: ->(cfg) { cfg[:feature_b] } do |_cfg|
          'feature B result'
        end

        step :combine, depends_on: %i[feature_a feature_b] do |feature_a:, feature_b:|
          { a: feature_a, b: feature_b }
        end
      end

      result = pipeline.run(executor: :parallel)
      expect(result).to be_success
      expect(result[:feature_a].output).to eq('feature A result')
      expect(result[:feature_b]).to be_skipped
      expect(result[:combine].output).to eq({ a: 'feature A result', b: nil })
    end
  end

  describe 'conditions with retries and timeouts' do
    it 'does not retry skipped steps' do
      attempts = 0

      pipeline = Piperb.define do
        step :skipped_retry, if: -> { false }, retries: 3 do
          attempts += 1
          raise 'should not run'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(attempts).to eq(0)
    end

    it 'does not apply timeout to skipped steps' do
      pipeline = Piperb.define do
        step :skipped_timeout, if: -> { false }, timeout: 0.01 do
          sleep 10
          'never'
        end
      end

      start = Time.now
      result = pipeline.run
      elapsed = Time.now - start

      expect(result).to be_success
      expect(elapsed).to be < 0.1
    end

    it 'applies retries to conditional step that runs' do
      attempts = 0

      pipeline = Piperb.define do
        step :retry_if_run, if: -> { true }, retries: 2 do
          attempts += 1
          raise 'fail' if attempts < 3

          'success'
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(attempts).to eq(3)
    end
  end

  describe 'edge cases' do
    it 'handles both if and unless (if takes precedence)' do
      pipeline = Piperb.define do
        step :both_conditions, if: -> { true }, unless: -> { true } do
          'executed'
        end
      end

      result = pipeline.run
      # if: true should run, unless is ignored when if is present
      expect(result[:both_conditions].output).to eq('executed')
    end

    it 'handles nil condition (treated as no condition)' do
      pipeline = Piperb.define do
        step :nil_if, if: nil do
          'executed'
        end
      end

      result = pipeline.run
      expect(result[:nil_if].output).to eq('executed')
    end

    it 'handles condition that returns truthy non-boolean' do
      pipeline = Piperb.define do
        step :truthy, if: -> { 'truthy string' } do
          'executed'
        end
      end

      result = pipeline.run
      expect(result[:truthy].output).to eq('executed')
    end

    it 'handles condition that returns falsy non-boolean' do
      pipeline = Piperb.define do
        step :falsy_nil, if: -> {} do
          'executed'
        end
      end

      result = pipeline.run
      expect(result[:falsy_nil]).to be_skipped
    end

    it 'handles exception in condition' do
      pipeline = Piperb.define do
        step :bad_condition, if: -> { raise 'condition error' } do
          'never'
        end
      end

      # Exception in condition should propagate
      result = pipeline.run
      expect(result).to be_failed
      expect(result.error.message).to eq('condition error')
    end

    it 'handles condition with multiple dependencies kwargs' do
      pipeline = Piperb.define do
        step :a do
          10
        end

        step :b do
          20
        end

        step :conditional, depends_on: %i[a b], if: ->(a:, b:) { a + b > 25 } do |a:, b:|
          a + b
        end
      end

      result = pipeline.run
      expect(result[:conditional].output).to eq(30)
    end
  end
end
