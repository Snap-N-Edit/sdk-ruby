# frozen_string_literal: true

module Snapnedit
  # The embed endpoints: how a third-party site or app gets a short-lived,
  # signed token that authenticates as your account without shipping your
  # secret key to a browser. Reach it as {Client#embed}.
  #
  # Two doors:
  #
  # * {#create_session} is called BY the embed frame with a `pk_` publishable
  #   key and its host origin. Unauthenticated — the key plus the origin
  #   allowlist configured on it IS the credential.
  # * {#create_token} is called by YOUR server, holding an `sk_` key, to mint
  #   a token scoped to one end user (a TTL, a credit cap, an operation
  #   allowlist).
  #
  # A verified embed token is billed exactly like an API key, never like a
  # free website session.
  class Embed
    # @param transport [Transport]
    # @api private
    def initialize(transport)
      @transport = transport
    end

    # `POST /embed/sessions` — exchange a publishable key for a token. Sends
    # no `Authorization` header even if the client has an api key.
    #
    # @param publishable_key [String] the account's `pk_` key.
    # @param host_origin [String] a browser origin
    #   (`"https://app.example.com"`) or a native shell id
    #   (`"native:com.acme.photos"`) for a WebView host that has none.
    # @return [EmbedToken]
    # @raise [Snapnedit::Error] `forbidden` when the origin is not on the
    #   key's allowlist; `unauthorized` for a key that is not publishable.
    def create_session(publishable_key:, host_origin:)
      body = @transport.json(
        :post, "/embed/sessions",
        body: { "publishableKey" => publishable_key, "hostOrigin" => host_origin },
        auth: false
      )
      EmbedToken.new(body)
    end

    # `POST /embed/tokens` — mint a scoped token with your secret key.
    #
    # @param ttl_seconds [Integer, nil] 60..86_400.
    # @param end_user_id [String, nil] your own identifier for the end user,
    #   echoed on the jobs it creates.
    # @param max_credits [Integer, nil] a spend cap for this token.
    # @param allowed_operations [Array<String>, nil] see {Operations::ALL}.
    # @param origin [String, nil] restrict the token to one origin.
    # @return [EmbedToken]
    # @raise [Snapnedit::Error] `unauthorized` without an `sk_` key.
    def create_token(ttl_seconds: nil, end_user_id: nil, max_credits: nil,
                     allowed_operations: nil, origin: nil)
      payload = Util.compact(
        ttl_seconds: ttl_seconds, end_user_id: end_user_id, max_credits: max_credits,
        allowed_operations: allowed_operations, origin: origin
      )
      EmbedToken.new(@transport.json(:post, "/embed/tokens", body: Util.camelize_keys(payload)))
    end
  end
end
