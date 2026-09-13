# frozen_string_literal: true

module Snapnedit
  # Saved storage destinations: an S3-compatible bucket your account
  # registers once, so a job can name it by id and snapnedit's worker signs
  # the PUT itself at delivery time. Reach it as {Client#destinations}.
  #
  # Rotating a credential therefore applies to jobs that are already queued —
  # only the id is stored on a job.
  #
  # @example
  #   dest = client.destinations.create(
  #     name: "exports",
  #     provider: "cloudflare-r2",
  #     bucket: "my-bucket",
  #     account_id: "abc123def456",
  #     key_prefix: "snapnedit/",
  #     access_key_id: ENV.fetch("R2_KEY_ID"),
  #     secret_access_key: ENV.fetch("R2_SECRET"),
  #     is_default: true
  #   )
  #   client.destinations.test(dest.id).ok? # => true
  class Destinations
    # @param transport [Transport]
    # @api private
    def initialize(transport)
      @transport = transport
    end

    # `GET /destinations`.
    # @return [Array<Destination>]
    # @raise [Snapnedit::Error]
    def list
      body = @transport.json(:get, "/destinations", idempotent: true)
      Array(body["destinations"]).map { |row| Destination.new(row) }
    end

    # `POST /destinations`. Keyword arguments are snake_case; they are sent as
    # the api's camelCase.
    #
    # @param name [String] 1-80 characters.
    # @param provider [String] `"aws-s3"`, `"cloudflare-r2"`, `"backblaze-b2"`
    #   or `"s3-compatible"`.
    # @param bucket [String]
    # @param access_key_id [String]
    # @param secret_access_key [String] stored AES-256-GCM sealed; never
    #   echoed back by any response.
    # @param region [String, nil]
    # @param endpoint [String, nil] required for `s3-compatible`.
    # @param account_id [String, nil] required for `cloudflare-r2`.
    # @param force_path_style [Boolean, nil]
    # @param key_prefix [String, nil] prefixed onto every object key.
    # @param is_default [Boolean, nil] at most one destination per account.
    # @param delete_after_delivery [Boolean, nil] drop snapnedit's own copy of
    #   a result once the bucket confirms the write.
    # @return [Destination]
    # @raise [Snapnedit::Error]
    def create(name:, provider:, bucket:, access_key_id:, secret_access_key:,
               region: nil, endpoint: nil, account_id: nil, force_path_style: nil,
               key_prefix: nil, is_default: nil, delete_after_delivery: nil)
      payload = Util.compact(
        name: name, provider: provider, bucket: bucket,
        access_key_id: access_key_id, secret_access_key: secret_access_key,
        region: region, endpoint: endpoint, account_id: account_id,
        force_path_style: force_path_style, key_prefix: key_prefix,
        is_default: is_default, delete_after_delivery: delete_after_delivery
      )
      body = @transport.json(:post, "/destinations", body: Util.camelize_keys(payload))
      Destination.new(body["destination"])
    end

    # `PATCH /destinations/{id}` — a partial update. Only the fields you pass
    # change. `region:` and `endpoint:` accept an explicit `nil`, which clears
    # them, so pass them only when you mean to.
    #
    # @param id [String]
    # @param patch [Hash] snake_case keys, as in {#create} (minus `provider`
    #   and `account_id`, which are fixed at creation).
    # @return [Destination]
    # @raise [Snapnedit::Error] `not_found` for an id that is not on your
    #   account — never `403`.
    def update(id, **patch)
      body = @transport.json(:patch, path(id), body: Util.camelize_keys(patch), idempotent: true)
      Destination.new(body["destination"])
    end

    # `DELETE /destinations/{id}` — `204`, no body. Jobs already delivered
    # keep their delivery record; a queued job naming it will fail to deliver.
    #
    # @param id [String]
    # @return [void]
    # @raise [Snapnedit::Error]
    def delete(id)
      @transport.json(:delete, path(id), idempotent: true, expect_empty: true)
      nil
    end

    # `POST /destinations/{id}/test` — a real round trip against the bucket.
    # Always answers `200`; read {DestinationTest#ok?}.
    #
    # @param id [String]
    # @return [DestinationTest]
    # @raise [Snapnedit::Error]
    def test(id)
      DestinationTest.new(@transport.json(:post, path(id, "/test"), body: {}, idempotent: true))
    end

    # `POST /destinations/{id}/presign` — a 15-minute signed PUT for exactly
    # one object with exactly one content type. This is how an editor or an
    # embed saves an export straight into your bucket without ever holding
    # your S3 credentials.
    #
    # @param id [String]
    # @param ext [String] one of `png jpg webp avif svg pdf gif`.
    # @param content_type [String] must agree with +ext+, or `400
    #   invalid_input`.
    # @return [PresignedUpload]
    # @raise [Snapnedit::Error]
    def presign_upload(id, ext:, content_type:)
      body = @transport.json(
        :post, path(id, "/presign"),
        body: { "ext" => ext, "contentType" => content_type },
        idempotent: false
      )
      PresignedUpload.new(body)
    end

    private

    def path(id, suffix = "")
      "/destinations/#{Util.escape_segment(id)}#{suffix}"
    end
  end
end
