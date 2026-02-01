# Flowrb

A Ruby dataflow and pipeline library with declarative step definitions, automatic dependency resolution, parallel/sequential execution, and built-in retry/timeout support.

## Project Structure

```
flowrb/
├── lib/
│   ├── flowrb.rb                    # Main module entry point
│   └── flowrb/
│       ├── version.rb                 # VERSION = "0.1.0"
│       ├── errors.rb                  # Error, CycleError, StepError, TimeoutError
│       ├── step.rb                    # Step class (name, deps, callable, retry/timeout)
│       ├── dag.rb                     # DAG with TSort, cycle detection, levels
│       ├── result.rb                  # Result + StepResult classes
│       ├── pipeline.rb                # Pipeline DSL
│       └── executor/
│           ├── base.rb                # Abstract executor with retry/timeout logic
│           ├── sequential.rb          # Sequential execution
│           └── parallel.rb            # Parallel execution
├── spec/
│   ├── spec_helper.rb
│   ├── flowrb/                      # Unit tests
│   └── integration/                   # Integration tests
```

## Core Concepts

### Step
Immutable unit of work with name, dependencies, callable, and optional retry/timeout configuration.

### DAG
Directed Acyclic Graph using Ruby's TSort for topological sorting and cycle detection. Provides `#levels` method to group steps by execution level for parallel execution.

### Pipeline
User-facing DSL for defining and running pipelines via `Flowrb.define { ... }`.

### Result/StepResult
Execution results with output, duration, timing, retry count, and error information.

### Executors
- **Sequential** (default): Executes steps one at a time in topological order
- **Parallel**: Executes independent steps concurrently using threads

## Usage Example

```ruby
pipeline = Flowrb.define do
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

# Sequential execution (default)
result = pipeline.run
result.success?           # => true
result[:load].output      # => 12
result[:load].duration    # => 0.001

# Parallel execution
result = pipeline.run(executor: :parallel)

# Parallel with thread limit
result = pipeline.run(executor: :parallel, max_threads: 4)
```

## Step Retries

Steps can be configured to automatically retry on failure:

```ruby
pipeline = Flowrb.define do
  step :fetch_api, retries: 3, retry_delay: 2 do
    HTTP.get("https://api.example.com/data")
  end

  # Exponential backoff: delays of 1s, 2s, 4s
  step :flaky_service, retries: 3, retry_delay: 1, retry_backoff: :exponential do
    ExternalService.call
  end

  # Linear backoff: delays of 1s, 2s, 3s
  step :another_service, retries: 3, retry_delay: 1, retry_backoff: :linear do
    AnotherService.call
  end

  # Conditional retry - only retry on specific errors
  step :selective_retry, retries: 3, retry_if: ->(error) { error.is_a?(IOError) } do
    risky_operation
  end
end

result = pipeline.run
result[:fetch_api].retries  # => number of retries that occurred
```

**Retry Options:**
- `retries: n` - Maximum retry attempts (default: 0)
- `retry_delay: seconds` - Wait time between retries (default: 0)
- `retry_backoff: :exponential | :linear` - Backoff strategy for delays
- `retry_if: ->(error) { ... }` - Only retry if condition returns true

## Step Timeouts

Steps can be configured with execution timeouts:

```ruby
pipeline = Flowrb.define do
  step :slow_operation, timeout: 30 do
    # Will raise TimeoutError if not complete in 30 seconds
    long_running_computation
  end

  # Combine timeout with retries
  step :unreliable, timeout: 10, retries: 3, retry_delay: 5 do
    external_api_call
  end
end

result = pipeline.run
result[:slow_operation].timed_out?  # => true if step timed out
```

**Timeout Options:**
- `timeout: seconds` - Maximum execution time for the step

## Conditional Execution

Steps can be conditionally executed based on runtime conditions:

```ruby
pipeline = Flowrb.define do
  step :config do
    { feature_enabled: true, skip_export: false }
  end

  # Only runs when if: condition returns truthy
  step :feature_a, depends_on: :config, if: ->(cfg) { cfg[:feature_enabled] } do |cfg|
    'feature A result'
  end

  # Skipped when unless: condition returns truthy
  step :export, depends_on: :config, unless: ->(cfg) { cfg[:skip_export] } do |cfg|
    'export result'
  end

  # Handles nil from skipped dependency
  step :finalize, depends_on: :feature_a do |input|
    input.nil? ? 'dependency was skipped' : "got: #{input}"
  end
end

result = pipeline.run
result[:feature_a].output      # => 'feature A result'
result[:feature_a].skipped?    # => false
result[:export].skipped?       # => false (unless was false)
```

**Conditional Behavior:**
- `if: condition` - Runs step only when condition returns truthy
- `unless: condition` - Skips step when condition returns truthy
- When both `if:` and `unless:` are present, `if:` takes precedence
- Conditions receive the same input as the step (initial input or dependency outputs)
- Skipped steps return `nil` output with `:skipped` status
- Dependent steps receive `nil` for skipped dependency outputs
- Skipped steps don't count as failures (pipeline still succeeds)
- Retries and timeouts are not applied to skipped steps

## Caching (Luigi-style)

Steps can be cached to enable resuming failed pipelines from the last successful step:

```ruby
# Using a file-based cache (persists across runs)
pipeline.run(cache: './cache')

# Using a memory cache (for testing)
cache = Flowrb::Cache::MemoryStore.new
pipeline.run(cache: cache)

# Force re-execution (ignores cache)
pipeline.run(cache: './cache', force: true)
```

### Step-level Cache Control

```ruby
pipeline = Flowrb.define do
  # This step is cached (default behavior)
  step :fetch_data do
    expensive_api_call
  end

  # This step is never cached
  step :current_time, cache: false do
    Time.now
  end

  # Custom cache key based on input
  step :process, depends_on: :fetch_data, cache_key: ->(input) { "process_#{input[:id]}" } do |data|
    transform(data)
  end
end
```

### Resume Failed Pipeline

```ruby
# First run - step 2 fails, but step 1 is cached
begin
  pipeline.run(cache: './cache')
rescue Flowrb::StepError
  puts "Pipeline failed, but progress was saved"
end

# Second run - step 1 loads from cache, step 2 retries
result = pipeline.run(cache: './cache')
```

**Cache Options:**
- `cache: path` - File-based cache directory (creates `Flowrb::Cache::FileStore`)
- `cache: store` - Custom cache store implementing `Flowrb::Cache::Base`
- `force: true` - Ignore cache and re-execute all steps
- Step option `cache: false` - Disable caching for specific steps
- Step option `cache_key: lambda` - Custom cache key based on input

## Parallel Execution

Steps at the same "level" (no inter-dependencies) run concurrently:

```ruby
pipeline = Flowrb.define do
  step :fetch_users do
    # Runs first (level 0)
    fetch_from_api("/users")
  end

  step :fetch_orders do
    # Runs in parallel with fetch_users (level 0)
    fetch_from_api("/orders")
  end

  step :process_users, depends_on: :fetch_users do |users|
    # Runs after fetch_users (level 1)
    users.map(&:normalize)
  end

  step :process_orders, depends_on: :fetch_orders do |orders|
    # Runs in parallel with process_users (level 1)
    orders.map(&:normalize)
  end

  step :generate_report, depends_on: [:process_users, :process_orders] do |process_users:, process_orders:|
    # Runs last (level 2)
    { users: process_users, orders: process_orders }
  end
end

# Parallel execution - fetch_users and fetch_orders run simultaneously
result = pipeline.run(executor: :parallel)
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

- `Flowrb::Error` - Base error
- `Flowrb::CycleError` - Circular dependency detected
- `Flowrb::MissingDependencyError` - Unknown dependency referenced
- `Flowrb::DuplicateStepError` - Step name already exists
- `Flowrb::StepError` - Step execution failed (wraps original error, includes partial_results)
- `Flowrb::TimeoutError` - Step exceeded timeout duration

## Mermaid Diagram Generation

```ruby
pipeline = Flowrb.define do
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
bundle exec rspec          # Run tests (454 examples)
bundle exec rubocop        # Run linter
bundle exec rake           # Run both tests and linter
```

## Test Coverage

- Line Coverage: ~97%
- Branch Coverage: ~90%
- 597 test examples covering:
  - Unit tests for Step, DAG, Result, Pipeline, Executor (Sequential + Parallel)
  - Extended edge case tests for all components
  - Integration tests for basic pipelines and error handling
  - Data transformation pipeline tests
  - Stability and rerun tests
  - Real-world scenario tests (user registration, data export, order processing, etc.)
  - Parallel execution tests (concurrency, thread limits, error handling)
  - DAG patterns (diamond, fan-out, fan-in, tree reduction, mesh topology)
  - Validation edge cases (cycles, missing deps, duplicates)
  - Step retry tests (retry counts, delays, backoff strategies, conditional retries)
  - Step timeout tests (timeout enforcement, timeout with retries)
  - Conditional execution tests (if/unless conditions, skipped steps, dependency handling)
  - Caching tests (file store, memory store, cache invalidation, resume from failure)

## Dependencies

- **Runtime**: None (pure Ruby, stdlib only - uses TSort, Mutex, Thread, Timeout)
- **Development**: rspec, rubocop, rubocop-rspec, simplecov
- **Ruby version**: >= 3.1.0

## Future Phases

Remaining features for future phases:
- Async/concurrent executors (e.g., with Async gem)
- Pipeline composition
