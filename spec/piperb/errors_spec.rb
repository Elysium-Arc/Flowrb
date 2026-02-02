# frozen_string_literal: true

RSpec.describe Piperb::Error do
  it 'is a StandardError' do
    expect(described_class.superclass).to eq(StandardError)
  end
end

RSpec.describe Piperb::CycleError do
  it 'is a Piperb::Error' do
    expect(described_class.superclass).to eq(Piperb::Error)
  end

  it 'accepts a cycle parameter' do
    error = described_class.new('Cycle detected', cycle: %i[a b a])
    expect(error.cycle).to eq(%i[a b a])
  end

  it 'has a default message' do
    error = described_class.new
    expect(error.message).to eq('Circular dependency detected')
  end
end

RSpec.describe Piperb::MissingDependencyError do
  it 'is a Piperb::Error' do
    expect(described_class.superclass).to eq(Piperb::Error)
  end

  it 'accepts step_name and missing_dependency parameters' do
    error = described_class.new(
      'Missing dep',
      step_name: :process,
      missing_dependency: :fetch
    )
    expect(error.step_name).to eq(:process)
    expect(error.missing_dependency).to eq(:fetch)
  end
end

RSpec.describe Piperb::DuplicateStepError do
  it 'is a Piperb::Error' do
    expect(described_class.superclass).to eq(Piperb::Error)
  end

  it 'accepts step_name parameter' do
    error = described_class.new('Duplicate', step_name: :fetch)
    expect(error.step_name).to eq(:fetch)
  end
end

RSpec.describe Piperb::StepError do
  it 'is a Piperb::Error' do
    expect(described_class.superclass).to eq(Piperb::Error)
  end

  it 'accepts step_name, original_error, and partial_results' do
    original = StandardError.new('boom')
    partial = Piperb::Result.new

    error = described_class.new(
      'Step failed',
      step_name: :process,
      original_error: original,
      partial_results: partial
    )

    expect(error.step_name).to eq(:process)
    expect(error.original_error).to eq(original)
    expect(error.partial_results).to eq(partial)
  end
end
