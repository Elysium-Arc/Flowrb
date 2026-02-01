# Flowline

A Ruby dataflow and pipeline library with declarative step definitions, automatic dependency resolution, and sequential execution.

## Project Structure

```
flowline/
├── lib/
│   ├── flowline.rb                    # Main module entry point
│   └── flowline/
│       ├── version.rb                 # VERSION = "0.1.0"
│       ├── errors.rb                  # Error, CycleError, StepError, etc.
│       ├── step.rb                    # Step class (name, deps, callable)
│       ├── dag.rb                     # DAG with TSort, cycle detection
│       ├── result.rb                  # Result + StepResult classes
│       ├── pipeline.rb                # Pipeline DSL
│       └── executor/
│           ├── base.rb                # Abstract executor
│           └── sequential.rb          # Sequential execution
├── spec/
│   ├── spec_helper.rb
│   ├── flowline/                      # Unit tests
│   └── integration/                   # Integration tests
```

## Core Concepts

### Step
Immutable unit of work with name, dependencies, and callable (block/Proc/lambda).

### DAG
Directed Acyclic Graph using Ruby's TSort for topological sorting and cycle detection.

### Pipeline
User-facing DSL for defining and running pipelines via `Flowline.define { ... }`.

### Result/StepResult
Execution results with output, duration, timing, and error information.

## Usage Example

```ruby
pipeline = Flowline.define do
  step :fetch do
    [1, 2, 3]
  end

  step :transform, depends_on: :fetch do |data|
    data.map { |n| n * 2 }
  end

  step :load, depends_on: :transform do |data|
    data.sum
  end
end

result = pipeline.run
result.success?           # => true
result[:load].output      # => 12
result[:load].duration    # => 0.001
```

## Input Passing Strategy

- **No dependencies**: receives `initial_input` or empty args
- **Single dependency**: output passed directly as argument
- **Multiple dependencies**: outputs passed as keyword arguments

```ruby
step :merge, depends_on: [:csv, :json] do |csv:, json:|
  # csv and json are keyword args from upstream steps
end
```

## Error Hierarchy

- `Flowline::Error` - Base error
- `Flowline::CycleError` - Circular dependency detected
- `Flowline::MissingDependencyError` - Unknown dependency referenced
- `Flowline::DuplicateStepError` - Step name already exists
- `Flowline::StepError` - Step execution failed (wraps original error)

## Mermaid Diagram Generation

```ruby
pipeline = Flowline.define do
  step :fetch do; end
  step :process, depends_on: :fetch do |_|; end
  step :save, depends_on: :process do |_|; end
end

puts pipeline.to_mermaid
# graph TD
#   fetch --> process
#   process --> save
```

## Development

```bash
bundle install
bundle exec rspec          # Run tests (304 examples)
bundle exec rubocop        # Run linter
bundle exec rake           # Run both tests and linter
```

## Test Coverage

- Line Coverage: ~98%
- Branch Coverage: ~88%
- 304 test examples covering:
  - Unit tests for Step, DAG, Result, Pipeline, Executor
  - Extended edge case tests for all components
  - Integration tests for basic pipelines and error handling
  - Data transformation pipeline tests
  - Stability and rerun tests
  - Real-world scenario tests (user registration, data export, order processing, etc.)

## Dependencies

- **Runtime**: None (pure Ruby, stdlib only - uses TSort)
- **Development**: rspec, rubocop, rubocop-rspec, simplecov
- **Ruby version**: >= 3.1.0

## Future Phases

This is Phase 1 (foundation). Future phases may include:
- Parallel execution
- Async/concurrent executors
- Step retries and timeouts
- Conditional step execution
- Pipeline composition
