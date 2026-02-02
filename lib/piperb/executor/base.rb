# frozen_string_literal: true

require 'timeout'

module Piperb
  module Executor
    # Abstract base class for pipeline executors.
    # Subclasses must implement the #execute method.
    class Base # rubocop:disable Metrics/ClassLength
      attr_reader :dag

      def initialize(dag)
        @dag = dag
      end

      def execute(initial_input: nil)
        raise NotImplementedError, 'Subclasses must implement #execute'
      end

      protected

      def build_step_input(step, outputs, initial_input)
        deps = step.dependencies

        case deps.size
        when 0
          # No dependencies: pass initial input or empty args
          { args: initial_input.nil? ? [] : [initial_input], kwargs: {} }
        when 1
          # Single dependency: pass output directly
          { args: [outputs[deps.first]], kwargs: {} }
        else
          # Multiple dependencies: pass as keyword arguments
          kwargs = deps.each_with_object({}) do |dep, hash|
            hash[dep] = outputs[dep]
          end
          { args: [], kwargs: kwargs }
        end
      end

      # Executes a step with retry and timeout support
      def execute_step_with_retry(step, input)
        retries_remaining = step.retries
        retry_count = 0
        last_error = nil
        timed_out = false
        step_started_at = Time.now

        loop do
          result = execute_single_attempt(step, input)

          return build_success_result(step, result[:output], step_started_at, retry_count) if result[:success]

          last_error = result[:error]
          timed_out = result[:timed_out]

          break unless should_retry?(step, last_error, retries_remaining)

          retries_remaining -= 1
          retry_count += 1
          apply_retry_delay(step, retry_count)
        end

        build_failure_result(step, last_error, step_started_at, retry_count, timed_out)
      end

      private

      def execute_single_attempt(step, input)
        if step.timeout
          execute_with_timeout(step, input)
        else
          execute_without_timeout(step, input)
        end
      end

      def execute_with_timeout(step, input)
        output = Timeout.timeout(step.timeout) do
          step.call(*input[:args], **input[:kwargs])
        end
        { success: true, output: output }
      rescue Timeout::Error
        error = TimeoutError.new(step_name: step.name, timeout_seconds: step.timeout)
        { success: false, error: error, timed_out: true }
      rescue StandardError => e
        { success: false, error: e, timed_out: false }
      end

      def execute_without_timeout(step, input)
        output = step.call(*input[:args], **input[:kwargs])
        { success: true, output: output }
      rescue StandardError => e
        { success: false, error: e, timed_out: false }
      end

      def should_retry?(step, error, retries_remaining)
        return false if retries_remaining <= 0

        retry_condition = step.retry_if
        return true unless retry_condition

        retry_condition.call(error)
      end

      def apply_retry_delay(step, retry_count)
        base_delay = step.retry_delay
        return if base_delay.nil? || base_delay <= 0

        actual_delay = calculate_delay(base_delay, retry_count, step.retry_backoff)
        sleep(actual_delay)
      end

      def calculate_delay(base_delay, retry_count, backoff)
        case backoff
        when :exponential
          base_delay * (2**(retry_count - 1))
        when :linear
          base_delay * retry_count
        else
          base_delay
        end
      end

      def build_success_result(step, output, started_at, retry_count)
        StepResult.new(
          step_name: step.name,
          output: output,
          duration: Time.now - started_at,
          started_at: started_at,
          status: :success,
          retries: retry_count
        )
      end

      def build_failure_result(step, error, started_at, retry_count, timed_out)
        StepResult.new(
          step_name: step.name,
          error: error,
          duration: Time.now - started_at,
          started_at: started_at,
          status: :failed,
          retries: retry_count,
          timed_out: timed_out
        )
      end

      def build_skipped_result(step)
        StepResult.new(
          step_name: step.name,
          output: nil,
          duration: 0,
          started_at: Time.now,
          status: :skipped,
          retries: 0
        )
      end

      def should_skip_step?(step, input)
        return false unless step.conditional?

        if_cond = step.if_condition
        unless_cond = step.unless_condition

        # if: takes precedence when both are present
        return !evaluate_condition(if_cond, input) if if_cond

        return evaluate_condition(unless_cond, input) if unless_cond

        false
      end

      def evaluate_condition(condition, input)
        return true if condition.nil?

        if input[:kwargs].empty?
          if input[:args].empty?
            condition.call
          else
            condition.call(*input[:args])
          end
        else
          condition.call(**input[:kwargs])
        end
      end

      # Cache support methods
      def cache_key_for(step, input)
        custom_key = step.cache_key
        if custom_key
          if input[:kwargs].empty?
            custom_key.call(*input[:args])
          else
            custom_key.call(**input[:kwargs])
          end
        else
          step.name.to_s
        end
      end

      def check_cache(step, input, cache, force)
        return nil unless cache
        return nil if force
        return nil unless step.cache_enabled?

        key = cache_key_for(step, input)
        return nil unless cache.exist?(key)

        cached = cache.read(key)
        return nil unless cached.is_a?(Cache::CachedResult)

        build_cached_result(step, cached)
      end

      def write_cache(step, result, input, cache)
        return unless cache
        return unless step.cache_enabled?
        return if result.failed?

        key = cache_key_for(step, input)
        cached = Cache::CachedResult.new(
          output: result.output,
          status: result.status,
          skipped: result.skipped?
        )
        cache.write(key, cached)
      end

      def build_cached_result(step, cached)
        if cached.skipped?
          build_skipped_result(step)
        else
          StepResult.new(
            step_name: step.name,
            output: cached.output,
            duration: 0,
            started_at: Time.now,
            status: cached.status,
            retries: 0
          )
        end
      end
    end
  end
end
