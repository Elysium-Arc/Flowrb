# frozen_string_literal: true

RSpec.describe 'Pipeline Stability' do
  describe 'rerunning pipelines' do
    it 'can run the same pipeline multiple times' do
      pipeline = Piperb.define do
        step :counter do
          rand(1000)
        end

        step :double, depends_on: :counter do |n|
          n * 2
        end
      end

      results = 5.times.map { pipeline.run }

      results.each do |result|
        expect(result).to be_success
        expect(result[:double].output).to eq(result[:counter].output * 2)
      end
    end

    it 'produces independent results on each run' do
      call_count = 0

      pipeline = Piperb.define do
        step :increment do
          call_count += 1
        end
      end

      result1 = pipeline.run
      result2 = pipeline.run
      result3 = pipeline.run

      expect(result1[:increment].output).to eq(1)
      expect(result2[:increment].output).to eq(2)
      expect(result3[:increment].output).to eq(3)
    end

    it 'handles different initial inputs on reruns' do
      pipeline = Piperb.define do
        step :process, &:upcase
      end

      result1 = pipeline.run(initial_input: 'hello')
      result2 = pipeline.run(initial_input: 'world')
      result3 = pipeline.run(initial_input: 'test')

      expect(result1[:process].output).to eq('HELLO')
      expect(result2[:process].output).to eq('WORLD')
      expect(result3[:process].output).to eq('TEST')
    end
  end

  describe 'pipeline immutability' do
    it 'pipeline definition is stable after creation' do
      pipeline = Piperb.define do
        step :a do
          1
        end

        step :b, depends_on: :a do |n|
          n + 1
        end
      end

      original_size = pipeline.size
      original_steps = pipeline.steps.map(&:name)

      # Run multiple times
      5.times { pipeline.run }

      expect(pipeline.size).to eq(original_size)
      expect(pipeline.steps.map(&:name)).to eq(original_steps)
    end

    it 'results are independent objects' do
      pipeline = Piperb.define do
        step :data do
          [1, 2, 3]
        end
      end

      result1 = pipeline.run
      result2 = pipeline.run

      # Modify result1's output (if mutable)
      result1[:data].output << 4

      # result2 should be unaffected
      expect(result2[:data].output).to eq([1, 2, 3])
    end
  end

  describe 'large pipelines' do
    it 'handles pipeline with 50 sequential steps' do
      pipeline = Piperb.define do
        step :step_0 do
          0
        end

        (1...50).each do |i|
          step :"step_#{i}", depends_on: :"step_#{i - 1}" do |n|
            n + 1
          end
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:step_49].output).to eq(49)
    end

    it 'handles pipeline with 20 parallel roots merging' do
      pipeline = Piperb.define do
        20.times do |i|
          step :"root_#{i}" do
            i
          end
        end

        step :merge, depends_on: (0...20).map { |i| :"root_#{i}" } do |**kwargs|
          kwargs.values.sum
        end
      end

      result = pipeline.run

      expect(result).to be_success
      expect(result[:merge].output).to eq((0...20).sum)
    end

    it 'handles wide diamond pattern' do
      pipeline = Piperb.define do
        step :source do
          100
        end

        10.times do |i|
          step :"branch_#{i}", depends_on: :source do |n|
            n + i
          end
        end

        step :sink, depends_on: (0...10).map { |i| :"branch_#{i}" } do |**kwargs|
          kwargs.values.sum
        end
      end

      result = pipeline.run

      expect(result).to be_success
      # 10 branches: 100+0, 100+1, ..., 100+9 = 10*100 + (0+1+...+9) = 1000 + 45 = 1045
      expect(result[:sink].output).to eq(1045)
    end
  end

  describe 'timing consistency' do
    it 'step durations sum approximately to total duration' do
      pipeline = Piperb.define do
        step :a do
          sleep(0.01)
          1
        end

        step :b, depends_on: :a do |n|
          sleep(0.01)
          n + 1
        end

        step :c, depends_on: :b do |n|
          sleep(0.01)
          n + 1
        end
      end

      result = pipeline.run

      step_durations = result.step_results.values.map(&:duration).sum
      total_duration = result.duration

      # Total should be at least as long as sum of steps
      expect(total_duration).to be >= 0.03
      # Steps sum should be close to total (allowing for overhead)
      expect(step_durations).to be_within(0.01).of(total_duration)
    end

    it 'timestamps are in chronological order' do
      pipeline = Piperb.define do
        step :first do
          sleep(0.005)
          1
        end

        step :second, depends_on: :first do |n|
          sleep(0.005)
          n + 1
        end

        step :third, depends_on: :second do |n|
          sleep(0.005)
          n + 1
        end
      end

      result = pipeline.run

      expect(result.started_at).to be <= result[:first].started_at
      expect(result[:first].started_at).to be <= result[:second].started_at
      expect(result[:second].started_at).to be <= result[:third].started_at
      expect(result[:third].started_at).to be <= result.finished_at
    end
  end

  describe 'output type preservation' do
    it 'preserves nil output' do
      pipeline = Piperb.define do
        step :nil_step do
          nil
        end
      end

      result = pipeline.run
      expect(result[:nil_step].output).to be_nil
    end

    it 'preserves false output' do
      pipeline = Piperb.define do
        step :false_step do
          false
        end
      end

      result = pipeline.run
      expect(result[:false_step].output).to be false
    end

    it 'preserves zero output' do
      pipeline = Piperb.define do
        step :zero_step do
          0
        end
      end

      result = pipeline.run
      expect(result[:zero_step].output).to eq(0)
    end

    it 'preserves empty string output' do
      pipeline = Piperb.define do
        step :empty_string do
          ''
        end
      end

      result = pipeline.run
      expect(result[:empty_string].output).to eq('')
    end

    it 'preserves empty array output' do
      pipeline = Piperb.define do
        step :empty_array do
          []
        end
      end

      result = pipeline.run
      expect(result[:empty_array].output).to eq([])
    end

    it 'preserves empty hash output' do
      pipeline = Piperb.define do
        step :empty_hash do
          {}
        end
      end

      result = pipeline.run
      expect(result[:empty_hash].output).to eq({})
    end
  end

  describe 'error isolation' do
    it 'error in one pipeline does not affect another' do
      good_pipeline = Piperb.define do
        step :good do
          'success'
        end
      end

      bad_pipeline = Piperb.define do
        step :bad do
          raise 'failure'
        end
      end

      # Run bad pipeline first
      expect { bad_pipeline.run }.to raise_error(Piperb::StepError)

      # Good pipeline should still work
      result = good_pipeline.run
      expect(result).to be_success
      expect(result[:good].output).to eq('success')
    end

    it 'error does not corrupt pipeline state' do
      run_count = 0

      pipeline = Piperb.define do
        step :maybe_fail do
          run_count += 1
          raise 'fail' if run_count == 2

          run_count
        end
      end

      # First run succeeds
      result1 = pipeline.run
      expect(result1).to be_success
      expect(result1[:maybe_fail].output).to eq(1)

      # Second run fails
      expect { pipeline.run }.to raise_error(Piperb::StepError)

      # Third run succeeds again
      result3 = pipeline.run
      expect(result3).to be_success
      expect(result3[:maybe_fail].output).to eq(3)
    end
  end

  describe 'validation stability' do
    it 'valid pipeline stays valid' do
      pipeline = Piperb.define do
        step :a do
          1
        end

        step :b, depends_on: :a do |n|
          n + 1
        end
      end

      10.times do
        expect(pipeline.validate!).to be true
      end
    end

    it 'invalid pipeline consistently fails validation' do
      pipeline = Piperb.define do
        step :a, depends_on: :b do
          1
        end

        step :b, depends_on: :a do
          2
        end
      end

      10.times do
        expect { pipeline.validate! }.to raise_error(Piperb::CycleError)
      end
    end
  end
end
