# Flowrb 🌊
## A Ruby Dataflow & Pipeline Library

**Tagline:** Composable data pipelines with dependency resolution, caching, and parallel execution.

**Inspired by:** Luigi, Prefect, Dagster (Python), RxJS (JS)

---

# Project Overview

## Vision
Flowrb enables Ruby developers to build declarative data pipelines where steps are defined once, dependencies are resolved automatically, execution is parallelized where possible, and failures are handled gracefully with retries and resumption.

## Core Value Propositions
1. **Declarative** - Define what, not how. Dependencies are explicit.
2. **Resilient** - Built-in retries, checkpointing, and resume from failure.
3. **Observable** - Know what's running, what failed, and why.
4. **Fast** - Parallel execution, result caching, incremental runs.
5. **Simple** - No external services required. Pure Ruby.

## Target Users
- Data engineers building ETL pipelines
- Backend developers with complex background jobs
- DevOps engineers automating workflows
- Anyone replacing brittle rake task chains

---

# 6-Week Plan | 4 Phases

```
┌─────────────────────────────────────────────────────────────────────┐
│ Phase 1: Foundation        │ Week 1-2 │ Core DAG + Basic Execution │
│ Phase 2: Resilience        │ Week 3   │ Caching, Retries, Recovery │
│ Phase 3: Power Features    │ Week 4-5 │ Parallel, Hooks, Reporting │
│ Phase 4: Polish & Release  │ Week 6   │ Docs, CLI, Gem Release     │
└─────────────────────────────────────────────────────────────────────┘
```

---

# Phase 1: Foundation (Week 1-2)
## Goal: Working DAG execution with basic features

### Week 1: Core Architecture

#### Day 1-2: Project Setup
- [ ] Initialize gem structure (`bundle gem flowrb`)
- [ ] Setup RSpec, RuboCop, GitHub Actions CI
- [ ] Create README with vision and planned API
- [ ] Define module structure:
  ```
  lib/
    flowrb.rb
    flowrb/
      version.rb
      pipeline.rb
      step.rb
      dag.rb
      result.rb
      errors.rb
  ```

#### Day 3-4: Step Definition
- [ ] `Flowrb::Step` class
  - Name (symbol)
  - Dependencies (array of step names)
  - Callable (block/proc/lambda)
  - Options (timeout, retries, etc.)
- [ ] Step DSL for clean definition
- [ ] Input/output type hints (optional, for documentation)

**Deliverable: Step Definition API**
```ruby
step = Flowrb::Step.new(:process_users) do |input|
  input[:users].map { |u| transform(u) }
end

step.call(users: [...])  # => transformed array
```

#### Day 5-7: DAG Construction
- [ ] `Flowrb::DAG` class
  - Add steps with dependencies
  - Topological sort algorithm
  - Cycle detection with clear error messages
  - Dependency validation (missing deps)
- [ ] Visualize DAG (simple ASCII or mermaid output)

**Deliverable: DAG Building**
```ruby
dag = Flowrb::DAG.new
dag.add(:fetch, -> { fetch_data })
dag.add(:transform, -> (data) { transform(data) }, depends_on: :fetch)
dag.add(:load, -> (data) { load(data) }, depends_on: :transform)

dag.sorted_steps  # => [:fetch, :transform, :load]
dag.to_mermaid    # => "graph TD\n  fetch --> transform\n  ..."
```

---

### Week 2: Pipeline Execution

#### Day 1-2: Sequential Executor
- [ ] `Flowrb::Executor::Sequential`
  - Execute steps in topological order
  - Pass outputs as inputs to dependents
  - Collect results from all steps
- [ ] `Flowrb::Result` to hold execution results
  - Success/failure status per step
  - Timing information
  - Output data

**Deliverable: Basic Execution**
```ruby
executor = Flowrb::Executor::Sequential.new(dag)
result = executor.run

result.success?           # => true
result[:transform].output # => transformed data
result[:transform].duration # => 0.234
```

#### Day 3-4: Pipeline DSL
- [ ] `Flowrb::Pipeline` class with clean DSL
- [ ] `Flowrb.define` entry point
- [ ] Support for both block and class-based steps

**Deliverable: Pipeline DSL**
```ruby
pipeline = Flowrb.define do
  step :fetch_users do
    User.all.to_a
  end

  step :enrich, depends_on: :fetch_users do |users|
    users.map { |u| enrich_from_api(u) }
  end

  step :validate, depends_on: :enrich do |users|
    users.select(&:valid?)
  end

  # Fan-out: multiple steps depend on :validate
  step :export_csv, depends_on: :validate do |users|
    CSV.generate { |csv| users.each { |u| csv << u.to_a } }
  end

  step :export_json, depends_on: :validate do |users|
    users.to_json
  end

  # Fan-in: step depends on multiple
  step :notify, depends_on: [:export_csv, :export_json] do |csv:, json:|
    Notifier.send("Exported #{csv.lines.count} rows")
  end
end

result = pipeline.run
```

#### Day 5-6: Error Handling
- [ ] `Flowrb::StepError` with context
- [ ] Capture step that failed + original exception
- [ ] Partial results on failure (successful steps preserved)
- [ ] `result.failed_step`, `result.error`

#### Day 7: Week 2 Testing & Refactor
- [ ] Comprehensive specs for all components
- [ ] Edge cases: empty pipeline, single step, complex DAG
- [ ] Refactor based on learnings

**Phase 1 Milestone:** ✅ Working pipeline with sequential execution

---

# Phase 2: Resilience (Week 3)
## Goal: Production-ready reliability features

### Week 3: Caching, Retries, Checkpointing

#### Day 1-2: Result Caching
- [ ] `Flowrb::Cache` interface
  - `#get(key)`, `#set(key, value, ttl:)`, `#exists?(key)`
- [ ] `Flowrb::Cache::Memory` (default, in-process)
- [ ] `Flowrb::Cache::File` (persist to disk)
- [ ] Cache key generation (step name + input hash)
- [ ] TTL support
- [ ] `skip_cache: true` option per step

**Deliverable: Caching**
```ruby
pipeline = Flowrb.define do
  # Cache for 1 hour
  step :expensive_api_call, cache: { ttl: 3600 } do
    ExternalAPI.fetch_all
  end

  # Never cache
  step :always_fresh, cache: false do
    Time.now
  end
end

# Second run uses cache
pipeline.run  # hits API
pipeline.run  # uses cache
```

#### Day 3-4: Retry Logic
- [ ] Configurable retries per step
- [ ] Retry strategies:
  - `:immediate` - retry right away
  - `:linear` - wait N seconds between retries
  - `:exponential` - exponential backoff
- [ ] `retry_if` condition (retry only certain errors)
- [ ] `on_retry` callback

**Deliverable: Retries**
```ruby
step :flaky_api, 
     retries: 3, 
     retry_strategy: :exponential,
     retry_if: ->(e) { e.is_a?(Net::TimeoutError) } do
  FlakeyService.call
end
```

#### Day 5-6: Checkpointing & Resume
- [ ] `Flowrb::Checkpoint` to save pipeline state
- [ ] Persist completed step outputs
- [ ] `pipeline.run(resume: true)` - skip completed steps
- [ ] `pipeline.run(from: :step_name)` - start from specific step
- [ ] Clear checkpoints on full success

**Deliverable: Resume from Failure**
```ruby
result = pipeline.run
# => fails at :load step

# Fix the issue, then resume
result = pipeline.run(resume: true)
# => skips :fetch and :transform, runs :load

# Or restart from specific step
result = pipeline.run(from: :transform)
```

#### Day 7: Timeouts
- [ ] Per-step timeout configuration
- [ ] `Flowrb::TimeoutError`
- [ ] Global pipeline timeout

**Phase 2 Milestone:** ✅ Resilient execution with caching and recovery

---

# Phase 3: Power Features (Week 4-5)
## Goal: Parallel execution, observability, advanced patterns

### Week 4: Parallel Execution & Hooks

#### Day 1-3: Parallel Executor
- [ ] `Flowrb::Executor::Parallel`
- [ ] Thread pool with configurable size
- [ ] Execute independent steps concurrently
- [ ] Thread-safe result collection
- [ ] Respect dependencies (wait for upstream)

**Deliverable: Parallel Execution**
```ruby
pipeline = Flowrb.define do
  step :fetch_users do ... end
  step :fetch_products do ... end
  step :fetch_orders do ... end

  # These 3 run in parallel (no dependencies)

  step :merge, depends_on: [:fetch_users, :fetch_products, :fetch_orders] do |users:, products:, orders:|
    { users: users, products: products, orders: orders }
  end
end

# Use parallel executor
result = pipeline.run(executor: :parallel, max_threads: 4)
```

#### Day 4-5: Lifecycle Hooks
- [ ] Pipeline-level hooks:
  - `before_run`, `after_run`
  - `on_success`, `on_failure`
- [ ] Step-level hooks:
  - `before_step`, `after_step`
  - `on_step_success`, `on_step_failure`
  - `on_step_skip` (cached/conditional)
- [ ] Hook context with timing, metadata

**Deliverable: Hooks**
```ruby
pipeline = Flowrb.define do
  before_run do |context|
    Logger.info "Pipeline starting: #{context.pipeline_name}"
  end

  after_step do |step, result|
    Metrics.histogram("step.duration", result.duration, tags: { step: step.name })
  end

  on_failure do |error, context|
    Slack.notify("#alerts", "Pipeline failed: #{error.message}")
  end

  step :work do ... end
end
```

#### Day 6-7: Conditional Steps
- [ ] `when:` / `unless:` conditions
- [ ] Skip step based on runtime data
- [ ] `Flowrb::Skipped` result type

**Deliverable: Conditional Execution**
```ruby
step :send_notifications, 
     depends_on: :process,
     when: ->(ctx) { ctx[:environment] == "production" } do |data|
  Notifier.broadcast(data)
end
```

---

### Week 5: Observability & Advanced Patterns

#### Day 1-2: Execution Reporter
- [ ] `Flowrb::Reporter` interface
- [ ] `Flowrb::Reporter::Console` - pretty terminal output
- [ ] `Flowrb::Reporter::JSON` - structured logs
- [ ] Progress bar for long-running pipelines
- [ ] Step status indicators (✓ ✗ ⏭ ⏳)

**Deliverable: Pretty Output**
```
Pipeline: data_import
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ fetch_users      0.52s   1,234 records
✓ fetch_products   0.31s   5,678 records
✓ transform        1.24s
⏳ load            running...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Elapsed: 2.07s | Steps: 3/5
```

#### Day 3-4: Pipeline Composition
- [ ] Nested pipelines (pipeline as a step)
- [ ] `pipeline.include(other_pipeline)`
- [ ] Shared step libraries

**Deliverable: Composition**
```ruby
CommonSteps = Flowrb.define do
  step :validate do |data|
    raise "Empty!" if data.empty?
    data
  end
end

MainPipeline = Flowrb.define do
  include CommonSteps

  step :fetch do ... end
  step :process, depends_on: [:fetch, :validate] do ... end
end
```

#### Day 5-6: Input Parameters & Context
- [ ] Pipeline parameters (typed inputs)
- [ ] Runtime context passed to all steps
- [ ] Parameter validation before execution

**Deliverable: Parameters**
```ruby
pipeline = Flowrb.define do
  param :start_date, type: :date, required: true
  param :batch_size, type: :integer, default: 100

  step :fetch do |ctx|
    Record.where("created_at >= ?", ctx[:start_date])
          .limit(ctx[:batch_size])
  end
end

pipeline.run(start_date: Date.today - 7, batch_size: 500)
```

#### Day 7: Dry Run Mode
- [ ] `pipeline.run(dry_run: true)`
- [ ] Validate DAG without execution
- [ ] Show execution plan
- [ ] Estimate based on cached timings

**Phase 3 Milestone:** ✅ Full-featured pipeline library

---

# Phase 4: Polish & Release (Week 6)
## Goal: Production-ready gem release

### Week 6: Documentation, CLI, Release

#### Day 1-2: Documentation
- [ ] Comprehensive README with examples
- [ ] YARD documentation for all public APIs
- [ ] Guide: "Getting Started"
- [ ] Guide: "Building Your First Pipeline"
- [ ] Guide: "Error Handling & Recovery"
- [ ] Guide: "Parallel Execution"
- [ ] Guide: "Caching Strategies"

#### Day 3: CLI Tool
- [ ] `flowrb` executable
- [ ] `flowrb run pipeline.rb` - execute a pipeline file
- [ ] `flowrb validate pipeline.rb` - check for errors
- [ ] `flowrb visualize pipeline.rb` - output DAG diagram
- [ ] `flowrb status` - show last run status (if checkpointed)

**Deliverable: CLI**
```bash
$ flowrb visualize my_pipeline.rb --format=mermaid

$ flowrb run my_pipeline.rb --param start_date=2024-01-01

$ flowrb run my_pipeline.rb --resume --verbose
```

#### Day 4: Integration Examples
- [ ] Example: Rails + Sidekiq integration
- [ ] Example: Standalone ETL script
- [ ] Example: Data sync between APIs
- [ ] Example: Report generation pipeline

#### Day 5: Final Testing & Edge Cases
- [ ] Load testing with large DAGs (100+ steps)
- [ ] Memory profiling
- [ ] Thread safety audit
- [ ] Error message review (helpful, actionable)

#### Day 6: Gem Release Prep
- [ ] Finalize version (0.1.0)
- [ ] CHANGELOG.md
- [ ] LICENSE (MIT)
- [ ] .gemspec metadata
- [ ] GitHub repo setup (issues, discussions)
- [ ] RubyGems account / push access

#### Day 7: Launch! 🚀
- [ ] Publish to RubyGems
- [ ] Announcement post (Dev.to, Reddit r/ruby)
- [ ] Twitter/X announcement
- [ ] Submit to Ruby Weekly newsletter

**Phase 4 Milestone:** ✅ Public release on RubyGems

---

# Final API Reference

```ruby
# Define a pipeline
pipeline = Flowrb.define(name: "my_pipeline") do
  # Parameters
  param :date, type: :date, required: true
  param :limit, type: :integer, default: 100

  # Hooks
  before_run { |ctx| puts "Starting..." }
  on_failure { |err, ctx| notify_slack(err) }

  # Steps
  step :fetch, cache: { ttl: 3600 } do |ctx|
    API.fetch(date: ctx[:date], limit: ctx[:limit])
  end

  step :transform, depends_on: :fetch, retries: 3 do |data|
    data.map { |d| process(d) }
  end

  step :validate, depends_on: :transform do |data|
    data.select(&:valid?)
  end

  step :load_db, depends_on: :validate do |data|
    DB.bulk_insert(data)
  end

  step :load_s3, depends_on: :validate do |data|
    S3.upload(data.to_json)
  end

  step :notify, depends_on: [:load_db, :load_s3] do
    Slack.post("Import complete!")
  end
end

# Run options
pipeline.run                           # basic sequential
pipeline.run(executor: :parallel)      # parallel execution
pipeline.run(dry_run: true)            # validate only
pipeline.run(resume: true)             # resume from checkpoint
pipeline.run(from: :transform)         # start from step
pipeline.run(reporter: :console)       # pretty output

# Inspect
pipeline.steps                         # list steps
pipeline.dag.to_mermaid               # visualize
pipeline.validate!                     # check for issues
```

---

# Success Metrics

| Metric | Target |
|--------|--------|
| Test Coverage | > 95% |
| Documentation | 100% public API |
| Gem Size | < 50KB (no deps) |
| Basic Pipeline Overhead | < 1ms |
| GitHub Stars (Month 1) | 50+ |
| Downloads (Month 1) | 500+ |

---

# Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Thread safety bugs | Extensive parallel specs, use Queue/Mutex |
| Complex DAG edge cases | Property-based testing for topological sort |
| Scope creep | Strict MVP features, "future" backlog |
| Cache invalidation bugs | Simple key-based cache, clear semantics |
| Poor adoption | Strong docs, real-world examples, comparison to Python tools |

---

# Future Roadmap (Post v1.0)

- [ ] Distributed execution (Redis-backed)
- [ ] Web UI for monitoring
- [ ] Cron/scheduler integration
- [ ] Streaming/incremental pipelines
- [ ] Sidekiq/GoodJob adapter
- [ ] OpenTelemetry integration
- [ ] VS Code extension for DAG visualization

---

# Let's Build It! 🚀

**Week 1 Kickoff Checklist:**
- [ ] Create GitHub repo
- [ ] Setup gem skeleton
- [ ] Write first spec for `Flowrb::Step`
- [ ] Implement Step class
- [ ] Start DAG implementation
