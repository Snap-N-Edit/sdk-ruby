# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Snapnedit
  # The HTTP seam. Everything the gem sends goes through an *adapter* — an
  # object answering `#call(method:, url:, headers:, body:)` and returning a
  # {Response}. {Adapter} is the stdlib `net/http` one used by default;
  # injecting your own (see `Client#initialize`'s `http:`) is how the unit
  # specs run with no network and how you would plug in a different HTTP
  # library or instrumentation.
  module HTTP
    # One HTTP response, adapter-agnostic.
    #
    # @!attribute [r] status
    #   @return [Integer] the HTTP status code.
    # @!attribute [r] headers
    #   @return [Hash{String => String}] response headers, keys down-cased.
    # @!attribute [r] body
    #   @return [String] the raw response body (binary-safe).
    Response = Struct.new(:status, :headers, :body, keyword_init: true) do
      # @return [Boolean] 2xx.
      def success?
        status >= 200 && status < 300
      end

      # @return [Object, nil] the body parsed as JSON, or nil if it is not JSON.
      def json
        return nil if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      # @return [String, nil] the `content-type` header.
      def content_type
        headers["content-type"]
      end
    end

    # The default adapter: `Net::HTTP`, one connection per request, no
    # dependencies. Raises {Snapnedit::Error} with `status: 0` for anything
    # that never became a response (DNS, connect, TLS, read timeout) so the
    # transport can treat it as retryable.
    class Adapter
      # Errors `Net::HTTP` can raise that mean "no response happened".
      NETWORK_ERRORS = [
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::EHOSTUNREACH,
        Errno::EPIPE,
        EOFError,
        IOError,
        Net::OpenTimeout,
        Net::ReadTimeout,
        OpenSSL::SSL::SSLError,
        SocketError
      ].freeze

      # @param open_timeout [Numeric] seconds to wait for the connection.
      # @param read_timeout [Numeric] seconds to wait for the response.
      def initialize(open_timeout: 10, read_timeout: 60)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      # @param method [Symbol] `:get`, `:post`, `:put`, `:patch` or `:delete`.
      # @param url [String] an absolute url.
      # @param headers [Hash{String => String}]
      # @param body [String, nil]
      # @return [Response]
      # @raise [Snapnedit::Error] with `status: 0` on a network failure.
      def call(method:, url:, headers: {}, body: nil)
        uri = URI.parse(url)
        request = build_request(method, uri, headers, body)

        response = Net::HTTP.start(
          uri.host, uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: @open_timeout,
          read_timeout: @read_timeout
        ) { |http| http.request(request) }

        Response.new(
          status: response.code.to_i,
          headers: response.each_header.to_h { |k, v| [k.downcase, v] },
          body: response.body || ""
        )
      rescue *NETWORK_ERRORS => e
        raise Snapnedit::Error.new(
          "network error calling #{url}: #{e.class}: #{e.message}",
          code: ErrorCodes::INTERNAL,
          status: 0
        )
      end

      private

      REQUEST_CLASSES = {
        get: Net::HTTP::Get,
        post: Net::HTTP::Post,
        put: Net::HTTP::Put,
        patch: Net::HTTP::Patch,
        delete: Net::HTTP::Delete
      }.freeze
      private_constant :REQUEST_CLASSES

      def build_request(method, uri, headers, body)
        klass = REQUEST_CLASSES.fetch(method) { raise ArgumentError, "unsupported HTTP method #{method.inspect}" }
        path = uri.request_uri
        request = klass.new(path)
        headers.each { |name, value| request[name] = value }
        request.body = body unless body.nil?
        request
      end
    end
  end
end
