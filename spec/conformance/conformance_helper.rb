# frozen_string_literal: true

require "json"
require "securerandom"
require "stringio"
require "time"
require "timeout"

# Harness for the language-neutral SDK conformance suite.
#
# `node scripts/conformance-server.mjs`, run from the snapnedit monorepo root,
# boots the REAL Fastify api and the REAL worker in one process over an
# in-memory store, a temp storage directory and the stub model provider. It
# prints exactly one line of JSON on stdout the moment it is accepting
# connections and serves until SIGTERM.
#
# See docs/sdk-conformance.md.
module Conformance
  # Seconds to wait for the server's ready line.
  BOOT_TIMEOUT = 120

  class << self
    # @return [Hash] the parsed ready line: url, apiKey, publishableKey,
    #   webhookSecret, accountId, bucket, startingCredits.
    attr_reader :config
    # @return [String] the monorepo root the server was started from.
    attr_reader :root

    # Spawns the server and blocks until it is ready.
    # @param root [String] the snapnedit monorepo root.
    def start!(root)
      @root = root
      reader, writer = IO.pipe
      @pid = Process.spawn(
        { "CONFORMANCE_PORT" => "0" },
        "node", "scripts/conformance-server.mjs",
        chdir: root, out: writer,
        err: ENV["SNAPNEDIT_CONFORMANCE_DEBUG"] ? :err : File::NULL
      )
      writer.close
      @stdout = reader
      line = Timeout.timeout(BOOT_TIMEOUT) { reader.gets }
      raise "the conformance server exited before printing its ready line" if line.nil?

      @config = JSON.parse(line)
      @adapter = Snapnedit::HTTP::Adapter.new(open_timeout: 5, read_timeout: 60)
    end

    # SIGTERM, reap, close the pipe.
    def stop!
      return if @pid.nil?

      Process.kill("TERM", @pid)
      Process.wait(@pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      @stdout&.close unless @stdout&.closed?
      @pid = nil
    end

    # @return [String] the server's base url.
    def url = @config["url"]

    # @return [String] the seeded account's secret `sk_live_` key.
    def api_key = @config["apiKey"]

    # @return [String] a `pk_live_` key on the same account.
    def publishable_key = @config["publishableKey"]

    # @return [String] the account both keys belong to.
    def account_id = @config["accountId"]

    # @return [String] the stand-in customer bucket's name.
    def bucket = @config["bucket"]

    # A client authenticated as the seeded account.
    # @return [Snapnedit::Client]
    def api
      @api ||= Snapnedit::Client.new(api_key: api_key, base_url: url)
    end

    # A client with no credential at all.
    # @return [Snapnedit::Client]
    def anon
      @anon ||= Snapnedit::Client.new(base_url: url)
    end

    # A client holding an arbitrary bearer token.
    # @param token [String, nil]
    # @return [Snapnedit::Client]
    def client_with(token)
      Snapnedit::Client.new(api_key: token, base_url: url)
    end

    # One raw HTTP request, bypassing the SDK entirely — for the scenarios
    # that assert on exact status codes, exact envelope keys or exact bytes.
    #
    # @param method [Symbol]
    # @param path [String] path or absolute url.
    # @param body [Object, nil] serialized as JSON when given.
    # @param token [String, nil] bearer token; nil sends no credential.
    # @param headers [Hash]
    # @param raw_body [String, nil] send these bytes verbatim instead of JSON.
    # @return [Snapnedit::HTTP::Response]
    def raw(method, path, body: nil, token: nil, headers: {}, raw_body: nil)
      request_headers = { "accept" => "*/*" }.merge(headers)
      request_headers["authorization"] = "Bearer #{token}" if token
      payload = raw_body
      if payload.nil? && !body.nil?
        request_headers["content-type"] = "application/json"
        payload = JSON.generate(body)
      end

      @adapter.call(
        method: method, url: Snapnedit::Util.resolve(url, path),
        headers: request_headers, body: payload
      )
    end

    # A unique, stable-ish label so two scenarios never collide.
    # @param label [String]
    # @return [String]
    def nonce(label)
      "#{label}-#{SecureRandom.hex(6)}"
    end

    # Real image bytes from the helper endpoint. `?nonce=` appends a comment
    # trailer after the image data, so the picture is identical and the
    # content hash is not — which is how a scenario avoids the result cache.
    #
    # @param name [String] `"small.png"` or `"small.jpg"`.
    # @param nonce_value [String, nil]
    # @return [String] the bytes.
    def fixture(name, nonce_value = nil)
      query = nonce_value ? "?nonce=#{nonce_value}" : ""
      response = raw(:get, "/__conformance/fixtures/#{name}#{query}")
      raise "fixture #{name} came back #{response.status}" unless response.success?

      response.body
    end

    # Uploads bytes nobody has submitted before, so the job cannot be a cache
    # hit.
    # @param label [String]
    # @return [Snapnedit::Upload]
    def unique_upload(label)
      api.upload(StringIO.new(fixture("small.png", nonce(label))), mime: "image/png")
    end

    # The seeded account's live credit balance. Assert on DELTAS: scenarios
    # share one account and run in any order.
    # @return [Integer]
    def balance
      JSON.parse(raw(:get, "/__conformance/credits").body)["balance"]
    end

    # Reads one object back out of the stand-in customer bucket.
    # @param key [String]
    # @return [Hash, nil] `{ key, bytes, contentType, headers, sha256, base64, receivedAt }`.
    def bucket_object(key)
      response = raw(:get, "/__conformance/bucket/#{key}")
      response.success? ? JSON.parse(response.body) : nil
    end

    # Creates a saved destination pointed at the server's own path-style S3
    # door, so the worker signs an ordinary SigV4 PUT against it.
    #
    # @param overrides [Hash] merged over the defaults.
    # @return [Snapnedit::Destination]
    def create_destination(**overrides)
      api.destinations.create(
        name: "conformance #{nonce("dest")}",
        provider: "s3-compatible",
        bucket: bucket,
        region: "auto",
        endpoint: url,
        force_path_style: true,
        key_prefix: "conformance/",
        access_key_id: "CONFORMANCEKEYID",
        secret_access_key: "conformance-secret-access-key", **overrides
      )
    end

    # @return [Hash] the parsed `test/conformance/scenarios.json`.
    def scenarios_doc
      @scenarios_doc ||= JSON.parse(File.read(File.join(root, "test/conformance/scenarios.json")))
    end
  end

  # Records which scenario ids the suite implements, so the last example can
  # fail when `scenarios.json` grows one this gem has not caught up with.
  # Appended to as the spec file defines its groups, so deliberately mutable.
  IMPLEMENTED = [] # rubocop:disable Style/MutableConstant
end
