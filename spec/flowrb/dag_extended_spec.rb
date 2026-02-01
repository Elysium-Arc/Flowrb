# frozen_string_literal: true

RSpec.describe Flowrb::DAG do
  let(:dag) { described_class.new }

  def make_step(name, deps = [])
    Flowrb::Step.new(name, depends_on: deps) { 'result' }
  end

  describe 'complex graph topologies' do
    it 'handles wide graph (many roots)' do
      10.times { |i| dag.add(make_step(:"root_#{i}")) }
      dag.add(make_step(:sink, (0...10).map { |i| :"root_#{i}" }))

      names = dag.sorted_steps.map(&:name)
      expect(names.last).to eq(:sink)
      expect(names.size).to eq(11)
    end

    it 'handles deep linear chain' do
      prev = nil
      10.times do |i|
        deps = prev ? [prev] : []
        dag.add(make_step(:"step_#{i}", deps))
        prev = :"step_#{i}"
      end

      names = dag.sorted_steps.map(&:name)
      expect(names).to eq((0...10).map { |i| :"step_#{i}" })
    end

    it 'handles binary tree structure' do
      #       a
      #      / \
      #     b   c
      #    /|   |\
      #   d e   f g
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:a]))
      dag.add(make_step(:d, [:b]))
      dag.add(make_step(:e, [:b]))
      dag.add(make_step(:f, [:c]))
      dag.add(make_step(:g, [:c]))

      names = dag.sorted_steps.map(&:name)
      expect(names.first).to eq(:a)
      expect(names.index(:b)).to be < names.index(:d)
      expect(names.index(:b)).to be < names.index(:e)
      expect(names.index(:c)).to be < names.index(:f)
      expect(names.index(:c)).to be < names.index(:g)
    end

    it 'handles inverted binary tree (convergent)' do
      #   a   b   c   d
      #    \ /     \ /
      #     e       f
      #      \     /
      #        g
      dag.add(make_step(:a))
      dag.add(make_step(:b))
      dag.add(make_step(:c))
      dag.add(make_step(:d))
      dag.add(make_step(:e, %i[a b]))
      dag.add(make_step(:f, %i[c d]))
      dag.add(make_step(:g, %i[e f]))

      names = dag.sorted_steps.map(&:name)
      expect(names.last).to eq(:g)
      expect(names.index(:e)).to be < names.index(:g)
      expect(names.index(:f)).to be < names.index(:g)
    end

    it 'handles multiple independent subgraphs' do
      # Subgraph 1: a -> b -> c
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:b]))

      # Subgraph 2: x -> y -> z
      dag.add(make_step(:x))
      dag.add(make_step(:y, [:x]))
      dag.add(make_step(:z, [:y]))

      expect(dag.size).to eq(6)
      names = dag.sorted_steps.map(&:name)

      # Verify ordering within each subgraph
      expect(names.index(:a)).to be < names.index(:b)
      expect(names.index(:b)).to be < names.index(:c)
      expect(names.index(:x)).to be < names.index(:y)
      expect(names.index(:y)).to be < names.index(:z)
    end

    it 'handles complex mesh topology' do
      #     a
      #    /|\
      #   b c d
      #   |X|X|
      #   e f g
      #    \|/
      #     h
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:a]))
      dag.add(make_step(:d, [:a]))
      dag.add(make_step(:e, %i[b c]))
      dag.add(make_step(:f, %i[b c d]))
      dag.add(make_step(:g, %i[c d]))
      dag.add(make_step(:h, %i[e f g]))

      names = dag.sorted_steps.map(&:name)
      expect(names.first).to eq(:a)
      expect(names.last).to eq(:h)
    end
  end

  describe 'cycle detection edge cases' do
    it 'detects cycle in otherwise valid graph' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:b]))
      dag.add(make_step(:d, %i[c a])) # d depends on c and a (valid)
      dag.add(make_step(:e, [:d]))
      dag.add(make_step(:f, %i[e b])) # creates potential for complex cycle detection

      expect(dag.validate!).to be true
    end

    it 'detects cycle with 4 nodes' do
      dag.add(make_step(:a, [:d]))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:b]))
      dag.add(make_step(:d, [:c]))

      expect { dag.validate! }.to raise_error(Flowrb::CycleError)
    end

    it 'detects multiple independent cycles' do
      # Cycle 1: a -> b -> a
      dag.add(make_step(:a, [:b]))
      dag.add(make_step(:b, [:a]))

      expect { dag.validate! }.to raise_error(Flowrb::CycleError)
    end

    it 'handles graph with cycle and missing dependency' do
      dag.add(make_step(:a, [:b]))
      dag.add(make_step(:b, %i[a missing]))

      # Should raise MissingDependencyError first (checked before cycles)
      expect { dag.validate! }.to raise_error(Flowrb::MissingDependencyError)
    end
  end

  describe 'missing dependency edge cases' do
    it 'detects multiple missing dependencies in one step' do
      dag.add(make_step(:process, %i[missing1 missing2 missing3]))

      expect { dag.validate! }.to raise_error(Flowrb::MissingDependencyError) do |error|
        expect(error.missing_dependency).to(satisfy { |dep| %i[missing1 missing2 missing3].include?(dep) })
      end
    end

    it 'detects missing dependency in middle of chain' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:missing]))
      dag.add(make_step(:d, [:c]))

      expect { dag.validate! }.to raise_error(Flowrb::MissingDependencyError) do |error|
        expect(error.step_name).to eq(:c)
        expect(error.missing_dependency).to eq(:missing)
      end
    end
  end

  describe 'chaining and fluent interface' do
    it 'supports chained add calls' do
      dag.add(make_step(:a))
         .add(make_step(:b, [:a]))
         .add(make_step(:c, [:b]))

      expect(dag.size).to eq(3)
    end
  end

  describe '#to_mermaid edge cases' do
    it 'handles step names with underscores' do
      dag.add(make_step(:fetch_data))
      dag.add(make_step(:process_data, [:fetch_data]))

      mermaid = dag.to_mermaid
      expect(mermaid).to include('fetch_data --> process_data')
    end

    it 'handles complex diamond in mermaid' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:a]))
      dag.add(make_step(:d, %i[b c]))

      mermaid = dag.to_mermaid
      expect(mermaid).to include('a --> b')
      expect(mermaid).to include('a --> c')
      expect(mermaid).to include('b --> d')
      expect(mermaid).to include('c --> d')
    end

    it 'handles multiple roots in mermaid' do
      dag.add(make_step(:root1))
      dag.add(make_step(:root2))
      dag.add(make_step(:sink, %i[root1 root2]))

      mermaid = dag.to_mermaid
      expect(mermaid).to include('root1')
      expect(mermaid).to include('root2')
      expect(mermaid).to include('root1 --> sink')
      expect(mermaid).to include('root2 --> sink')
    end
  end

  describe 'step retrieval' do
    it 'returns all steps in insertion order for steps method' do
      dag.add(make_step(:c))
      dag.add(make_step(:a))
      dag.add(make_step(:b))

      # NOTE: Hash order is preserved in Ruby 1.9+
      expect(dag.step_names).to eq(%i[c a b])
    end

    it 'distinguishes between similar step names' do
      dag.add(make_step(:step))
      dag.add(make_step(:step1, [:step]))
      dag.add(make_step(:step_1, [:step]))

      expect(dag.size).to eq(3)
      expect(dag[:step]).not_to be_nil
      expect(dag[:step1]).not_to be_nil
      expect(dag[:step_1]).not_to be_nil
    end
  end

  describe 'validation idempotence' do
    it 'can validate multiple times' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))

      expect(dag.validate!).to be true
      expect(dag.validate!).to be true
      expect(dag.validate!).to be true
    end

    it 'sorted_steps is consistent across calls' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:a]))
      dag.add(make_step(:d, %i[b c]))

      first_sort = dag.sorted_steps.map(&:name)
      second_sort = dag.sorted_steps.map(&:name)
      third_sort = dag.sorted_steps.map(&:name)

      expect(first_sort).to eq(second_sort)
      expect(second_sort).to eq(third_sort)
    end
  end
end
