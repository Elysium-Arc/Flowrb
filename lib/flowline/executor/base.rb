# frozen_string_literal: true

module Flowline
  module Executor
    # Abstract base class for pipeline executors.
    # Subclasses must implement the #execute method.
    class Base
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
    end
  end
end
