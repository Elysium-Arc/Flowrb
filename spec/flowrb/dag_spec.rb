# frozen_string_literal: true

RSpec.describe Flowrb::DAG do
  let(:dag) { described_class.new }

  def make_step(name, deps = [])
    Flowrb::Step.new(name, depends_on: deps) { 'result' }
  end

  describe '#add' do
    it 'adds a step to the DAG' do
      step = make_step(:fetch)
      dag.add(step)
      expect(dag[:fetch]).to eq(step)
    end

    it 'returns self for chaining' do
      step = make_step(:fetch)
      expect(dag.add(step)).to eq(dag)
    end

    it 'raises DuplicateStepError for duplicate step names' do
      dag.add(make_step(:fetch))
      expect { dag.add(make_step(:fetch)) }.to raise_error(
        Flowrb::DuplicateStepError,
        /already exists/
      )
    end

    it 'includes step name in DuplicateStepError' do
      dag.add(make_step(:fetch))
      expect { dag.add(make_step(:fetch)) }.to raise_error do |error|
        expect(error.step_name).to eq(:fetch)
      end
    end
  end

  describe '#[]' do
    it 'retrieves a step by name' do
      step = make_step(:fetch)
      dag.add(step)
      expect(dag[:fetch]).to eq(step)
    end

    it 'accepts string keys and converts to symbol' do
      step = make_step(:fetch)
      dag.add(step)
      expect(dag['fetch']).to eq(step)
    end

    it 'returns nil for unknown steps' do
      expect(dag[:unknown]).to be_nil
    end
  end

  describe '#steps' do
    it 'returns all steps' do
      step1 = make_step(:a)
      step2 = make_step(:b)
      dag.add(step1)
      dag.add(step2)
      expect(dag.steps).to contain_exactly(step1, step2)
    end
  end

  describe '#step_names' do
    it 'returns all step names' do
      dag.add(make_step(:a))
      dag.add(make_step(:b))
      expect(dag.step_names).to contain_exactly(:a, :b)
    end
  end

  describe '#empty?' do
    it 'returns true for empty DAG' do
      expect(dag).to be_empty
    end

    it 'returns false for non-empty DAG' do
      dag.add(make_step(:fetch))
      expect(dag).not_to be_empty
    end
  end

  describe '#size' do
    it 'returns the number of steps' do
      dag.add(make_step(:a))
      dag.add(make_step(:b))
      expect(dag.size).to eq(2)
    end
  end

  describe '#sorted_steps' do
    it 'returns steps in topological order' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:b]))

      names = dag.sorted_steps.map(&:name)
      expect(names).to eq(%i[a b c])
    end

    it 'handles multiple roots' do
      dag.add(make_step(:a))
      dag.add(make_step(:b))
      dag.add(make_step(:c, %i[a b]))

      names = dag.sorted_steps.map(&:name)
      expect(names.last).to eq(:c)
      expect(names[0..1]).to contain_exactly(:a, :b)
    end

    it 'handles diamond dependencies' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:a]))
      dag.add(make_step(:d, %i[b c]))

      names = dag.sorted_steps.map(&:name)
      expect(names.first).to eq(:a)
      expect(names.last).to eq(:d)
      expect(names.index(:b)).to be < names.index(:d)
      expect(names.index(:c)).to be < names.index(:d)
    end

    it 'returns empty array for empty DAG' do
      expect(dag.sorted_steps).to eq([])
    end
  end

  describe '#validate!' do
    it 'returns true for valid DAG' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      expect(dag.validate!).to be true
    end

    it 'raises MissingDependencyError for unknown dependency' do
      dag.add(make_step(:process, [:unknown]))
      expect { dag.validate! }.to raise_error(Flowrb::MissingDependencyError)
    end

    it 'includes details in MissingDependencyError' do
      dag.add(make_step(:process, [:unknown]))
      expect { dag.validate! }.to raise_error do |error|
        expect(error.step_name).to eq(:process)
        expect(error.missing_dependency).to eq(:unknown)
      end
    end

    context 'with cycles' do
      it 'raises CycleError for self-referencing step' do
        dag.add(make_step(:a, [:a]))
        expect { dag.validate! }.to raise_error(Flowrb::CycleError)
      end

      it 'raises CycleError for A -> B -> A cycle' do
        dag.add(make_step(:a, [:b]))
        dag.add(make_step(:b, [:a]))
        expect { dag.validate! }.to raise_error(Flowrb::CycleError)
      end

      it 'raises CycleError for longer cycles' do
        dag.add(make_step(:a, [:c]))
        dag.add(make_step(:b, [:a]))
        dag.add(make_step(:c, [:b]))
        expect { dag.validate! }.to raise_error(Flowrb::CycleError)
      end

      it 'includes cycle information in error' do
        dag.add(make_step(:a, [:b]))
        dag.add(make_step(:b, [:a]))
        expect { dag.validate! }.to raise_error do |error|
          expect(error.cycle).not_to be_empty
        end
      end
    end
  end

  describe '#levels' do
    it 'returns empty array for empty DAG' do
      expect(dag.levels).to eq([])
    end

    it 'returns single level for steps with no dependencies' do
      dag.add(make_step(:a))
      dag.add(make_step(:b))
      dag.add(make_step(:c))

      levels = dag.levels
      expect(levels.size).to eq(1)
      expect(levels[0].map(&:name)).to contain_exactly(:a, :b, :c)
    end

    it 'returns correct levels for linear chain' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:b]))

      levels = dag.levels
      expect(levels.size).to eq(3)
      expect(levels[0].map(&:name)).to eq([:a])
      expect(levels[1].map(&:name)).to eq([:b])
      expect(levels[2].map(&:name)).to eq([:c])
    end

    it 'groups independent steps at the same level' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:a]))
      dag.add(make_step(:d, %i[b c]))

      levels = dag.levels
      expect(levels.size).to eq(3)
      expect(levels[0].map(&:name)).to eq([:a])
      expect(levels[1].map(&:name)).to contain_exactly(:b, :c)
      expect(levels[2].map(&:name)).to eq([:d])
    end

    it 'handles multiple roots' do
      dag.add(make_step(:root1))
      dag.add(make_step(:root2))
      dag.add(make_step(:sink, %i[root1 root2]))

      levels = dag.levels
      expect(levels.size).to eq(2)
      expect(levels[0].map(&:name)).to contain_exactly(:root1, :root2)
      expect(levels[1].map(&:name)).to eq([:sink])
    end

    it 'handles complex topology with multiple paths' do
      #   a
      #  /|\
      # b c d
      # |X|X|
      # e f g
      #  \|/
      #   h
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))
      dag.add(make_step(:c, [:a]))
      dag.add(make_step(:d, [:a]))
      dag.add(make_step(:e, %i[b c]))
      dag.add(make_step(:f, %i[b c d]))
      dag.add(make_step(:g, %i[c d]))
      dag.add(make_step(:h, %i[e f g]))

      levels = dag.levels
      expect(levels.size).to eq(4)
      expect(levels[0].map(&:name)).to eq([:a])
      expect(levels[1].map(&:name)).to contain_exactly(:b, :c, :d)
      expect(levels[2].map(&:name)).to contain_exactly(:e, :f, :g)
      expect(levels[3].map(&:name)).to eq([:h])
    end
  end

  describe '#to_mermaid' do
    it 'returns mermaid diagram for empty DAG' do
      expect(dag.to_mermaid).to include('graph TD')
      expect(dag.to_mermaid).to include('empty[Empty Pipeline]')
    end

    it 'returns mermaid diagram with steps' do
      dag.add(make_step(:a))
      dag.add(make_step(:b, [:a]))

      mermaid = dag.to_mermaid
      expect(mermaid).to include('graph TD')
      expect(mermaid).to include('a --> b')
    end

    it 'shows standalone steps' do
      dag.add(make_step(:standalone))
      mermaid = dag.to_mermaid
      expect(mermaid).to include('standalone')
    end

    it 'shows multiple dependencies' do
      dag.add(make_step(:a))
      dag.add(make_step(:b))
      dag.add(make_step(:c, %i[a b]))

      mermaid = dag.to_mermaid
      expect(mermaid).to include('a --> c')
      expect(mermaid).to include('b --> c')
    end
  end
end
