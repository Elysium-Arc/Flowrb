# frozen_string_literal: true

RSpec.describe Flowline::StepResult do
  describe 'edge cases' do
    it 'handles nil duration' do
      result = described_class.new(step_name: :test, output: 42)
      expect(result.duration).to be_nil
    end

    it 'handles nil started_at' do
      result = described_class.new(step_name: :test, output: 42)
      expect(result.started_at).to be_nil
    end

    it 'handles very small duration' do
      result = described_class.new(step_name: :test, output: 42, duration: 0.000001)
      expect(result.duration).to eq(0.000001)
    end

    it 'handles very large duration' do
      result = described_class.new(step_name: :test, output: 42, duration: 86_400.0)
      expect(result.duration).to eq(86_400.0)
    end

    it 'handles output of any type' do
      [nil, false, 0, '', [], {}, Object.new, :symbol, 'string', [1, 2, 3]].each do |output|
        result = described_class.new(step_name: :test, output: output, status: :success)
        expect(result.output).to eq(output)
      end
    end
  end

  describe '#to_h completeness' do
    it 'includes all fields in hash' do
      started = Time.now
      error = StandardError.new('test error')

      result = described_class.new(
        step_name: :test,
        output: 'output_value',
        duration: 1.5,
        started_at: started,
        error: error,
        status: :failed
      )

      hash = result.to_h

      expect(hash[:step_name]).to eq(:test)
      expect(hash[:output]).to eq('output_value')
      expect(hash[:duration]).to eq(1.5)
      expect(hash[:started_at]).to eq(started)
      expect(hash[:error]).to eq(error)
      expect(hash[:status]).to eq(:failed)
    end

    it 'handles missing optional fields' do
      result = described_class.new(step_name: :minimal)

      hash = result.to_h

      expect(hash[:step_name]).to eq(:minimal)
      expect(hash[:output]).to be_nil
      expect(hash[:duration]).to be_nil
      expect(hash[:started_at]).to be_nil
      expect(hash[:error]).to be_nil
      expect(hash[:status]).to eq(:success)
    end
  end

  describe '#inspect formatting' do
    it 'shows nil duration as nil' do
      result = described_class.new(step_name: :test, status: :success)
      expect(result.inspect).to include('duration=')
    end

    it 'rounds duration in inspect' do
      result = described_class.new(step_name: :test, duration: 0.123456789, status: :success)
      expect(result.inspect).to include('0.1235')
    end
  end
end

RSpec.describe Flowline::Result do
  describe 'empty result' do
    it 'is successful when empty' do
      result = described_class.new
      expect(result).to be_success
      expect(result).not_to be_failed
    end

    it 'has no completed steps' do
      result = described_class.new
      expect(result.completed_steps).to be_empty
    end

    it 'has empty outputs' do
      result = described_class.new
      expect(result.outputs).to eq({})
    end

    it 'has nil duration when no timestamps' do
      result = described_class.new
      expect(result.duration).to be_nil
    end
  end

  describe 'multiple step results' do
    let(:step_a) { Flowline::StepResult.new(step_name: :a, output: 1, status: :success) }
    let(:step_b) { Flowline::StepResult.new(step_name: :b, output: 2, status: :success) }
    let(:step_c) { Flowline::StepResult.new(step_name: :c, output: 3, status: :success) }

    it 'tracks multiple successful steps' do
      result = described_class.new(step_results: { a: step_a, b: step_b, c: step_c })

      expect(result).to be_success
      expect(result.completed_steps).to contain_exactly(:a, :b, :c)
    end

    it 'outputs returns all step outputs' do
      result = described_class.new(step_results: { a: step_a, b: step_b, c: step_c })

      expect(result.outputs).to eq({ a: 1, b: 2, c: 3 })
    end

    it 'fails if any step failed' do
      failed = Flowline::StepResult.new(step_name: :failed, error: StandardError.new)
      result = described_class.new(step_results: { a: step_a, failed: failed, c: step_c })

      expect(result).to be_failed
    end
  end

  describe 'timing' do
    it 'calculates duration correctly' do
      started = Time.now
      finished = started + 5.5

      result = described_class.new(started_at: started, finished_at: finished)

      expect(result.duration).to eq(5.5)
    end

    it 'handles sub-second durations' do
      started = Time.now
      finished = started + 0.001

      result = described_class.new(started_at: started, finished_at: finished)

      expect(result.duration).to be_within(0.0001).of(0.001)
    end

    it 'duration is nil with only started_at' do
      result = described_class.new(started_at: Time.now)
      expect(result.duration).to be_nil
    end

    it 'duration is nil with only finished_at' do
      result = described_class.new(finished_at: Time.now)
      expect(result.duration).to be_nil
    end
  end

  describe '#to_h' do
    it 'includes error message when present' do
      error = StandardError.new('something went wrong')
      result = described_class.new(error: error)

      hash = result.to_h

      expect(hash[:error]).to eq('something went wrong')
      expect(hash[:success]).to be false
    end

    it 'has nil error when no error' do
      result = described_class.new

      hash = result.to_h

      expect(hash[:error]).to be_nil
      expect(hash[:success]).to be true
    end

    it 'includes nested step results' do
      step = Flowline::StepResult.new(step_name: :test, output: 'value', status: :success)
      result = described_class.new(step_results: { test: step })

      hash = result.to_h

      expect(hash[:steps][:test][:output]).to eq('value')
      expect(hash[:steps][:test][:status]).to eq(:success)
    end
  end

  describe '#[]' do
    it 'returns nil for missing step' do
      result = described_class.new(step_results: {})
      expect(result[:nonexistent]).to be_nil
    end

    it 'works with symbol key' do
      step = Flowline::StepResult.new(step_name: :test, output: 42, status: :success)
      result = described_class.new(step_results: { test: step })

      expect(result[:test].output).to eq(42)
    end

    it 'works with string key converted to symbol' do
      step = Flowline::StepResult.new(step_name: :test, output: 42, status: :success)
      result = described_class.new(step_results: { test: step })

      expect(result['test'].output).to eq(42)
    end
  end

  describe '#inspect' do
    it 'shows step count' do
      steps = {
        a: Flowline::StepResult.new(step_name: :a, status: :success),
        b: Flowline::StepResult.new(step_name: :b, status: :success),
        c: Flowline::StepResult.new(step_name: :c, status: :success)
      }
      result = described_class.new(step_results: steps)

      expect(result.inspect).to include('steps=3')
    end

    it 'shows duration when available' do
      result = described_class.new(
        started_at: Time.now,
        finished_at: Time.now + 1.2345
      )

      expect(result.inspect).to include('duration=1.2345')
    end

    it 'shows nil duration when not available' do
      result = described_class.new

      expect(result.inspect).to include('duration=')
    end
  end

  describe 'success determination' do
    it 'is failed if result has error even with successful steps' do
      step = Flowline::StepResult.new(step_name: :ok, output: 1, status: :success)
      result = described_class.new(
        step_results: { ok: step },
        error: StandardError.new('pipeline error')
      )

      expect(result).to be_failed
    end

    it 'is failed if any step failed even without result error' do
      ok_step = Flowline::StepResult.new(step_name: :ok, output: 1, status: :success)
      failed_step = Flowline::StepResult.new(step_name: :failed, error: StandardError.new)
      result = described_class.new(step_results: { ok: ok_step, failed: failed_step })

      expect(result).to be_failed
    end

    it 'is successful only when no error and all steps successful' do
      step_a = Flowline::StepResult.new(step_name: :a, output: 1, status: :success)
      step_b = Flowline::StepResult.new(step_name: :b, output: 2, status: :success)
      result = described_class.new(step_results: { a: step_a, b: step_b })

      expect(result).to be_success
    end
  end
end
