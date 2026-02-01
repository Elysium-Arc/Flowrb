# frozen_string_literal: true

require_relative 'base'

module Flowline
  module Executor
    # Executes pipeline steps sequentially in topological order.
    class Sequential < Base
      def execute(initial_input: nil)
        dag.validate!

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
        step_started_at = Time.now
        input = build_step_input(step, outputs, initial_input)

        begin
          output = step.call(*input[:args], **input[:kwargs])
          step_finished_at = Time.now

          StepResult.new(
            step_name: step.name,
            output: output,
            duration: step_finished_at - step_started_at,
            started_at: step_started_at,
            status: :success
          )
        rescue StandardError => e
          step_finished_at = Time.now

          StepResult.new(
            step_name: step.name,
            error: e,
            duration: step_finished_at - step_started_at,
            started_at: step_started_at,
            status: :failed
          )
        end
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
