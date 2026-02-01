# frozen_string_literal: true

module Flowrb
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

    # Retry options
    def retries
      options.fetch(:retries, 0)
    end

    def retry_delay
      options.fetch(:retry_delay, 0)
    end

    def retry_backoff
      options.fetch(:retry_backoff, nil)
    end

    def retry_if
      options.fetch(:retry_if, nil)
    end

    # Timeout options
    def timeout
      options.fetch(:timeout, nil)
    end

    # Conditional execution options
    def if_condition
      options.fetch(:if, nil)
    end

    def unless_condition
      options.fetch(:unless, nil)
    end

    def conditional?
      !if_condition.nil? || !unless_condition.nil?
    end

    # Cache options
    def cache_enabled?
      # Default to true unless explicitly set to false
      options.fetch(:cache, true)
    end

    def cache_key
      options.fetch(:cache_key, nil)
    end

    def to_s
      "Step(#{name})"
    end

    def inspect
      "#<Flowrb::Step name=#{name.inspect} dependencies=#{dependencies.inspect}>"
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
