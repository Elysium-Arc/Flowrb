# frozen_string_literal: true

require_relative 'flowline/version'
require_relative 'flowline/errors'
require_relative 'flowline/step'
require_relative 'flowline/dag'
require_relative 'flowline/result'
require_relative 'flowline/executor/base'
require_relative 'flowline/executor/sequential'
require_relative 'flowline/pipeline'

# Flowline is a Ruby dataflow and pipeline library with declarative step
# definitions, automatic dependency resolution, and sequential execution.
module Flowline
  class << self
    # Define a new pipeline using the DSL.
    #
    # @example
    #   pipeline = Flowline.define do
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
    # @return [Flowline::Pipeline] The defined pipeline
    def define(&)
      Pipeline.new(&)
    end
  end
end
