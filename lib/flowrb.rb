# frozen_string_literal: true

require_relative 'flowrb/version'
require_relative 'flowrb/errors'
require_relative 'flowrb/step'
require_relative 'flowrb/dag'
require_relative 'flowrb/result'
require_relative 'flowrb/cache'
require_relative 'flowrb/executor/base'
require_relative 'flowrb/executor/sequential'
require_relative 'flowrb/executor/parallel'
require_relative 'flowrb/pipeline'

# Flowrb is a Ruby dataflow and pipeline library with declarative step
# definitions, automatic dependency resolution, and sequential execution.
module Flowrb
  class << self
    # Define a new pipeline using the DSL.
    #
    # @example
    #   pipeline = Flowrb.define do
    #     step :fetch do
    #       [1, 2, 3]
    #     end
    #
    #     step :transform, depends_on: :fetch do |data|
    #       data.map { |n| n * 2 }
    #     end
    #   end
    #
    #   result = pipeline.run
    #
    # @yield Block containing step definitions
    # @return [Flowrb::Pipeline] The defined pipeline
    def define(&)
      Pipeline.new(&)
    end
  end
end
