# frozen_string_literal: true

require_relative 'lib/flowrb/version'

Gem::Specification.new do |spec|
  spec.name = 'flowrb'
  spec.version = Flowrb::VERSION
  spec.authors = ['Flowrb Contributors']
  spec.email = ['flowrb@example.com']

  spec.summary = 'A Ruby dataflow and pipeline library'
  spec.description = 'Flowrb provides declarative step definitions, automatic dependency resolution, and sequential execution for building data pipelines in Ruby.'
  spec.homepage = 'https://github.com/flowrb/flowrb'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # No runtime dependencies - pure Ruby with stdlib only
end
