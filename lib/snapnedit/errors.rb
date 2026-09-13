# frozen_string_literal: true

module Snapnedit
  # Every machine-readable error code the snapnedit api can return, as
  # constants. Branch on {Error#code} against these — never on
  # {Error#message}, which is human text and changes.
  #
  # The list is closed: it mirrors the `ErrorEnvelope` enum in the api's
  # OpenAPI document (`components.schemas.ErrorEnvelope`).
  #
  # @example
  #   begin
  #     client.run(Snapnedit::Operations::UPSCALE, "cat.png", params: { factor: "4" })
  #   rescue Snapnedit::Error => e
  #     retry if e.code == Snapnedit::ErrorCodes::RATE_LIMITED
  #     raise
  #   end
  module ErrorCodes
    # The request body failed validation (bad params, unknown param key, a
    # mask-guided operation with no `maskAssetId`, ...).
    INVALID_INPUT = "invalid_input"
    # The declared upload mime is not one snapnedit accepts.
    UNSUPPORTED_MIME = "unsupported_mime"
    # The upload (or a fetched `input_url`) exceeded the size ceiling.
    TOO_LARGE = "too_large"
    # No such resource on the caller's account. Also what a resource belonging
    # to someone else looks like — an id is never an existence oracle.
    NOT_FOUND = "not_found"
    # A job whose input was an external url could not be fetched. Terminal,
    # never retried, credits refunded.
    INPUT_FETCH_FAILED = "input_fetch_failed"
    # A model provider failed on this job.
    PROVIDER_FAILED = "provider_failed"
    # Every provider that can serve the operation failed.
    PROVIDER_EXHAUSTED = "provider_exhausted"
    # Rate limited. Retryable.
    RATE_LIMITED = "rate_limited"
    # Bot protection rejected the caller (browser sessions only).
    BOT_CHECK_FAILED = "bot_check_failed"
    # No usable credential, or an unknown/revoked one.
    UNAUTHORIZED = "unauthorized"
    # Authenticated, but this caller may not do this (e.g. an anonymous caller
    # supplying `input_url`).
    FORBIDDEN = "forbidden"
    # Not enough credits, or a free-tier limit was hit.
    PAYMENT_REQUIRED = "payment_required"
    # Anything else, including a network failure on this side.
    INTERNAL = "internal"

    # Every code above, in the api's own order.
    # @return [Array<String>]
    ALL = [
      INVALID_INPUT,
      UNSUPPORTED_MIME,
      TOO_LARGE,
      NOT_FOUND,
      INPUT_FETCH_FAILED,
      PROVIDER_FAILED,
      PROVIDER_EXHAUSTED,
      RATE_LIMITED,
      BOT_CHECK_FAILED,
      UNAUTHORIZED,
      FORBIDDEN,
      PAYMENT_REQUIRED,
      INTERNAL
    ].freeze

    # @param code [Object]
    # @return [Boolean] whether +code+ is one of {ALL}.
    def self.known?(code)
      ALL.include?(code)
    end

    # Narrows an arbitrary response field to a known code, falling back to
    # {INTERNAL}. A future api code this gem has not been updated for still
    # produces a usable error rather than blowing up while parsing the error.
    #
    # @param value [Object]
    # @return [String]
    def self.coerce(value)
      known?(value) ? value : INTERNAL
    end
  end

  # Raised for any non-2xx api response, for a job that reaches
  # `state: "failed"`, and for a network failure talking to the api.
  #
  # @!attribute [r] code
  #   @return [String, nil] one of {ErrorCodes::ALL} (nil only for
  #     {TimeoutError}, which is not an api response at all).
  # @!attribute [r] status
  #   @return [Integer, nil] the HTTP status that produced it; +0+ for a
  #     network-level failure, nil when there was no response.
  class Error < StandardError
    attr_reader :code, :status

    # @param message [String]
    # @param code [String, nil]
    # @param status [Integer, nil]
    def initialize(message, code: ErrorCodes::INTERNAL, status: nil)
      super(message)
      @code = code
      @status = status
    end

    # @return [String]
    def inspect
      "#<#{self.class.name} code=#{code.inspect} status=#{status.inspect} #{message.inspect}>"
    end
  end

  # Raised when {Client#wait_for_job} (and therefore {Client#run}) polls past
  # its +timeout+ without the job reaching a terminal, settled state. Not an
  # api response, so it carries no {Error#code} or {Error#status}.
  class TimeoutError < Error
    # @param message [String]
    def initialize(message)
      super(message, code: nil, status: nil)
    end
  end

  # Raised by {Webhooks.construct_event} when a delivery's signature does not
  # verify. Use {Webhooks.verify} instead if you would rather branch on a
  # boolean.
  class SignatureVerificationError < Error
    # @param message [String]
    def initialize(message = "webhook signature verification failed")
      super(message, code: ErrorCodes::UNAUTHORIZED, status: nil)
    end
  end
end
