# frozen_string_literal: true

require 'tsort'

module Piperb
  # Directed Acyclic Graph implementation using Ruby's TSort.
  # Manages step dependencies and provides topological sorting.
  class DAG
    include TSort

    def initialize
      @steps = {}
    end

    def add(step)
      if @steps.key?(step.name)
        raise DuplicateStepError.new(
          "Step '#{step.name}' already exists",
          step_name: step.name
        )
      end

      @steps[step.name] = step
      self
    end

    def [](name)
      @steps[name.to_sym]
    end

    def steps
      @steps.values
    end

    def step_names
      @steps.keys
    end

    def empty?
      @steps.empty?
    end

    def size
      @steps.size
    end

    def sorted_steps
      validate!
      tsort.map { |name| @steps[name] }
    end

    def validate!
      validate_dependencies!
      validate_no_cycles!
      true
    end

    # Returns steps grouped by execution level.
    # Steps at the same level have no dependencies on each other and can run in parallel.
    # Level 0 contains steps with no dependencies (roots).
    # @return [Array<Array<Step>>] Array of step arrays, one per level
    def levels
      validate!
      return [] if empty?

      step_levels = compute_step_levels
      group_steps_by_level(step_levels)
    end

    def to_mermaid
      lines = ['graph TD']

      if empty?
        lines << '  empty[Empty Pipeline]'
        return lines.join("\n")
      end

      sorted_steps.each do |step|
        if step.dependencies.empty?
          lines << "  #{step.name}"
        else
          step.dependencies.each do |dep|
            lines << "  #{dep} --> #{step.name}"
          end
        end
      end

      lines.join("\n")
    end

    private

    # TSort interface: iterate over all nodes
    def tsort_each_node(&)
      @steps.each_key(&)
    end

    # TSort interface: iterate over dependencies of a node
    def tsort_each_child(node, &)
      step = @steps[node]
      return unless step

      step.dependencies.each(&)
    end

    def compute_step_levels
      step_levels = {}
      tsort.each do |name|
        step = @steps[name]
        step_levels[name] = step.dependencies.empty? ? 0 : step.dependencies.map { |dep| step_levels[dep] }.max + 1
      end
      step_levels
    end

    def group_steps_by_level(step_levels)
      max_level = step_levels.values.max || 0
      (0..max_level).map { |level| step_levels.select { |_, l| l == level }.keys.map { |name| @steps[name] } }
    end

    def validate_dependencies!
      @steps.each_value do |step|
        step.dependencies.each do |dep|
          # Check for self-reference
          if dep == step.name
            raise CycleError.new(
              "Circular dependency detected: #{step.name} -> #{step.name}",
              cycle: [step.name, step.name]
            )
          end

          next if @steps.key?(dep)

          raise MissingDependencyError.new(
            "Step '#{step.name}' depends on '#{dep}' which does not exist",
            step_name: step.name,
            missing_dependency: dep
          )
        end
      end
    end

    def validate_no_cycles!
      tsort
    rescue TSort::Cyclic => e
      # Extract cycle information from the error message
      cycle = extract_cycle_from_error(e)
      raise CycleError.new(
        "Circular dependency detected: #{cycle.join(' -> ')}",
        cycle: cycle
      )
    end

    def extract_cycle_from_error(_error)
      # TSort::Cyclic message format: "topological sort failed: ... (TSort::Cyclic)"
      # Try to detect the cycle by finding strongly connected components
      detect_cycle
    end

    def detect_cycle
      # Simple DFS-based cycle detection
      visited = {}
      rec_stack = {}
      cycle = []

      @steps.each_key do |name|
        return cycle.reverse if detect_cycle_dfs(name, visited, rec_stack, cycle)
      end

      []
    end

    def detect_cycle_dfs(node, visited, rec_stack, cycle)
      visited[node] = true
      rec_stack[node] = true

      step = @steps[node]
      return false unless step

      step.dependencies.each do |dep|
        if !visited[dep]
          cycle << node
          return true if detect_cycle_dfs(dep, visited, rec_stack, cycle)

          cycle.pop
        elsif rec_stack[dep]
          cycle << node
          cycle << dep
          return true
        end
      end

      rec_stack[node] = false
      false
    end
  end
end
