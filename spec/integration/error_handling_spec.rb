# frozen_string_literal: true

RSpec.describe 'Error Handling Integration' do
  describe 'step execution errors' do
    it 'raises StepError when a step fails' do
      pipeline = Flowrb.define do
        step :ok do
          'success'
        end

        step :fail, depends_on: :ok do |_|
          raise 'Something went wrong'
        end

        step :never_runs, depends_on: :fail do |_|
          'unreachable'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.step_name).to eq(:fail)
        expect(error.original_error.message).to eq('Something went wrong')
      end
    end

    it 'provides partial results when step fails' do
      pipeline = Flowrb.define do
        step :a do
          'result_a'
        end

        step :b, depends_on: :a do |_|
          raise 'boom'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        partial = error.partial_results
        expect(partial[:a].output).to eq('result_a')
        expect(partial[:a]).to be_success
        expect(partial[:b]).to be_failed
      end
    end

    it 'stops execution after failure' do
      executed = []

      pipeline = Flowrb.define do
        step :first do
          executed << :first
          1
        end

        step :second, depends_on: :first do |_|
          executed << :second
          raise 'error'
        end

        step :third, depends_on: :second do |_|
          executed << :third
          3
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError)
      expect(executed).to eq(%i[first second])
    end

    it 'preserves original error type and backtrace' do
      pipeline = Flowrb.define do
        step :fail do
          raise ArgumentError, 'invalid argument'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.original_error).to be_a(ArgumentError)
        expect(error.original_error.message).to eq('invalid argument')
        expect(error.original_error.backtrace).not_to be_nil
      end
    end
  end

  describe 'cycle detection' do
    it 'detects self-referencing step' do
      pipeline = Flowrb.define do
        step :self_ref, depends_on: :self_ref do
          1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::CycleError)
    end

    it 'detects simple A -> B -> A cycle' do
      pipeline = Flowrb.define do
        step :a, depends_on: :b do
          1
        end

        step :b, depends_on: :a do
          2
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::CycleError)
    end

    it 'detects longer cycles (A -> B -> C -> A)' do
      pipeline = Flowrb.define do
        step :a, depends_on: :c do
          1
        end

        step :b, depends_on: :a do
          2
        end

        step :c, depends_on: :b do
          3
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::CycleError)
    end

    it 'includes cycle information in error' do
      pipeline = Flowrb.define do
        step :a, depends_on: :b do
          1
        end

        step :b, depends_on: :a do
          2
        end
      end

      expect { pipeline.validate! }.to raise_error(Flowrb::CycleError) do |error|
        expect(error.cycle).not_to be_empty
      end
    end
  end

  describe 'missing dependency detection' do
    it 'raises MissingDependencyError for unknown dependency' do
      pipeline = Flowrb.define do
        step :process, depends_on: :nonexistent do |_|
          'result'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::MissingDependencyError) do |error|
        expect(error.step_name).to eq(:process)
        expect(error.missing_dependency).to eq(:nonexistent)
      end
    end

    it 'raises error for partially missing dependencies' do
      pipeline = Flowrb.define do
        step :exists do
          1
        end

        step :consumer, depends_on: %i[exists missing] do |exists:, missing:|
          exists + missing
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::MissingDependencyError) do |error|
        expect(error.missing_dependency).to eq(:missing)
      end
    end
  end

  describe 'duplicate step detection' do
    it 'raises DuplicateStepError for duplicate step names' do
      expect do
        Flowrb.define do
          step :duplicate do
            1
          end

          step :duplicate do
            2
          end
        end
      end.to raise_error(Flowrb::DuplicateStepError) do |error|
        expect(error.step_name).to eq(:duplicate)
      end
    end
  end

  describe 'validation before run' do
    it 'validates DAG before execution' do
      pipeline = Flowrb.define do
        step :a, depends_on: :b do
          1
        end

        step :b, depends_on: :a do
          2
        end
      end

      expect { pipeline.validate! }.to raise_error(Flowrb::CycleError)
    end

    it 'validation returns true for valid pipeline' do
      pipeline = Flowrb.define do
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

  describe 'error message quality' do
    it 'provides descriptive error messages for cycles' do
      pipeline = Flowrb.define do
        step :a, depends_on: :b do
          1
        end

        step :b, depends_on: :a do
          2
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::CycleError) do |error|
        expect(error.message).to include('Circular dependency')
      end
    end

    it 'provides descriptive error messages for missing deps' do
      pipeline = Flowrb.define do
        step :process, depends_on: :missing do |_|
          1
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::MissingDependencyError) do |error|
        expect(error.message).to include('missing')
        expect(error.message).to include('does not exist')
      end
    end

    it 'provides descriptive error messages for step failures' do
      pipeline = Flowrb.define do
        step :fail do
          raise 'custom error message'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        expect(error.message).to include('fail')
        expect(error.message).to include('custom error message')
      end
    end
  end

  describe 'error recovery information' do
    it 'partial results contain successful step outputs' do
      pipeline = Flowrb.define do
        step :a do
          'a_output'
        end

        step :b do
          'b_output'
        end

        step :c, depends_on: %i[a b] do |_a:, _b:|
          raise 'failed in c'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        partial = error.partial_results
        expect(partial[:a].output).to eq('a_output')
        expect(partial[:b].output).to eq('b_output')
        expect(partial[:c]).to be_failed
      end
    end

    it 'partial results include timing information' do
      pipeline = Flowrb.define do
        step :a do
          sleep(0.01)
          'done'
        end

        step :b, depends_on: :a do |_|
          raise 'boom'
        end
      end

      expect { pipeline.run }.to raise_error(Flowrb::StepError) do |error|
        partial = error.partial_results
        expect(partial[:a].duration).to be >= 0.01
        expect(partial.duration).to be >= 0.01
      end
    end
  end
end
