# frozen_string_literal: true

require 'fileutils'
require 'digest'

module Flowrb
  # Caching support for pipeline step results (Luigi-style).
  # Allows resuming failed pipelines from the last successful step.
  module Cache
    # Abstract base class for cache stores.
    class Base
      def exist?(_key)
        raise NotImplementedError
      end

      def read(_key)
        raise NotImplementedError
      end

      def write(_key, _value)
        raise NotImplementedError
      end

      def delete(_key)
        raise NotImplementedError
      end

      def clear
        raise NotImplementedError
      end
    end

    # In-memory cache store. Useful for testing and single-run caching.
    class MemoryStore < Base
      def initialize
        super
        @data = {}
      end

      def exist?(key)
        @data.key?(key.to_s)
      end

      def read(key)
        @data[key.to_s]
      end

      def write(key, value)
        @data[key.to_s] = value
      end

      def delete(key)
        @data.delete(key.to_s)
      end

      def clear
        @data.clear
      end
    end

    # File-based cache store. Persists results to disk for cross-run caching.
    class FileStore < Base
      attr_reader :dir

      def initialize(dir)
        super()
        @dir = dir
        FileUtils.mkdir_p(dir)
      end

      def exist?(key)
        File.exist?(path_for(key))
      end

      def read(key)
        return nil unless exist?(key)

        File.open(path_for(key), 'rb') do |f|
          Marshal.load(f.read) # rubocop:disable Security/MarshalLoad
        end
      rescue StandardError
        nil
      end

      def write(key, value)
        File.binwrite(path_for(key), Marshal.dump(value))
      end

      def delete(key)
        File.delete(path_for(key)) if exist?(key)
      end

      def clear
        FileUtils.rm_rf(Dir.glob(File.join(dir, '*.cache')))
      end

      private

      def path_for(key)
        # Sanitize key to create safe filename
        safe_key = Digest::SHA256.hexdigest(key.to_s)
        File.join(dir, "#{safe_key}.cache")
      end
    end

    # Represents a cached step result
    class CachedResult
      attr_reader :output, :status, :skipped

      def initialize(output:, status:, skipped: false)
        @output = output
        @status = status
        @skipped = skipped
      end

      def skipped?
        @skipped
      end
    end
  end
end
