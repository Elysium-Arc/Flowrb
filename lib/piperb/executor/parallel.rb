# frozen_string_literal: true

require_relative 'base'

module Piperb
  module Executor
    # Executes pipeline steps in parallel where possible.
    # Steps at the same level (no inter-dependencies) run concurrently.
    class Parallel < Base
      def initialize(dag, max_threads: nil)
        super(dag)
        @max_threads = max_threads
      end

      def execute(initial_input: nil, cache: nil, force: false)
        dag.validate!
        context = ExecutionContext.new(initial_input, cache, force)

        dag.levels.each do |level_steps|
          break if context.error_info

          execute_level(level_steps, context) { |err| context.error_info = err }
        end

        context.finalize_result
      rescue StepError
        raise
      rescue StandardError => e
        Result.new(step_results: context.step_results, started_at: context.started_at, finished_at: Time.now, error: e)
      end

      private

      # Holds mutable state during parallel execution
      class ExecutionContext
        attr_reader :step_results, :outputs, :mutex, :started_at, :initial_input, :cache, :force
        attr_accessor :error_info

        def initialize(initial_input, cache, force)
          @initial_input = initial_input
          @cache = cache
          @force = force
          @started_at = Time.now
          @step_results = {}
          @outputs = {}
          @mutex = Mutex.new
          @error_info = nil
        end

        def finalize_result
          raise_step_error if error_info
          Result.new(step_results: step_results, started_at: started_at, finished_at: Time.now)
        end

        private

        def raise_step_error
          raise StepError.new(
            "Step '#{error_info[:step_name]}' failed: #{error_info[:error].message}",
            step_name: error_info[:step_name],
            original_error: error_info[:error],
            partial_results: Result.new(step_results: step_results, started_at: started_at, finished_at: Time.now)
          )
        end
      end

      def execute_level(steps, context, &)
        return if context.error_info

        if @max_threads&.positive?
          execute_batched(steps, context, &)
        else
          execute_unbounded(steps, context, &)
        end
      end

      def execute_batched(steps, context, &error_handler)
        steps.each_slice(@max_threads) do |batch|
          run_threads(batch, context, &error_handler)
        end
      end

      def execute_unbounded(steps, context, &)
        run_threads(steps, context, &)
      end

      def run_threads(steps, context, &error_handler)
        threads = steps.map { |step| create_step_thread(step, context, &error_handler) }
        threads.each(&:join)
      end

      def create_step_thread(step, context)
        Thread.new do
          step_result = execute_step(step, context)
          context.mutex.synchronize do
            context.step_results[step.name] = step_result
            if step_result.failed?
              yield({ step_name: step.name, error: step_result.error })
            else
              context.outputs[step.name] = step_result.output
            end
          end
        end
      end

      def execute_step(step, context)
        input = context.mutex.synchronize { build_step_input(step, context.outputs, context.initial_input) }

        # Check cache first
        cached_result = check_cache(step, input, context.cache, context.force)
        return cached_result if cached_result

        # Check conditions
        if should_skip_step?(step, input)
          result = build_skipped_result(step)
          context.mutex.synchronize { write_cache(step, result, input, context.cache) }
          return result
        end

        # Execute and cache result
        result = execute_step_with_retry(step, input)
        context.mutex.synchronize { write_cache(step, result, input, context.cache) }
        result
      end
    end
  end
end
