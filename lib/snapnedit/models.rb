# frozen_string_literal: true

module Snapnedit
  # Base for every response object: a thin, read-only view over the parsed
  # JSON the api sent. The raw hash is always reachable at {#to_h}, so a field
  # this gem does not model yet is never lost.
  class Model
    # @param raw [Hash] the parsed JSON object, string-keyed.
    def initialize(raw)
      @raw = raw.freeze
    end

    # @return [Hash] the raw, string-keyed JSON object the api sent.
    def to_h
      @raw
    end

    # @param key [String]
    # @return [Object, nil] a raw field, including ones this gem does not model.
    def [](key)
      @raw[key]
    end

    # @return [String]
    def inspect
      "#<#{self.class.name} #{@raw.inspect}>"
    end
  end

  # A short-lived signed url the api minted: an upload PUT target, or a result
  # download. `url` may be a same-origin PATH (`/_local/...`) rather than an
  # absolute url — {Client} resolves it against `base_url` for you.
  class SignedUrl < Model
    # @return [String]
    def url = @raw["url"]

    # @return [String] ISO-8601.
    def expires_at = @raw["expiresAt"]
  end

  # One entry of the operation catalog (`GET /operations`).
  class Operation < Model
    # @return [String] e.g. `"remove-background"`.
    def id = @raw["id"]

    # @return [String] human label.
    def label = @raw["label"]

    # @return [Array<String>] accepted input mime types.
    def accept = @raw["accept"]

    # @return [Integer] longest edge the api will accept, in pixels.
    def max_input_dimension = @raw["maxInputDimension"]

    # @return [Hash] JSON Schema for this operation's `params`. Strict: an
    #   unrecognized key is a 400, not an ignored field.
    def params_json_schema = @raw["paramsJsonSchema"]

    # @return [Boolean] whether a job needs `params[:maskAssetId]`.
    def requires_mask? = @raw["requiresMask"] == true

    # @return [String]
    def description = @raw["description"]

    # @return [String]
    def seo_title = @raw["seoTitle"]

    # @return [Integer, nil] credits, from {Operations::CREDIT_COSTS}.
    def credit_cost = Operations.credit_cost(id)
  end

  # A confirmed upload: the asset id a job refers to, plus the content hash
  # the api computed over the bytes it actually received.
  class Upload < Model
    # @return [String] pass this to {Client#create_job} / {Client#run}.
    def asset_id = @raw["assetId"]

    # @return [String, nil] 64 lower-case hex characters. The cache key is
    #   derived from it, so an identical re-submission is a free cache hit.
    def content_hash = @raw["contentHash"]

    # @return [Integer, nil] byte length as stored.
    def bytes = @raw["bytes"]
  end

  # How a job's result travelled to the caller's own bucket. Present only on a
  # job that named a `destination` (or inherited the account default).
  class Delivery < Model
    # @return [String] `"pending"`, `"delivered"` or `"failed"`.
    def status = @raw["status"]

    # @return [Boolean]
    def pending? = status == "pending"

    # @return [Boolean]
    def delivered? = status == "delivered"

    # @return [Boolean] a failed delivery does NOT fail the job — the result
    #   is still downloadable.
    def failed? = status == "failed"

    # @return [Integer]
    def attempts = @raw["attempts"]

    # @return [String, nil] ISO-8601.
    def delivered_at = @raw["deliveredAt"]

    # @return [Integer, nil] the bucket's HTTP status on the last attempt.
    def status_code = @raw["statusCode"]

    # @return [String, nil] why it failed.
    def error = @raw["error"]

    # @return [String, nil] the object key written (saved destinations).
    def key = @raw["key"]

    # @return [String, nil] the bucket written to (saved destinations).
    def bucket = @raw["bucket"]

    # @return [Boolean] whether snapnedit dropped its own copy after the
    #   bucket confirmed (`delete_after_delivery`). {Job#download} is then nil.
    def local_copy_deleted? = @raw["localCopyDeleted"] == true
  end

  # What the api will admit about a job's `destination`: the KIND, and for a
  # saved destination the account's own id and label. Never the presigned url
  # or its headers — those are bearer credentials for your bucket and are
  # never echoed back by any endpoint or webhook.
  class DestinationSummary < Model
    # @return [String] `"presigned-put"` or `"saved"`.
    def type = @raw["type"]

    # @return [Boolean]
    def presigned_put? = type == "presigned-put"

    # @return [Boolean]
    def saved? = type == "saved"

    # @return [String, nil] the saved destination's id.
    def id = @raw["id"]

    # @return [String, nil] the saved destination's name; absent if it has
    #   since been deleted.
    def name = @raw["name"]
  end

  # A job, as `GET /jobs/{id}` reports it.
  #
  # Note the two wire shapes: `POST /jobs` NESTS the status under `status`
  # while `GET /jobs/{id}` FLATTENS `state` to the top level. This class
  # presents the flattened view for both — {#to_h} keeps whichever shape the
  # api actually sent.
  class Job < Model
    # Terminal states: nothing further will happen to the job.
    TERMINAL_STATES = %w[succeeded failed canceled].freeze

    # @param raw [Hash] the response body.
    # @param job_id [String, nil] the id, when the body does not carry one
    #   (`GET /jobs/{id}` does not echo it).
    # @param http_status [Integer, nil] the status the api answered with —
    #   `202` for a newly queued job, `200` for a cache hit.
    def initialize(raw, job_id: nil, http_status: nil)
      super(raw)
      @status = raw["status"].is_a?(Hash) ? raw["status"] : raw
      @job_id = job_id || raw["jobId"]
      @http_status = http_status
    end

    # @return [String]
    def id = @job_id
    alias job_id id

    # @!attribute [r] status
    #   @return [Hash] the flattened status object (`state`, `download`, ...).
    # @!attribute [r] http_status
    #   @return [Integer, nil] the HTTP status of the response that produced
    #     this job.
    attr_reader :status, :http_status

    # Whether the result came out of the cache rather than a model run.
    #
    # Reads the api's own {#cached?} flag first and falls back to the `200`
    # (rather than `202`) a cache hit is answered with, so this still works on
    # a {Job} built from a `GET /jobs/{id}` body, which carries no status code.
    #
    # @return [Boolean]
    def cache_hit? = cached? || @http_status == 200

    # @return [String] `"queued"`, `"processing"`, `"succeeded"`, `"failed"`
    #   or `"canceled"`.
    def state = @status["state"]

    # @return [Boolean]
    def queued? = state == "queued"

    # @return [Boolean]
    def processing? = state == "processing"

    # @return [Boolean]
    def succeeded? = state == "succeeded"

    # @return [Boolean]
    def failed? = state == "failed"

    # @return [Boolean]
    def canceled? = state == "canceled"

    # @return [Boolean] whether the job reached a terminal state.
    def terminal? = TERMINAL_STATES.include?(state)

    # Whether there is nothing left to wait for: terminal AND, if the job has
    # a destination, its delivery has settled.
    #
    # The second half matters for exactly one case — a CACHE HIT with a
    # destination, which comes back already `succeeded` with `delivery`
    # still `pending` because pushing the bytes to your bucket is the
    # worker's work and it has not run yet.
    #
    # @return [Boolean]
    def settled?
      return false unless terminal?

      !(succeeded? && delivery&.pending?)
    end

    # @return [String, nil] the result asset id, on a succeeded job.
    def output_asset_id = @status["outputAssetId"]

    # A presigned url for the result.
    #
    # @return [SignedUrl, nil] nil when there is no copy on snapnedit's side
    #   to sign one for: the job was delivered to a saved destination with
    #   `delete_after_delivery`, so the only copy is in your bucket (see
    #   {Delivery#bucket} / {Delivery#key}).
    def download
      raw = @status["download"]
      raw.is_a?(Hash) ? SignedUrl.new(raw) : nil
    end

    # Credits actually debited for THIS job.
    #
    # 0 for a free operation, a cache hit, a delivery-only clone and any
    # unmetered website/anonymous job. Debited at creation time and refunded in
    # full if the job ends `failed`.
    #
    # @return [Integer]
    def credit_cost = @raw["creditCost"] || 0

    # Whether this row was satisfied from the result cache: no model ran and
    # nothing was billed. A cache hit is still a job — one row per REQUEST — so
    # this is a NEW job id pointing at the SAME {#output_asset_id} as the job
    # whose result it reuses.
    #
    # @return [Boolean]
    def cached? = @raw["cached"] == true

    # Whether this row exists only to deliver an already-cached result to a
    # destination: `cached?` with a bucket to write to, so the worker has
    # something to do even though no model will run.
    #
    # @return [Boolean]
    def delivery_only? = @raw["deliveryOnly"] == true

    # @return [String, nil] the machine-readable failure code, on a failed job.
    def error_code = @status["errorCode"]

    # @return [String, nil] the human failure message, on a failed job.
    def message = @status["message"]

    # @return [String] `"asset"` or `"url"`. The url itself is never echoed.
    def input_kind = (@raw["input"] || {})["kind"]

    # @return [DestinationSummary, nil]
    def destination
      raw = @raw["destination"]
      raw.is_a?(Hash) ? DestinationSummary.new(raw) : nil
    end

    # @return [Delivery, nil]
    def delivery
      raw = @raw["delivery"]
      raw.is_a?(Hash) ? Delivery.new(raw) : nil
    end
  end

  # What {Client#run} resolves to.
  class RunResult
    # @return [String]
    attr_reader :job_id
    # @return [Job] the final job, for anything not surfaced here.
    attr_reader :job
    # @return [String, nil] the result bytes, or nil when the download was
    #   skipped (see {#downloaded?}).
    attr_reader :output
    # @return [String, nil] the result's content type, when downloaded.
    attr_reader :mime

    # @api private
    def initialize(job:, output: nil, mime: nil, downloaded: false)
      @job = job
      @job_id = job.id
      @output = output
      @mime = mime
      @downloaded = downloaded
    end

    # Whether the bytes are attached. False when the result went straight to
    # your bucket (an explicit `destination:` that delivered), when you passed
    # `download: false`, or when `delete_after_delivery` removed snapnedit's
    # copy.
    # @return [Boolean]
    def downloaded? = @downloaded

    # @return [SignedUrl, nil] see {Job#download}.
    def download = @job.download

    # @return [String] `"asset"` or `"url"`.
    def input_kind = @job.input_kind

    # @return [DestinationSummary, nil]
    def destination = @job.destination

    # @return [Delivery, nil]
    def delivery = @job.delivery

    # @return [Integer] credits debited for the job — see {Job#credit_cost}.
    def credit_cost = @job.credit_cost

    # @return [Boolean] whether the result came from the cache, unbilled.
    def cached? = @job.cached?

    # Writes {#output} to +path+.
    # @param path [String]
    # @return [Integer] bytes written.
    # @raise [Snapnedit::Error] if there are no bytes to write.
    def write(path)
      raise Snapnedit::Error, "run result has no bytes (downloaded? == false)" if @output.nil?

      File.binwrite(path, @output)
    end

    # @return [String]
    def inspect
      "#<Snapnedit::RunResult job_id=#{@job_id.inspect} state=#{@job.state.inspect} " \
        "downloaded=#{@downloaded} bytes=#{@output&.bytesize.inspect}>"
    end
  end

  # A saved storage destination: an S3-compatible bucket the account has
  # registered once, so a job can name it by id and the worker signs the PUT
  # itself. The secret access key is never echoed by any response — only
  # {#access_key_id_last4}.
  class Destination < Model
    # @return [String] uuid.
    def id = @raw["id"]

    # @return [String]
    def name = @raw["name"]

    # @return [String] `"aws-s3"`, `"cloudflare-r2"`, `"backblaze-b2"` or
    #   `"s3-compatible"`.
    def provider = @raw["provider"]

    # @return [String]
    def bucket = @raw["bucket"]

    # @return [String, nil]
    def region = @raw["region"]

    # @return [String, nil]
    def endpoint = @raw["endpoint"]

    # @return [Boolean]
    def force_path_style? = @raw["forcePathStyle"] == true

    # @return [String] prefixed onto every object key written here.
    def key_prefix = @raw["keyPrefix"]

    # @return [String] the last 4 characters of the access key id.
    def access_key_id_last4 = @raw["accessKeyIdLast4"]

    # @return [Boolean] whether jobs that name no destination land here.
    def default? = @raw["isDefault"] == true

    # @return [Boolean] whether snapnedit drops its own copy of a result once
    #   the bucket confirms the write.
    def delete_after_delivery? = @raw["deleteAfterDelivery"] == true

    # @return [Hash, nil] `{ "status" => "ok"|"failed", "at" => ..., "error" => ... }`.
    def last_test = @raw["lastTest"]

    # @return [String] ISO-8601.
    def created_at = @raw["createdAt"]

    # @return [String] ISO-8601.
    def updated_at = @raw["updatedAt"]
  end

  # The outcome of {Destinations#test} — a real round trip against the bucket
  # (a probe object written under the destination's own prefix, then deleted),
  # not a credential format check. The HTTP call always succeeds; {#ok?} says
  # whether the bucket did.
  class DestinationTest < Model
    # @return [Boolean]
    def ok? = @raw["ok"] == true

    # @return [Integer]
    def latency_ms = @raw["latencyMs"]

    # @return [String, nil] present only when {#ok?} is false.
    def error = @raw["error"]
  end

  # A one-shot server-signed PUT into a saved destination's bucket
  # ({Destinations#presign_upload}). Send the bytes yourself with exactly
  # these {#headers}.
  class PresignedUpload < Model
    # @return [String] absolute url.
    def url = @raw["url"]

    # @return [String] always `"PUT"`.
    def method = @raw["method"]

    # @return [Hash{String => String}] headers the signature requires.
    def headers = @raw["headers"]

    # @return [String] `<keyPrefix>YYYY/MM/DD/export-<ts>-<6 chars>.<ext>`.
    def key = @raw["key"]

    # @return [String]
    def bucket = @raw["bucket"]

    # @return [String] ISO-8601.
    def expires_at = @raw["expiresAt"]
  end

  # A short-lived signed embed token.
  class EmbedToken < Model
    # @return [String] present it as `Authorization: Bearer <token>`.
    def token = @raw["token"]

    # @return [String] ISO-8601.
    def expires_at = @raw["expiresAt"]
  end
end
