# Piperb

A Ruby dataflow and pipeline library with declarative step definitions, automatic dependency resolution, parallel/sequential execution, and built-in retry/timeout support.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'piperb'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install piperb
```

## Features

- **Declarative step definitions** - Define what each step does, not how to orchestrate them
- **Automatic dependency resolution** - Steps execute in the correct order based on dependencies
- **Parallel execution** - Independent steps run concurrently using threads
- **Retries with backoff** - Automatic retry with linear or exponential backoff strategies
- **Timeouts** - Per-step execution time limits
- **Conditional execution** - Skip steps based on runtime conditions
- **Luigi-style caching** - Resume failed pipelines from the last successful step
- **Zero runtime dependencies** - Pure Ruby using only stdlib

## Quick Start

```ruby
require 'piperb'

pipeline = Piperb.define do
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

## Usage

### Basic Pipeline

```ruby
pipeline = Piperb.define do
  step :fetch_users do
    User.all.to_a
  end

  step :enrich, depends_on: :fetch_users do |users|
    users.map { |u| enrich_from_api(u) }
  end

  step :export_csv, depends_on: :enrich do |users|
    CSV.generate { |csv| users.each { |u| csv << u.to_a } }
  end

  step :export_json, depends_on: :enrich do |users|
    users.to_json
  end

  # Multiple dependencies - outputs passed as keyword arguments
  step :notify, depends_on: [:export_csv, :export_json] do |export_csv:, export_json:|
    Notifier.send("Exported #{export_csv.lines.count} rows")
  end
end

result = pipeline.run
```

### Parallel Execution

Steps at the same "level" (no inter-dependencies) run concurrently:

```ruby
pipeline = Piperb.define do
  step :fetch_users do
    fetch_from_api("/users")
  end

  step :fetch_orders do
    fetch_from_api("/orders")
  end

  # fetch_users and fetch_orders run in parallel

  step :generate_report, depends_on: [:fetch_users, :fetch_orders] do |fetch_users:, fetch_orders:|
    { users: fetch_users, orders: fetch_orders }
  end
end

# Parallel execution
result = pipeline.run(executor: :parallel)

# Parallel with thread limit
result = pipeline.run(executor: :parallel, max_threads: 4)
```

### Step Retries

Steps can be configured to automatically retry on failure:

```ruby
pipeline = Piperb.define do
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

### Step Timeouts

Steps can be configured with execution timeouts:

```ruby
pipeline = Piperb.define do
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

### Conditional Execution

Steps can be conditionally executed based on runtime conditions:

```ruby
pipeline = Piperb.define do
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
result[:feature_a].skipped?    # => false
```

**Conditional Behavior:**
- `if: condition` - Runs step only when condition returns truthy
- `unless: condition` - Skips step when condition returns truthy
- Skipped steps return `nil` output with `:skipped` status
- Dependent steps receive `nil` for skipped dependency outputs
- Skipped steps don't count as failures (pipeline still succeeds)

### Caching (Luigi-style)

Steps can be cached to enable resuming failed pipelines from the last successful step:

```ruby
# Using a file-based cache (persists across runs)
pipeline.run(cache: './cache')

# Using a memory cache (for testing)
cache = Piperb::Cache::MemoryStore.new
pipeline.run(cache: cache)

# Force re-execution (ignores cache)
pipeline.run(cache: './cache', force: true)
```

#### Step-level Cache Control

```ruby
pipeline = Piperb.define do
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

#### Resume Failed Pipeline

```ruby
# First run - step 2 fails, but step 1 is cached
begin
  pipeline.run(cache: './cache')
rescue Piperb::StepError
  puts "Pipeline failed, but progress was saved"
end

# Second run - step 1 loads from cache, step 2 retries
result = pipeline.run(cache: './cache')
```

**Cache Options:**
- `cache: path` - File-based cache directory
- `cache: store` - Custom cache store implementing `Piperb::Cache::Base`
- `force: true` - Ignore cache and re-execute all steps
- Step option `cache: false` - Disable caching for specific steps
- Step option `cache_key: lambda` - Custom cache key based on input

### Input Passing Strategy

- **No dependencies**: receives `initial_input` or empty args
- **Single dependency**: output passed directly as argument
- **Multiple dependencies**: outputs passed as keyword arguments

```ruby
# Single dependency - direct argument
step :process, depends_on: :fetch do |data|
  data.map(&:transform)
end

# Multiple dependencies - keyword arguments
step :merge, depends_on: [:csv, :json] do |csv:, json:|
  { csv: csv, json: json }
end

# Initial input
result = pipeline.run(initial_input: { date: Date.today })
```

### Mermaid Diagram Generation

```ruby
pipeline = Piperb.define do
  step :fetch do; end
  step :process, depends_on: :fetch do |_|; end
  step :save, depends_on: :process do |_|; end
end

puts pipeline.to_mermaid
# graph TD
#   fetch --> process
#   process --> save
```

## Error Handling

```ruby
Piperb::Error                    # Base error
Piperb::CycleError               # Circular dependency detected
Piperb::MissingDependencyError   # Unknown dependency referenced
Piperb::DuplicateStepError       # Step name already exists
Piperb::StepError                # Step execution failed
Piperb::TimeoutError             # Step exceeded timeout duration
```

`StepError` wraps the original error and includes partial results:

```ruby
begin
  pipeline.run
rescue Piperb::StepError => e
  e.step_name       # => :failed_step
  e.original_error  # => the underlying exception
  e.partial_results # => results from completed steps
end
```

## Development

```bash
bundle install
bundle exec rspec          # Run tests (597 examples)
bundle exec rubocop        # Run linter
bundle exec rake           # Run both tests and linter
```

## Test Coverage

- Line Coverage: ~97%
- Branch Coverage: ~90%
- 597 test examples

## Requirements

- Ruby >= 3.1.0
- No runtime dependencies (pure Ruby, stdlib only)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
