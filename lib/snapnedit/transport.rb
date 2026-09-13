# frozen_string_literal: true

require "json"

module Snapnedit
  # Turns a request into either a parsed body or a {Snapnedit::Error},
  # retrying the ones it is safe to retry.
  #
  # Retry policy: `429`, any `5xx`, and any network failure (which the adapter
  # surfaces as an {Snapnedit::Error} with `status: 0`) are retried with
  # exponential backoff and full jitter — but only for requests marked
  # idempotent. `POST /jobs`, `POST /destinations` and `POST /embed/tokens`
  # are not: replaying them could bill twice or create two rows.
  # `Retry-After` (seconds) is honoured when the server sends it.
  #
  # @api private
  class Transport
    # Statuses worth trying again.
    RETRYABLE_STATUSES = [408, 429, 500, 502, 503, 504].freeze

    # Longest single backoff, in seconds.
    MAX_BACKOFF = 8.0

    # One prepared request, so the retry loop passes a single value around.
    # @api private
    Request = Struct.new(:verb, :url, :headers, :body, :idempotent, keyword_init: true)

    # @param base_url [String]
    # @param api_key [String, nil] nil sends no `Authorization` header, which
    #   is how the anonymous endpoints (`/operations`, `/embed/sessions`,
    #   `/openapi.json`) are called.
    # @param adapter [#call]
    # @param max_retries [Integer] additional attempts after the first.
    # @param retry_base_delay [Numeric] seconds; the first backoff.
    # @param sleeper [#call] injected for tests; receives the delay in seconds.
    # @param user_agent [String]
    def initialize(base_url:, api_key:, adapter:, max_retries: 2, retry_base_delay: 0.5,
                   sleeper: ->(seconds) { sleep(seconds) }, user_agent: "snapnedit-ruby/#{Snapnedit::VERSION}")
      @base_url = base_url.chomp("/")
      @api_key = api_key
      @adapter = adapter
      @max_retries = max_retries
      @retry_base_delay = retry_base_delay
      @sleeper = sleeper
      @user_agent = user_agent
    end

    # @return [String]
    attr_reader :base_url

    # Performs a request against the api and returns the parsed JSON body.
    #
    # @param method [Symbol]
    # @param path [String] api path, e.g. `"/jobs"`.
    # @param body [Object, nil] serialized as JSON when given.
    # @param idempotent [Boolean] whether a retry is safe.
    # @param auth [Boolean] whether to send the api key.
    # @param expect_empty [Boolean] for `204 No Content` routes.
    # @return [Object, nil] the parsed body, or nil for `expect_empty`.
    # @raise [Snapnedit::Error]
    def json(method, path, body: nil, idempotent: false, auth: true, expect_empty: false)
      headers = { "accept" => "application/json" }
      payload = nil
      unless body.nil?
        headers["content-type"] = "application/json"
        payload = JSON.generate(body)
      end

      response = perform(method, Util.resolve(@base_url, path), headers: headers, body: payload,
                                                                idempotent: idempotent, auth: auth)
      return nil if expect_empty

      parse_json(response)
    end

    # Performs a request and returns the raw {HTTP::Response} (bytes intact) —
    # used for downloads, presigned PUTs and the design renderer.
    #
    # @param method [Symbol]
    # @param url [String] an absolute url OR an api path.
    # @param headers [Hash{String => String}]
    # @param body [String, nil]
    # @param idempotent [Boolean]
    # @param auth [Boolean]
    # @return [HTTP::Response]
    # @raise [Snapnedit::Error]
    def raw(method, url, headers: {}, body: nil, idempotent: false, auth: true)
      perform(method, Util.resolve(@base_url, url), headers: headers, body: body,
                                                    idempotent: idempotent, auth: auth)
    end

    private

    def perform(method, url, headers:, body:, idempotent:, auth:)
      headers = headers.transform_keys(&:downcase)
      headers["user-agent"] = @user_agent
      headers["authorization"] = "Bearer #{@api_key}" if auth && @api_key
      request = Request.new(verb: method, url: url, headers: headers, body: body, idempotent: idempotent)

      attempt = 0
      loop do
        response = attempt_once(request, attempt)
        return response if response.success?
        raise error_from(response, url) unless retryable?(request, response, attempt)

        backoff(attempt, retry_after(response))
        attempt += 1
      end
    end

    def retryable?(request, response, attempt)
      request.idempotent && attempt < @max_retries && RETRYABLE_STATUSES.include?(response.status)
    end

    # Runs one attempt; a network failure is retried in place when allowed.
    def attempt_once(request, attempt)
      @adapter.call(method: request.verb, url: request.url, headers: request.headers, body: request.body)
    rescue Snapnedit::Error => e
      raise e unless request.idempotent && e.status.to_i.zero? && attempt < @max_retries

      backoff(attempt, nil)
      attempt_once(request, attempt + 1)
    end

    def retry_after(response)
      value = response.headers["retry-after"]
      return nil if value.nil?

      seconds = Float(value, exception: false)
      seconds if seconds&.positive?
    end

    def backoff(attempt, retry_after_seconds)
      delay = retry_after_seconds || [@retry_base_delay * (2**attempt), MAX_BACKOFF].min
      # Full jitter: spread a thundering herd out over the whole window.
      @sleeper.call(retry_after_seconds ? delay : rand * delay)
    end

    def parse_json(response)
      return nil if response.body.nil? || response.body.empty?

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Snapnedit::Error.new(
        "expected JSON from the snapnedit api but got #{e.message}",
        code: ErrorCodes::INTERNAL,
        status: response.status
      )
    end

    # `{ "error": { "code", "message" } }` — the uniform envelope every route
    # sends on a non-2xx.
    def error_from(response, url)
      envelope = response.json
      error = envelope.is_a?(Hash) ? envelope["error"] : nil

      if error.is_a?(Hash)
        Snapnedit::Error.new(
          error["message"].is_a?(String) ? error["message"] : "request to #{url} failed",
          code: ErrorCodes.coerce(error["code"]),
          status: response.status
        )
      else
        Snapnedit::Error.new(
          "request to #{url} failed with status #{response.status}",
          code: ErrorCodes::INTERNAL,
          status: response.status
        )
      end
    end
  end
end
