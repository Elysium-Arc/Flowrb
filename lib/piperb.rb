# frozen_string_literal: true

require_relative 'piperb/version'
require_relative 'piperb/errors'
require_relative 'piperb/step'
require_relative 'piperb/dag'
require_relative 'piperb/result'
require_relative 'piperb/cache'
require_relative 'piperb/executor/base'
require_relative 'piperb/executor/sequential'
require_relative 'piperb/executor/parallel'
require_relative 'piperb/pipeline'

# Piperb is a Ruby dataflow and pipeline library with declarative step
# definitions, automatic dependency resolution, and sequential execution.
module Piperb
  class << self
    # Define a new pipeline using the DSL.
    #
    # @example
    #   pipeline = Piperb.define do
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
    # @return [Piperb::Pipeline] The defined pipeline
    def define(&)
      Pipeline.new(&)
    end
  end
end
