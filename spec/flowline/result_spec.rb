# frozen_string_literal: true

RSpec.describe Flowline::StepResult do
  describe '#initialize' do
    it 'creates a step result with all attributes' do
      started = Time.now
      result = described_class.new(
        step_name: :fetch,
        output: [1, 2, 3],
        duration: 0.5,
        started_at: started,
        status: :success
      )

      expect(result.step_name).to eq(:fetch)
      expect(result.output).to eq([1, 2, 3])
      expect(result.duration).to eq(0.5)
      expect(result.started_at).to eq(started)
    end
  end

  describe '#status' do
    it 'returns :success when no error' do
      result = described_class.new(step_name: :fetch, output: 42)
      expect(result.status).to eq(:success)
    end

    it 'returns :failed when error present' do
      result = described_class.new(step_name: :fetch, error: StandardError.new)
      expect(result.status).to eq(:failed)
    end

    it 'returns explicit status when provided' do
      result = described_class.new(step_name: :fetch, status: :skipped)
      expect(result.status).to eq(:skipped)
    end
  end

  describe '#success?' do
    it 'returns true for successful result' do
      result = described_class.new(step_name: :fetch, output: 42, status: :success)
      expect(result).to be_success
    end

    it 'returns false for failed result' do
      result = described_class.new(step_name: :fetch, error: StandardError.new)
      expect(result).not_to be_success
    end
  end

  describe '#failed? and #failure?' do
    it 'returns true for failed result' do
      result = described_class.new(step_name: :fetch, error: StandardError.new)
      expect(result).to be_failed
      expect(result).to be_failure
    end

    it 'returns false for successful result' do
      result = described_class.new(step_name: :fetch, output: 42, status: :success)
      expect(result).not_to be_failed
    end
  end

  describe '#to_h' do
    it 'returns hash representation' do
      started = Time.now
      result = described_class.new(
        step_name: :fetch,
        output: 42,
        duration: 0.5,
        started_at: started,
        status: :success
      )

      hash = result.to_h
      expect(hash[:step_name]).to eq(:fetch)
      expect(hash[:output]).to eq(42)
      expect(hash[:status]).to eq(:success)
    end
  end

  describe '#inspect' do
    it 'returns readable inspection' do
      result = described_class.new(step_name: :fetch, output: 42, duration: 0.12345, status: :success)
      expect(result.inspect).to include('step=:fetch')
      expect(result.inspect).to include('status=:success')
      expect(result.inspect).to include('duration=0.1235')
    end
  end
end

RSpec.describe Flowline::Result do
  let(:step_result) do
    Flowline::StepResult.new(step_name: :fetch, output: [1, 2, 3], status: :success)
  end

  describe '#initialize' do
    it 'creates a result with step results' do
      result = described_class.new(step_results: { fetch: step_result })
      expect(result.step_results[:fetch]).to eq(step_result)
    end
  end

  describe '#[]' do
    it 'accesses step results by name' do
      result = described_class.new(step_results: { fetch: step_result })
      expect(result[:fetch]).to eq(step_result)
    end

    it 'converts string keys to symbols' do
      result = described_class.new(step_results: { fetch: step_result })
      expect(result['fetch']).to eq(step_result)
    end
  end

  describe '#success?' do
    it 'returns true when all steps succeeded' do
      result = described_class.new(step_results: { fetch: step_result })
      expect(result).to be_success
    end

    it 'returns false when any step failed' do
      failed = Flowline::StepResult.new(step_name: :process, error: StandardError.new)
      result = described_class.new(step_results: { fetch: step_result, process: failed })
      expect(result).not_to be_success
    end

    it 'returns false when result has an error' do
      result = described_class.new(
        step_results: { fetch: step_result },
        error: StandardError.new('pipeline error')
      )
      expect(result).not_to be_success
    end

    it 'returns true for empty result' do
      result = described_class.new
      expect(result).to be_success
    end
  end

  describe '#failed? and #failure?' do
    it 'returns true when not successful' do
      result = described_class.new(error: StandardError.new)
      expect(result).to be_failed
      expect(result).to be_failure
    end
  end

  describe '#duration' do
    it 'calculates duration from timestamps' do
      started = Time.now
      finished = started + 1.5
      result = described_class.new(started_at: started, finished_at: finished)
      expect(result.duration).to eq(1.5)
    end

    it 'returns nil when timestamps missing' do
      result = described_class.new
      expect(result.duration).to be_nil
    end
  end

  describe '#outputs' do
    it 'returns hash of step outputs' do
      result1 = Flowline::StepResult.new(step_name: :a, output: 1, status: :success)
      result2 = Flowline::StepResult.new(step_name: :b, output: 2, status: :success)
      result = described_class.new(step_results: { a: result1, b: result2 })

      expect(result.outputs).to eq({ a: 1, b: 2 })
    end
  end

  describe '#completed_steps' do
    it 'returns list of completed step names' do
      result1 = Flowline::StepResult.new(step_name: :a, output: 1, status: :success)
      result2 = Flowline::StepResult.new(step_name: :b, output: 2, status: :success)
      result = described_class.new(step_results: { a: result1, b: result2 })

      expect(result.completed_steps).to contain_exactly(:a, :b)
    end
  end

  describe '#to_h' do
    it 'returns hash representation' do
      started = Time.now
      finished = started + 1.0
      result = described_class.new(
        step_results: { fetch: step_result },
        started_at: started,
        finished_at: finished
      )

      hash = result.to_h
      expect(hash[:success]).to be true
      expect(hash[:duration]).to eq(1.0)
      expect(hash[:steps]).to have_key(:fetch)
    end
  end

  describe '#inspect' do
    it 'returns readable inspection for success' do
      result = described_class.new(step_results: { fetch: step_result })
      expect(result.inspect).to include('status=success')
      expect(result.inspect).to include('steps=1')
    end

    it 'returns readable inspection for failure' do
      result = described_class.new(error: StandardError.new)
      expect(result.inspect).to include('status=failed')
    end
  end
end
