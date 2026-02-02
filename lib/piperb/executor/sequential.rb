# frozen_string_literal: true

require_relative 'base'

module Piperb
  module Executor
    # Executes pipeline steps sequentially in topological order.
    class Sequential < Base
      def execute(initial_input: nil, cache: nil, force: false) # rubocop:disable Metrics/MethodLength
        dag.validate!

        @cache = cache
        @force = force
        started_at = Time.now
        step_results = {}
        outputs = {}

        begin
          dag.sorted_steps.each do |step|
            step_result = execute_step(step, outputs, initial_input)
            step_results[step.name] = step_result

            if step_result.failed?
              raise StepError.new(
                "Step '#{step.name}' failed: #{step_result.error.message}",
                step_name: step.name,
                original_error: step_result.error,
                partial_results: build_result(step_results, started_at)
              )
            end

            outputs[step.name] = step_result.output
          end

          build_result(step_results, started_at)
        rescue StepError
          raise
        rescue StandardError => e
          Result.new(
            step_results: step_results,
            started_at: started_at,
            finished_at: Time.now,
            error: e
          )
        end
      end

      private

      def execute_step(step, outputs, initial_input)
        input = build_step_input(step, outputs, initial_input)

        # Check cache first
        cached_result = check_cache(step, input, @cache, @force)
        return cached_result if cached_result

        # Check conditions
        if should_skip_step?(step, input)
          result = build_skipped_result(step)
          write_cache(step, result, input, @cache)
          return result
        end

        # Execute and cache result
        result = execute_step_with_retry(step, input)
        write_cache(step, result, input, @cache)
        result
      end

      def build_result(step_results, started_at)
        Result.new(
          step_results: step_results,
          started_at: started_at,
          finished_at: Time.now
        )
      end
    end
  end
end
