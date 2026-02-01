# frozen_string_literal: true

module Flowrb
  # User-facing DSL class for defining and executing pipelines.
  class Pipeline
    attr_reader :dag

    def initialize(&)
      @dag = DAG.new
      @executor_class = Executor::Sequential
      instance_eval(&) if block_given?
    end

    def step(name, depends_on: [], **options, &block)
      step = Step.new(name, depends_on: depends_on, **options, &block)
      dag.add(step)
      self
    end

    # Runs the pipeline with the specified executor.
    #
    # @param initial_input [Object] Input passed to root steps (steps with no dependencies)
    # @param executor [Symbol, Class] Executor to use (:sequential, :parallel, or a class)
    # @param max_threads [Integer, nil] Maximum concurrent threads for parallel executor
    # @param cache [Cache::Base, String, nil] Cache store or directory path for result caching
    # @param force [Boolean] Force re-execution, ignoring cache
    # @return [Flowrb::Result] The execution result
    def run(initial_input: nil, executor: :sequential, max_threads: nil, cache: nil, force: false)
      executor_instance = build_executor(executor, max_threads)
      cache_store = resolve_cache_store(cache)
      executor_instance.execute(initial_input: initial_input, cache: cache_store, force: force)
    end

    def validate!
      dag.validate!
    end

    def to_mermaid
      dag.to_mermaid
    end

    def steps
      dag.steps
    end

    def [](step_name)
      dag[step_name]
    end

    def empty?
      dag.empty?
    end

    def size
      dag.size
    end

    private

    def build_executor(executor, max_threads)
      case executor
      when :sequential
        Executor::Sequential.new(dag)
      when :parallel
        Executor::Parallel.new(dag, max_threads: max_threads)
      when Class
        if max_threads && executor.instance_method(:initialize).arity != 1
          executor.new(dag, max_threads: max_threads)
        else
          executor.new(dag)
        end
      else
        raise ArgumentError, "Unknown executor: #{executor}. Use :sequential, :parallel, or a class."
      end
    end

    def resolve_cache_store(cache)
      case cache
      when nil
        nil
      when String
        Cache::FileStore.new(cache)
      when Cache::Base
        cache
      else
        raise ArgumentError, "Invalid cache option: #{cache.class}. Use a path string or Cache::Base instance."
      end
    end
  end
end
