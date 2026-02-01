# frozen_string_literal: true

module Flowline
  # Represents an atomic unit of work in a pipeline.
  # Steps are immutable after creation for thread safety.
  class Step
    attr_reader :name, :dependencies, :callable, :options

    def initialize(name, depends_on: [], callable: nil, **options, &block)
      @name = name.to_sym
      @dependencies = normalize_dependencies(depends_on)
      @callable = callable || block
      @options = options.freeze

      validate!
      freeze
    end

    def call(*args, **kwargs)
      if kwargs.empty?
        callable.call(*args)
      else
        callable.call(*args, **kwargs)
      end
    end

    def to_s
      "Step(#{name})"
    end

    def inspect
      "#<Flowline::Step name=#{name.inspect} dependencies=#{dependencies.inspect}>"
    end

    private

    def normalize_dependencies(deps)
      Array(deps).map(&:to_sym).freeze
    end

    def validate!
      raise ArgumentError, 'Step name cannot be nil' if name.nil?
      raise ArgumentError, 'Step must have a callable (block, Proc, or object responding to #call)' unless callable
      raise ArgumentError, 'Callable must respond to #call' unless callable.respond_to?(:call)
    end
  end
end
