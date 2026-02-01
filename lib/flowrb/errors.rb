# frozen_string_literal: true

module Flowrb
  # Base error class for all Flowrb errors
  class Error < StandardError; end

  # Raised when a circular dependency is detected in the DAG
  class CycleError < Error
    attr_reader :cycle

    def initialize(message = 'Circular dependency detected', cycle: nil)
      @cycle = cycle
      super(message)
    end
  end

  # Raised when a step references a dependency that doesn't exist
  class MissingDependencyError < Error
    attr_reader :step_name, :missing_dependency

    def initialize(message = 'Missing dependency', step_name: nil, missing_dependency: nil)
      @step_name = step_name
      @missing_dependency = missing_dependency
      super(message)
    end
  end

  # Raised when a step with the same name already exists
  class DuplicateStepError < Error
    attr_reader :step_name

    def initialize(message = 'Duplicate step', step_name: nil)
      @step_name = step_name
      super(message)
    end
  end

  # Raised when a step execution fails
  class StepError < Error
    attr_reader :step_name, :original_error, :partial_results

    def initialize(message = 'Step execution failed', step_name: nil, original_error: nil, partial_results: nil)
      @step_name = step_name
      @original_error = original_error
      @partial_results = partial_results
      super(message)
    end
  end

  # Raised when a step exceeds its timeout
  class TimeoutError < Error
    attr_reader :step_name, :timeout_seconds

    def initialize(message = nil, step_name: nil, timeout_seconds: nil)
      @step_name = step_name
      @timeout_seconds = timeout_seconds
      message ||= "Step '#{step_name}' timed out after #{timeout_seconds} seconds"
      super(message)
    end
  end
end
