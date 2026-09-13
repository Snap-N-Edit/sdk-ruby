# frozen_string_literal: true

require "stringio"

module Snapnedit
  # The snapnedit api client.
  #
  # @example The whole flow in one call
  #   client = Snapnedit::Client.new(api_key: ENV.fetch("SNAPNEDIT_API_KEY"))
  #   result = client.run(Snapnedit::Operations::REMOVE_BACKGROUND, "cat.jpg")
  #   result.write("cat-cutout.png")
  #
  # @example Step by step
  #   asset = client.upload("cat.jpg")
  #   job   = client.create_job(Snapnedit::Operations::UPSCALE, asset.asset_id, params: { factor: "4" })
  #   done  = client.wait_for_job(job.id)
  #   bytes = client.download_result(done)
  class Client
    # The hosted api. Point `base_url:` at `http://localhost:8787` for the
    # local stack.
    DEFAULT_BASE_URL = "https://snapnedit.com/api"

    # Seconds between `GET /jobs/{id}` polls.
    DEFAULT_POLL_INTERVAL = 1.0

    # Seconds {#wait_for_job} will poll before raising {TimeoutError}.
    DEFAULT_TIMEOUT = 120.0

    # Sentinel for `destination:` meaning "send no `destination` field at
    # all", which lets the account default (if any) apply. Distinct from
    # `nil`, which explicitly opts out of that default.
    DEFAULT_DESTINATION = :default

    # @return [String] the api origin, without a trailing slash.
    attr_reader :base_url

    # @param api_key [String, nil] your `sk_` secret key, or an embed token.
    #   `nil` calls the api anonymously — enough for {#list_operations},
    #   {Embed#create_session} and {Designs}, but every account endpoint will
    #   answer `401`.
    # @param base_url [String] see {DEFAULT_BASE_URL}.
    # @param http [#call, nil] an HTTP adapter (see {HTTP::Adapter}). Inject
    #   one to test without a network or to use a different HTTP library.
    # @param max_retries [Integer] extra attempts for idempotent requests on
    #   `429`/`5xx`/network failures.
    # @param open_timeout [Numeric] connect timeout, seconds.
    # @param read_timeout [Numeric] response timeout, seconds.
    # @param sleeper [#call] injected for tests; receives a backoff in seconds.
    def initialize(api_key: nil, base_url: DEFAULT_BASE_URL, http: nil, max_retries: 2,
                   open_timeout: 10, read_timeout: 60, sleeper: nil)
      @base_url = base_url.chomp("/")
      adapter = http || HTTP::Adapter.new(open_timeout: open_timeout, read_timeout: read_timeout)
      @transport = Transport.new(
        base_url: @base_url, api_key: api_key, adapter: adapter, max_retries: max_retries,
        **(sleeper ? { sleeper: sleeper } : {})
      )
      @destinations = Destinations.new(@transport)
      @embed = Embed.new(@transport)
      @designs = Designs.new(@transport)
    end

    # Saved storage destinations.
    # @return [Destinations]
    attr_reader :destinations

    # Embed sessions and tokens.
    # @return [Embed]
    attr_reader :embed

    # Declarative designs and the server-side renderer.
    # @return [Designs]
    attr_reader :designs

    # `GET /operations` — the catalog. Public, no credential needed. Every
    # entry carries the JSON Schema for its `params`, so a UI can be rendered
    # straight from it.
    #
    # @return [Array<Operation>]
    # @raise [Snapnedit::Error]
    def list_operations
      Array(@transport.json(:get, "/operations", idempotent: true, auth: false))
        .map { |row| Operation.new(row) }
    end

    # Uploads an image and confirms it, returning the asset a job can name.
    #
    # Three steps behind one call: `POST /uploads` for a presigned PUT, the
    # PUT itself, then `POST /uploads/{id}/confirm` — which is not optional:
    # until it runs the asset carries a placeholder hash and cannot
    # participate in content-based caching.
    #
    # @param input [String, Pathname, IO, StringIO] a filesystem path, or any
    #   IO to read the bytes from. To upload bytes you already hold, wrap them:
    #   `StringIO.new(bytes)`.
    # @param mime [String, nil] declared content type; sniffed from the bytes
    #   (then the file extension) when omitted.
    # @return [Upload]
    # @raise [Snapnedit::Error] `unsupported_mime` for anything but PNG, JPEG
    #   or WebP; `too_large` past the size ceiling.
    def upload(input, mime: nil)
      bytes, path = read_input(input)
      resolved_mime = mime || Mime.detect(bytes, path)

      created = @transport.json(
        :post, "/uploads",
        body: { "mime" => resolved_mime, "bytes" => bytes.bytesize },
        idempotent: true
      )

      # The presigned PUT is self-authenticating; sending our bearer token as
      # well is what some presigned-url schemes (S3 SigV4 among them) reject
      # outright as a conflicting second credential.
      @transport.raw(
        :put, created.dig("upload", "url"),
        headers: { "content-type" => resolved_mime },
        body: bytes, idempotent: true, auth: false
      )

      confirmed = @transport.json(
        :post, "/uploads/#{Util.escape_segment(created["assetId"])}/confirm",
        idempotent: true
      )
      Upload.new(confirmed)
    end

    # `POST /jobs` — enqueue one operation. Returns as soon as the api has
    # accepted it; nothing is downloaded and nothing is waited for.
    #
    # Credits are debited here, at creation time, not at completion. An
    # identical resubmission (same operation, same bytes, same params) is a
    # free cache hit: the api answers `200` with a job that is already
    # `succeeded` ({Job#cache_hit?}).
    #
    # @param operation [String] see {Operations}.
    # @param input [String, Upload, Hash] an asset id (or the {Upload} that
    #   produced it), or `{ url: "https://..." }` to have the SERVER fetch the
    #   bytes from your own storage — https only, no redirects, 30s, and
    #   account-only (an anonymous caller gets `403 forbidden`).
    # @param params [Hash] operation params, validated against the
    #   operation's own strict JSON Schema. An unrecognized key is a `400`.
    # @param destination [Symbol, nil, Hash, Destination, String] where the
    #   RESULT bytes go:
    #
    #   * {DEFAULT_DESTINATION} (the default) — send no field, so your
    #     account's default destination applies if you have one.
    #   * `nil` — explicitly opt out of that default for this job.
    #   * `{ type: "presigned-put", url:, headers: }` — a PUT you signed.
    #   * `{ type: "saved", id: }`, a {Destination}, or its id as a String —
    #     one of your saved destinations; snapnedit signs the PUT itself.
    # @return [Job]
    # @raise [Snapnedit::Error]
    def create_job(operation, input, params: {}, destination: DEFAULT_DESTINATION)
      body = { "operation" => operation, "params" => params }
      body.merge!(job_input_field(input))
      body["destination"] = normalize_destination(destination) unless destination == DEFAULT_DESTINATION

      response = @transport.raw(
        :post, "/jobs",
        headers: { "content-type" => "application/json", "accept" => "application/json" },
        body: JSON.generate(body)
      )
      parsed = JSON.parse(response.body)
      Job.new(parsed, job_id: parsed["jobId"], http_status: response.status)
    end

    # `GET /jobs/{id}` — one poll.
    #
    # @param job_id [String]
    # @return [Job]
    # @raise [Snapnedit::Error] `not_found` for a job that is not yours —
    #   never `403`, so a job id cannot be used as an existence oracle.
    def get_job(job_id)
      raw = @transport.json(:get, "/jobs/#{Util.escape_segment(job_id)}", idempotent: true)
      Job.new(raw, job_id: job_id)
    end

    # Polls `GET /jobs/{id}` until the job is terminal AND, if it has a
    # destination, its delivery has settled.
    #
    # That second condition matters for a cache hit with a destination: it
    # comes back already `succeeded` while its delivery is still `pending`,
    # because pushing the bytes to your bucket is the worker's work and it has
    # not run yet.
    #
    # @param job_id [String]
    # @param poll_interval [Numeric] seconds between polls.
    # @param timeout [Numeric] total budget, in seconds.
    # @return [Job] terminal and settled. A `failed` job is returned, not
    #   raised — {#run} is the one that raises.
    # @raise [TimeoutError] when the budget runs out first.
    # @raise [Snapnedit::Error]
    def wait_for_job(job_id, poll_interval: DEFAULT_POLL_INTERVAL, timeout: DEFAULT_TIMEOUT)
      deadline = monotonic_now + timeout
      loop do
        job = get_job(job_id)
        return job if job.settled?

        remaining = deadline - monotonic_now
        if remaining <= 0
          raise TimeoutError,
                "polling job #{job_id} exceeded timeout (#{timeout}s) without reaching a settled state " \
                "(last state: #{job.state.inspect})"
        end
        sleep([poll_interval, remaining].min)
      end
    end

    # Downloads a job's result bytes.
    #
    # @param job_or_signed_url [Job, SignedUrl, String] a succeeded {Job}, the
    #   {SignedUrl} from it, or a url/path string.
    # @return [String] the bytes (binary).
    # @raise [Snapnedit::Error] when there is nothing to download — a job
    #   delivered to a destination with `delete_after_delivery` has no copy
    #   left on snapnedit's side.
    def download_result(job_or_signed_url)
      signed = case job_or_signed_url
               when Job then job_or_signed_url.download
               when SignedUrl then job_or_signed_url
               when String then nil
               end
      url = signed ? signed.url : job_or_signed_url

      if url.nil? || !url.is_a?(String)
        raise Snapnedit::Error.new(
          "this job has no downloadable result (delivered to your bucket with delete_after_delivery)",
          code: ErrorCodes::NOT_FOUND
        )
      end

      fetch_result(url).body
    end

    # The whole flow: upload the input (and the mask, if any), create the job,
    # poll it to a settled state, and download the result.
    #
    # @param operation [String] see {Operations}.
    # @param input [String, Pathname, IO, StringIO, Hash] a filesystem path,
    #   an IO, or `{ url: "https://..." }` to have the server fetch it.
    # @param params [Hash] operation params.
    # @param mask [String, Pathname, IO, StringIO, nil] a second image for a
    #   mask-guided operation ({Operations::REQUIRES_MASK}). Uploaded and set
    #   as `params[:maskAssetId]` for you. Masks are asset-only — there is no
    #   url form.
    # @param mime [String, nil] content type of +input+ (and of +mask+ when it
    #   is an IO with no path). Sniffed when omitted.
    # @param destination [Symbol, nil, Hash, Destination, String] see
    #   {#create_job}.
    # @param download [Boolean, nil] whether to fetch the result bytes.
    #   `nil` (the default) means: yes, UNLESS you named an explicit
    #   destination and the delivery succeeded — in which case the bytes are
    #   already in your bucket and pulling them back would defeat the point. A
    #   delivery that FAILED still downloads, so you are never left
    #   empty-handed. An account default applied server-side does not flip the
    #   default: a caller who just wrote `run(...)` still expects bytes.
    # @param poll_interval [Numeric] seconds between polls.
    # @param timeout [Numeric] total polling budget, in seconds.
    # @return [RunResult]
    # @raise [Snapnedit::Error] for any api failure, and for a job that
    #   reaches `failed` (with the job's own {Job#error_code}).
    # @raise [TimeoutError]
    def run(operation, input, params: {}, mask: nil, mime: nil, destination: DEFAULT_DESTINATION,
            download: nil, poll_interval: DEFAULT_POLL_INTERVAL, timeout: DEFAULT_TIMEOUT)
      input_ref = url_input?(input) ? input : upload(input, mime: mime)
      job_params = params.dup
      job_params[mask_param_key(job_params)] = upload(mask, mime: mime).asset_id if mask

      created = create_job(operation, input_ref, params: job_params, destination: destination)
      final = if created.settled?
                created
              else
                wait_for_job(created.id, poll_interval: poll_interval, timeout: timeout)
              end

      finish_run(final, destination: destination, download: download)
    end

    # `GET /usage` — what this account has run, what it cost, and where it came
    # from, bucketed along ONE dimension at a time.
    #
    # Everything is optional: `client.usage` is the last 30 days grouped by
    # day. `usage(group_by: "key")` answers "which key is spending the
    # credits"; `usage(source: "embed", group_by: "origin")` answers "which
    # embedding site".
    #
    # Every `POST /jobs` writes one row — a cache hit included — so
    # {UsageFacts#jobs} counts REQUESTS and {UsageFacts#cache_hits} says how
    # many of them ran no model.
    #
    # An EMBED token is scoped to its own key: `key_id:` is forced to it and
    # {UsageReport#keys} comes back empty. A session or `sk_` caller sees the
    # whole account.
    #
    # @param from [Time, Date, String, nil] inclusive start. A bare
    #   `"YYYY-MM-DD"` is midnight UTC. Defaults to 30 days before +to+.
    # @param to [Time, Date, String, nil] inclusive end. A bare `"YYYY-MM-DD"`
    #   covers that whole UTC day. Defaults to now.
    # @param group_by [String, Symbol, nil] one of {Usage::GROUP_BY}; `"day"`
    #   when omitted.
    # @param key_id [String, nil] only jobs authenticated with this api key.
    # @param origin [String, nil] only embed jobs from this host surface
    #   (`"https://app.example.com"` or `"native:com.acme.photos"`).
    # @param operation [String, nil] only jobs for this operation.
    # @param source [String, Symbol, nil] one of {Usage::SOURCES}.
    # @return [UsageReport]
    # @raise [Snapnedit::Error] `unauthorized` without an account credential;
    #   `invalid_input` for an unparseable date, `from` after `to`, or a range
    #   over 366 days.
    def usage(from: nil, to: nil, group_by: nil, key_id: nil, origin: nil, operation: nil, source: nil)
      query = Util.query_string(
        "from" => Util.iso8601(from), "to" => Util.iso8601(to), "groupBy" => group_by,
        "keyId" => key_id, "origin" => origin, "operation" => operation, "source" => source
      )
      UsageReport.new(@transport.json(:get, "/usage#{query}", idempotent: true))
    end

    private

    def finish_run(job, destination:, download:)
      case job.state
      when "succeeded"
        wanted = download.nil? ? default_download?(job, destination) : download
        signed = job.download
        return RunResult.new(job: job) if !wanted || signed.nil?

        response = fetch_result(signed.url)
        RunResult.new(job: job, output: response.body, mime: response.content_type || "application/octet-stream",
                      downloaded: true)
      when "failed"
        raise Snapnedit::Error.new(
          job.message || "job #{job.id} failed",
          code: ErrorCodes.coerce(job.error_code),
          status: nil
        )
      else
        raise Snapnedit::Error.new("job #{job.id} was #{job.state}", code: ErrorCodes::INTERNAL)
      end
    end

    # Only an EXPLICIT destination suppresses the download; an account default
    # applied server-side does not.
    def default_download?(job, destination)
      asked_for_delivery = destination != DEFAULT_DESTINATION && !destination.nil?
      !(asked_for_delivery && job.delivery&.delivered?)
    end

    # A presigned download url is self-authenticating; the bearer token is
    # deliberately not sent with it.
    def fetch_result(url)
      @transport.raw(:get, url, headers: { "accept" => "*/*" }, idempotent: true, auth: false)
    end

    def mask_param_key(params)
      params.key?(:maskAssetId) || params.key?("maskAssetId") ? "maskAssetId" : :maskAssetId
    end

    def url_input?(value)
      value.is_a?(Hash) && (value.key?(:url) || value.key?("url"))
    end

    def job_input_field(input)
      case input
      when Upload then { "inputAssetId" => input.asset_id }
      when Hash
        url = input[:url] || input["url"]
        raise ArgumentError, "a Hash input must be { url: ... }" if url.nil?

        { "inputUrl" => url }
      when String then { "inputAssetId" => input }
      else
        raise ArgumentError, "input must be an asset id String, an Upload, or { url: ... } (got #{input.class})"
      end
    end

    def normalize_destination(destination)
      case destination
      when nil then nil
      when Destination then { "type" => "saved", "id" => destination.id }
      when String then { "type" => "saved", "id" => destination }
      when Hash then Util.camelize_keys(destination)
      else
        raise ArgumentError, "destination must be nil, a Hash, a Destination or an id String " \
                             "(got #{destination.class})"
      end
    end

    # @return [Array(String, String｜nil)] the bytes and, when there was one, a path.
    def read_input(input)
      case input
      when String then [File.binread(input), input]
      when StringIO then [input.string.b, nil]
      when IO then [read_io(input), (input.respond_to?(:path) ? input.path : nil)]
      else
        if input.respond_to?(:to_path) then [File.binread(input.to_path), input.to_path]
        elsif input.respond_to?(:read) then [read_io(input), (input.respond_to?(:path) ? input.path : nil)]
        else raise ArgumentError, "expected a path, an IO or a Hash { url: ... } (got #{input.class})"
        end
      end
    end

    def read_io(io)
      io.binmode if io.respond_to?(:binmode)
      io.read.b
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
