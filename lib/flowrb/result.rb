# frozen_string_literal: true

module Flowrb
  # Represents the result of executing a single step.
  class StepResult
    attr_reader :step_name, :output, :duration, :started_at, :error, :retries

    def initialize(step_name:, output: nil, duration: nil, started_at: nil, error: nil, status: nil, retries: 0,
                   timed_out: false)
      @step_name = step_name
      @output = output
      @duration = duration
      @started_at = started_at
      @error = error
      @status = status
      @retries = retries
      @timed_out = timed_out
    end

    def status
      @status || (error ? :failed : :success)
    end

    def success?
      status == :success
    end

    def failed?
      status == :failed
    end

    alias failure? failed?

    def skipped?
      status == :skipped
    end

    def timed_out?
      @timed_out
    end

    def to_h
      {
        step_name: step_name,
        output: output,
        duration: duration,
        started_at: started_at,
        error: error,
        status: status,
        retries: retries,
        timed_out: timed_out?,
        skipped: skipped?
      }
    end

    def inspect
      "#<Flowrb::StepResult step=#{step_name.inspect} status=#{status.inspect} duration=#{duration&.round(4)}>"
    end
  end

  # Represents the overall result of executing a pipeline.
  class Result
    attr_reader :step_results, :started_at, :finished_at, :error

    def initialize(step_results: {}, started_at: nil, finished_at: nil, error: nil)
      @step_results = step_results
      @started_at = started_at
      @finished_at = finished_at
      @error = error
    end

    def [](step_name)
      step_results[step_name.to_sym]
    end

    def success?
      error.nil? && step_results.values.none?(&:failed?)
    end

    def failed?
      !success?
    end

    alias failure? failed?

    def duration
      return nil unless started_at && finished_at

      finished_at - started_at
    end

    def outputs
      step_results.transform_values(&:output)
    end

    def completed_steps
      step_results.keys
    end

    def to_h
      {
        success: success?,
        duration: duration,
        started_at: started_at,
        finished_at: finished_at,
        error: error&.message,
        steps: step_results.transform_values(&:to_h)
      }
    end

    def inspect
      status = success? ? 'success' : 'failed'
      "#<Flowrb::Result status=#{status} steps=#{step_results.size} duration=#{duration&.round(4)}>"
    end
  end
end
