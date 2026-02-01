# frozen_string_literal: true

# Tests for validation and cycle detection edge cases based on patterns from:
# - paradag (cycle detection, vertex validation)
# - Luigi (dependency resolution, missing dependencies)
# - Airflow (DAG validation, complex dependency graphs)

RSpec.describe 'Validation Edge Cases' do
  describe 'cycle detection' do
    it 'detects simple self-reference cycle' do
      expect do
        Flowrb.define do
          step :self_ref, depends_on: :self_ref do
            'never runs'
          end
        end.validate!
      end.to raise_error(Flowrb::CycleError)
    end

    it 'detects two-node cycle (A -> B -> A)' do
      expect do
        Flowrb.define do
          step :a, depends_on: :b do
            'a'
          end

          step :b, depends_on: :a do
            'b'
          end
        end.validate!
      end.to raise_error(Flowrb::CycleError)
    end

    it 'detects three-node cycle (A -> B -> C -> A)' do
      expect do
        Flowrb.define do
          step :a, depends_on: :c do
            'a'
          end

          step :b, depends_on: :a do
            'b'
          end

          step :c, depends_on: :b do
            'c'
          end
        end.validate!
      end.to raise_error(Flowrb::CycleError)
    end

    it 'detects cycle in otherwise valid graph' do
      expect do
        Flowrb.define do
          step :root do
            'root'
          end

          step :branch_a, depends_on: :root do |_|
            'a'
          end

          step :branch_b, depends_on: :root do |_|
            'b'
          end

          # This creates a cycle: cycle_a -> cycle_b -> cycle_a
          step :cycle_a, depends_on: %i[branch_a cycle_b] do |_branch_a:, _cycle_b:|
            'cycle_a'
          end

          step :cycle_b, depends_on: :cycle_a do |_|
            'cycle_b'
          end
        end.validate!
      end.to raise_error(Flowrb::CycleError)
    end

    it 'detects long cycle (A -> B -> C -> D -> E -> A)' do
      expect do
        Flowrb.define do
          step :a, depends_on: :e do
            'a'
          end

          step :b, depends_on: :a do
            'b'
          end

          step :c, depends_on: :b do
            'c'
          end

          step :d, depends_on: :c do
            'd'
          end

          step :e, depends_on: :d do
            'e'
          end
        end.validate!
      end.to raise_error(Flowrb::CycleError)
    end

    it 'allows valid graph with diamond pattern (not a cycle)' do
      pipeline = Flowrb.define do
        step :a do
          'a'
        end

        step :b, depends_on: :a do |_|
          'b'
        end

        step :c, depends_on: :a do |_|
          'c'
        end

        step :d, depends_on: %i[b c] do |b:, c:|
          "#{b}#{c}"
        end
      end

      expect(pipeline.validate!).to be true
    end

    it 'allows complex valid graph with no cycles' do
      pipeline = Flowrb.define do
        # Multiple roots
        step :root1 do
          1
        end

        step :root2 do
          2
        end

        step :root3 do
          3
        end

        # Intermediate layer
        step :mid1, depends_on: %i[root1 root2] do |root1:, root2:|
          root1 + root2
        end

        step :mid2, depends_on: %i[root2 root3] do |root2:, root3:|
          root2 + root3
        end

        # Final convergence
        step :final, depends_on: %i[mid1 mid2 root1] do |mid1:, mid2:, root1:|
          mid1 + mid2 + root1
        end
      end

      expect(pipeline.validate!).to be true
      result = pipeline.run
      expect(result[:final].output).to eq(9) # (1+2) + (2+3) + 1
    end
  end

  describe 'missing dependency detection' do
    it 'detects missing dependency' do
      expect do
        Flowrb.define do
          step :consumer, depends_on: :nonexistent do |_|
            'never runs'
          end
        end.validate!
      end.to raise_error(Flowrb::MissingDependencyError)
    end

    it 'reports correct missing dependency name' do
      expect do
        Flowrb.define do
          step :consumer, depends_on: :missing_step do |_|
            'never runs'
          end
        end.validate!
      end.to raise_error(Flowrb::MissingDependencyError) do |error|
        expect(error.missing_dependency).to eq(:missing_step)
        expect(error.step_name).to eq(:consumer)
      end
    end

    it 'detects missing dependency in chain' do
      expect do
        Flowrb.define do
          step :a do
            'a'
          end

          step :b, depends_on: :a do |_|
            'b'
          end

          step :c, depends_on: :missing do |_|
            'c'
          end

          step :d, depends_on: :c do |_|
            'd'
          end
        end.validate!
      end.to raise_error(Flowrb::MissingDependencyError) do |error|
        expect(error.step_name).to eq(:c)
        expect(error.missing_dependency).to eq(:missing)
      end
    end

    it 'detects multiple missing dependencies (reports first found)' do
      expect do
        Flowrb.define do
          step :consumer, depends_on: %i[missing1 missing2 missing3] do |_missing1:, _missing2:, _missing3:|
            'never runs'
          end
        end.validate!
      end.to raise_error(Flowrb::MissingDependencyError) do |error|
        expect(error.missing_dependency).to(satisfy { |dep| %i[missing1 missing2 missing3].include?(dep) })
      end
    end
  end

  describe 'duplicate step detection' do
    it 'detects duplicate step names' do
      expect do
        Flowrb.define do
          step :duplicate do
            'first'
          end

          step :duplicate do
            'second'
          end
        end
      end.to raise_error(Flowrb::DuplicateStepError)
    end

    it 'reports correct duplicate step name' do
      expect do
        Flowrb.define do
          step :my_step do
            'first'
          end

          step :my_step do
            'second'
          end
        end
      end.to raise_error(Flowrb::DuplicateStepError) do |error|
        expect(error.step_name).to eq(:my_step)
      end
    end
  end

  describe 'step name edge cases' do
    it 'handles numeric suffixes in step names' do
      pipeline = Flowrb.define do
        step :step1 do
          1
        end

        step :step2, depends_on: :step1 do |n|
          n + 1
        end

        step :step10, depends_on: :step2 do |n|
          n + 8
        end
      end

      result = pipeline.run
      expect(result[:step10].output).to eq(10)
    end

    it 'handles underscore variations in step names' do
      pipeline = Flowrb.define do
        step :step do
          'step'
        end

        step :_step do
          '_step'
        end

        step :step_ do
          'step_'
        end

        step :__step__ do
          '__step__'
        end
      end

      expect(pipeline.size).to eq(4)
      result = pipeline.run
      expect(result[:step].output).to eq('step')
      expect(result[:_step].output).to eq('_step')
      expect(result[:step_].output).to eq('step_')
      expect(result[:__step__].output).to eq('__step__')
    end

    it 'converts string step names to symbols' do
      pipeline = Flowrb.define do
        step 'string_name' do
          'from string'
        end

        step 'another_string', depends_on: 'string_name' do |v|
          "#{v} -> another"
        end
      end

      result = pipeline.run
      expect(result[:string_name].output).to eq('from string')
      expect(result[:another_string].output).to eq('from string -> another')
    end
  end

  describe 'empty and minimal pipelines' do
    it 'validates empty pipeline' do
      pipeline = Flowrb.define {}
      expect(pipeline.validate!).to be true
      expect(pipeline).to be_empty
    end

    it 'runs empty pipeline successfully' do
      pipeline = Flowrb.define {}
      result = pipeline.run
      expect(result).to be_success
      expect(result.outputs).to eq({})
    end

    it 'validates single-step pipeline' do
      pipeline = Flowrb.define do
        step :only do
          42
        end
      end

      expect(pipeline.validate!).to be true
    end

    it 'runs single-step pipeline' do
      pipeline = Flowrb.define do
        step :only do
          42
        end
      end

      result = pipeline.run
      expect(result).to be_success
      expect(result[:only].output).to eq(42)
    end
  end

  describe 'dependency order independence' do
    it 'allows defining dependent before dependency' do
      pipeline = Flowrb.define do
        # Define consumer before producer
        step :consumer, depends_on: :producer do |v|
          v * 2
        end

        step :producer do
          21
        end
      end

      expect(pipeline.validate!).to be true
      result = pipeline.run
      expect(result[:consumer].output).to eq(42)
    end

    it 'allows complex out-of-order definitions' do
      pipeline = Flowrb.define do
        step :d, depends_on: %i[b c] do |b:, c:|
          b + c
        end

        step :b, depends_on: :a do |v|
          v + 1
        end

        step :c, depends_on: :a do |v|
          v + 2
        end

        step :a do
          10
        end
      end

      expect(pipeline.validate!).to be true
      result = pipeline.run
      expect(result[:d].output).to eq(23) # (10+1) + (10+2)
    end
  end
end
