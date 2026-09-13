# frozen_string_literal: true

require "json"
require "openssl"

module Snapnedit
  # Verifies the signature on an outbound webhook delivery.
  #
  # A snapnedit account can register endpoint urls that receive a signed HTTP
  # POST when a job finishes. Every delivery carries:
  #
  #     X-Snapnedit-Signature: t=<unix seconds>,v1=<hex>
  #
  # comma-separated `k=v` pairs. Unknown keys are ignored, and `v1` may appear
  # more than once during a secret rotation — a delivery is accepted if ANY
  # `v1` matches. The signed string is `"#{t}.#{raw_body}"`, MACed with
  # HMAC-SHA256 under the endpoint's plaintext signing secret and hex encoded.
  #
  # Four rules that are part of the contract, not implementation detail:
  #
  # 1. `raw_body` is the bytes you received, verified BEFORE any JSON parse —
  #    a re-serialized body will not match.
  # 2. The comparison is constant time.
  # 3. Hex is compared case-insensitively against lower case.
  # 4. {verify} returns false — never raises — for a malformed header, a bad
  #    signature or a stale timestamp, so every falsy result can be treated
  #    identically.
  #
  # @example Rails
  #   raw = request.raw_post
  #   unless Snapnedit::Webhooks.verify(raw, request.headers["X-Snapnedit-Signature"], secret, tolerance: 300)
  #     return head :bad_request
  #   end
  #   event = JSON.parse(raw)
  module Webhooks
    # The header snapnedit signs every delivery with.
    SIGNATURE_HEADER = "X-Snapnedit-Signature"
    # The event type, also present in the body's `type`.
    EVENT_HEADER = "X-Snapnedit-Event"
    # The delivery id, also present in the body's `id`.
    DELIVERY_HEADER = "X-Snapnedit-Delivery"

    # Event types snapnedit sends today. Treat an unrecognized `type` as a
    # forward-compatible no-op rather than an error.
    EVENT_TYPES = %w[job.succeeded job.failed].freeze

    # The conventional freshness window, in seconds. Not applied unless you
    # pass it.
    DEFAULT_TOLERANCE = 300

    module_function

    # Verifies a delivery.
    #
    # @param payload [String] the RAW request body, exactly as received.
    # @param signature [String, nil] the `X-Snapnedit-Signature` header value.
    # @param secret [String] the endpoint's plaintext signing secret
    #   (`whsec_...`).
    # @param tolerance [Integer, nil] reject a signed timestamp more than this
    #   many seconds from +now+. Omit to check the MAC only.
    # @param now [Integer] current unix seconds; injectable for tests.
    # @return [Boolean] true only when a signature matches and, if requested,
    #   the timestamp is fresh. Never raises.
    def verify(payload, signature, secret, tolerance: nil, now: Time.now.to_i)
      parsed = parse_header(signature)
      return false if parsed.nil?

      timestamp, candidates = parsed
      return false if tolerance && (now - timestamp).abs > tolerance

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{payload}")
      candidates.any? { |candidate| secure_compare(expected, candidate.downcase) }
    end

    # Verifies a delivery and parses it.
    #
    # @param payload [String] the RAW request body.
    # @param signature [String, nil] the `X-Snapnedit-Signature` header value.
    # @param secret [String] the endpoint's signing secret.
    # @param tolerance [Integer, nil] see {verify}.
    # @param now [Integer] current unix seconds.
    # @return [Hash] the parsed event: `{ "id", "type", "created", "data" }`.
    #   `data` carries `jobId`, `operation`, `status`, and either
    #   `outputAssetId`/`download` or `errorCode`/`message`, plus the
    #   `input`/`destination`/`delivery` envelope.
    # @raise [SignatureVerificationError] if the signature does not verify, or
    #   the verified body is not JSON.
    def construct_event(payload, signature, secret, tolerance: nil, now: Time.now.to_i)
      unless verify(payload, signature, secret, tolerance: tolerance, now: now)
        raise SignatureVerificationError,
              "webhook signature verification failed for header #{signature.inspect}"
      end

      JSON.parse(payload)
    rescue JSON::ParserError => e
      raise SignatureVerificationError, "webhook body verified but is not JSON: #{e.message}"
    end

    # Parses `t=<unix seconds>,v1=<hex>[,v1=<hex>...]`.
    #
    # @param header [String, nil]
    # @return [Array(Integer, Array<String>), nil] nil for any header without
    #   a numeric `t` and at least one non-empty `v1`.
    # @api private
    def parse_header(header)
      return nil unless header.is_a?(String)

      timestamp = nil
      signatures = []
      header.split(",").each do |part|
        key, _, value = part.partition("=")
        key = key.strip
        value = value.strip
        if key == "t"
          parsed = Integer(value, exception: false)
          timestamp = parsed unless parsed.nil?
        elsif key == "v1" && !value.empty?
          signatures << value
        end
      end
      return nil if timestamp.nil? || signatures.empty?

      [timestamp, signatures]
    end

    # Constant-time string comparison. A length mismatch short-circuits (a
    # length is not secret); a value mismatch does not.
    #
    # @param expected [String]
    # @param actual [String]
    # @return [Boolean]
    # @api private
    def secure_compare(expected, actual)
      return false unless expected.bytesize == actual.bytesize

      OpenSSL.fixed_length_secure_compare(expected, actual)
    end
  end
end
