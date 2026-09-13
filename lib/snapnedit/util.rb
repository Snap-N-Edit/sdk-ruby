# frozen_string_literal: true

require "time"
require "uri"

module Snapnedit
  # Small internal helpers shared by the clients. Not part of the public API.
  # @api private
  module Util
    module_function

    # Recursively converts snake_case Symbol/String keys to the camelCase the
    # api speaks, so callers can write idiomatic Ruby
    # (`secret_access_key:`) for a wire field named `secretAccessKey`. Keys
    # that already contain a capital are passed through untouched, so a caller
    # who prefers the wire spelling is never second-guessed.
    #
    # @param value [Object]
    # @return [Object]
    def camelize_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), out|
          out[camelize(key.to_s)] = camelize_keys(val)
        end
      when Array
        value.map { |item| camelize_keys(item) }
      else
        value
      end
    end

    # @param key [String]
    # @return [String]
    def camelize(key)
      return key unless key.include?("_")

      head, *rest = key.split("_")
      head + rest.map(&:capitalize).join
    end

    # Drops keys whose value is nil, so an omitted keyword argument means
    # "don't send the field" rather than "send null" — a distinction the api
    # cares about for `destination`.
    #
    # @param hash [Hash]
    # @return [Hash]
    def compact(hash)
      hash.compact
    end

    # Percent-encodes one path segment (an id) so it cannot break out of the
    # path it is interpolated into.
    #
    # @param segment [String]
    # @return [String]
    def escape_segment(segment)
      segment.to_s.b.gsub(/[^A-Za-z0-9\-._~]/) { |c| format("%%%02X", c.ord) }
    end

    # Renders a query string from a Hash of WIRE-spelled keys, dropping every
    # nil and empty value: the api distinguishes "no filter" (count everything)
    # from a filter that matches nothing, so an unset keyword must not become
    # `?keyId=`.
    #
    # @param params [Hash{String => Object, nil}]
    # @return [String] `"?a=1&b=2"`, or `""` when nothing survived.
    def query_string(params)
      pairs = params.filter_map do |key, value|
        next if value.nil? || value.to_s.empty?

        "#{key}=#{escape_segment(value.to_s)}"
      end
      pairs.empty? ? "" : "?#{pairs.join("&")}"
    end

    # Normalizes a time-ish argument to the ISO-8601 the api parses. A String
    # passes through untouched, so a caller who wants the api's bare
    # `YYYY-MM-DD` shorthand (a whole UTC day) can still write it.
    #
    # @param value [Time, Date, DateTime, String, nil]
    # @return [String, nil]
    def iso8601(value)
      case value
      when nil, String then value
      when Time then value.utc.iso8601(3)
      else
        unless value.respond_to?(:iso8601)
          raise ArgumentError, "expected a Time, a Date or an ISO-8601 String (got #{value.class})"
        end

        value.iso8601
      end
    end

    # Joins a base url and a path, tolerating a trailing slash on either.
    #
    # @param base_url [String]
    # @param path [String] an absolute path, or an absolute url (returned as-is).
    # @return [String]
    def resolve(base_url, path)
      return path if path.start_with?("http://", "https://")

      "#{base_url.chomp("/")}#{path.start_with?("/") ? path : "/#{path}"}"
    end
  end
end
