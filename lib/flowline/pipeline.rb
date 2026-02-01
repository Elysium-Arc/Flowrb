# frozen_string_literal: true

module Flowline
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

    def run(initial_input: nil)
      executor = @executor_class.new(dag)
      executor.execute(initial_input: initial_input)
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
  end
end
