# frozen_string_literal: true

require "stringio"
require "tempfile"

RSpec.describe Snapnedit::Client do
  let(:http) { FakeHTTP.new }
  let(:client) do
    described_class.new(api_key: "sk_live_test", base_url: "https://api.example", http: http,
                        sleeper: ->(_seconds) {})
  end
  let(:png) { "\x89PNG\r\n\x1A\n#{"pixels" * 4}".b }
  let(:asset_id) { "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }
  let(:job_id) { "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" }

  def stub_upload(id: nil)
    id ||= asset_id
    http.stub(:post, %r{/uploads\z}, json: { assetId: id, upload: { url: "/_local/uploads/#{id}?sig=x",
                                                                    expiresAt: "2026-09-13T01:00:00.000Z" } })
    http.stub(:put, "/_local/uploads/", status: 204, body: "")
    http.stub(:post, "/confirm", json: { assetId: id, contentHash: "0" * 64, bytes: png.bytesize })
  end

  def succeeded_job(overrides = {})
    {
      "state" => "succeeded", "outputAssetId" => "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      "download" => { "url" => "/_local/results/abc.png?sig=y", "expiresAt" => "2026-09-13T01:00:00.000Z" },
      "input" => { "kind" => "asset" }, "destination" => nil, "delivery" => nil
    }.merge(overrides)
  end

  it "defaults to the hosted api" do
    expect(described_class::DEFAULT_BASE_URL).to eq("https://snapnedit.com/api")
  end

  describe "#list_operations" do
    it "returns the catalog without a credential" do
      http.stub(:get, "/operations", json: [{
                  id: "upscale", label: "Upscale Image", accept: ["image/png"], maxInputDimension: 4096,
                  paramsJsonSchema: { properties: { factor: { enum: %w[2 4], default: "2" } } },
                  requiresMask: false, description: "d", seoTitle: "s"
                }])

      operation = client.list_operations.first
      expect(operation.id).to eq("upscale")
      expect(operation.requires_mask?).to be(false)
      expect(operation.max_input_dimension).to eq(4096)
      expect(operation.params_json_schema.dig("properties", "factor", "enum")).to eq(%w[2 4])
      expect(operation.credit_cost).to eq(2)
      expect(http.requests.first.headers).not_to have_key("authorization")
    end
  end

  describe "#upload" do
    it "creates, PUTs and confirms, in that order" do
      stub_upload
      Tempfile.create(["cat", ".png"]) do |file|
        file.binmode
        file.write(png)
        file.flush

        upload = client.upload(file.path)
        expect(upload.asset_id).to eq(asset_id)
        expect(upload.content_hash).to match(/\A[0-9a-f]{64}\z/)
        expect(upload.bytes).to eq(png.bytesize)
      end

      expect(http.requests.map(&:verb)).to eq(%i[post put post])
      expect(http.requests[0].json).to eq("mime" => "image/png", "bytes" => png.bytesize)
    end

    it "does not send the bearer token with the presigned PUT" do
      stub_upload
      client.upload(StringIO.new(png))

      put = http.requests_for(:put).first
      expect(put.headers).not_to have_key("authorization")
      expect(put.headers["content-type"]).to eq("image/png")
      expect(put.body).to eq(png)
    end

    it "resolves the presigned path against the base url" do
      stub_upload
      client.upload(StringIO.new(png))
      expect(http.requests_for(:put).first.url).to eq("https://api.example/_local/uploads/#{asset_id}?sig=x")
    end

    it "sniffs the mime from the bytes when none is given" do
      stub_upload
      client.upload(StringIO.new("\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01".b))
      expect(http.requests.first.json["mime"]).to eq("image/jpeg")
    end

    it "lets an explicit mime win" do
      stub_upload
      client.upload(StringIO.new(png), mime: "image/webp")
      expect(http.requests.first.json["mime"]).to eq("image/webp")
    end

    it "raises unsupported_mime straight through" do
      http.stub(:post, %r{/uploads\z}, status: 400,
                                       json: { error: { code: "unsupported_mime", message: "pdf is not an image" } })

      expect { client.upload(StringIO.new("%PDF-1.7 and some more bytes".b)) }
        .to raise_error(Snapnedit::Error) { |e| expect(e.code).to eq("unsupported_mime") }
    end

    it "rejects an input it cannot read" do
      expect { client.upload(42) }.to raise_error(ArgumentError, /path, an IO/)
    end
  end

  describe "#create_job" do
    before do
      http.stub(:post, "/jobs", status: 202,
                                json: { jobId: job_id, status: { state: "queued" },
                                        input: { kind: "asset" }, destination: nil, delivery: nil })
    end

    it "sends inputAssetId for an asset id String" do
      job = client.create_job("remove-background", asset_id)
      expect(job.id).to eq(job_id)
      expect(job.state).to eq("queued")
      expect(job.http_status).to eq(202)
      expect(job.cache_hit?).to be(false)
      expect(http.requests.first.json).to eq(
        "operation" => "remove-background", "params" => {}, "inputAssetId" => asset_id
      )
    end

    it "accepts the Upload object an upload returned" do
      client.create_job("upscale", Snapnedit::Upload.new("assetId" => asset_id), params: { factor: "4" })
      expect(http.requests.first.json).to include("inputAssetId" => asset_id, "params" => { "factor" => "4" })
    end

    it "sends inputUrl for a { url: } input" do
      client.create_job("remove-background", { url: "https://cdn.example/cat.png" })
      expect(http.requests.first.json).to include("inputUrl" => "https://cdn.example/cat.png")
      expect(http.requests.first.json).not_to have_key("inputAssetId")
    end

    it "rejects a Hash input that is not { url: }" do
      expect { client.create_job("remove-background", { asset: "x" }) }
        .to raise_error(ArgumentError, /must be \{ url: /)
    end

    describe "destination" do
      it "sends NO destination field by default, so an account default can apply" do
        client.create_job("remove-background", asset_id)
        expect(http.requests.first.json).not_to have_key("destination")
      end

      it "sends an explicit null to opt out of the account default" do
        client.create_job("remove-background", asset_id, destination: nil)
        expect(http.requests.first.json).to include("destination" => nil)
      end

      it "camelizes a presigned-put destination" do
        client.create_job("remove-background", asset_id, destination: {
                            type: "presigned-put", url: "https://bucket.example/k.png",
                            headers: { "content-type" => "image/png" }
                          })
        expect(http.requests.first.json["destination"]).to eq(
          "type" => "presigned-put", "url" => "https://bucket.example/k.png",
          "headers" => { "content-type" => "image/png" }
        )
      end

      it "takes a saved destination id as a bare String" do
        client.create_job("remove-background", asset_id, destination: "dest-1")
        expect(http.requests.first.json["destination"]).to eq("type" => "saved", "id" => "dest-1")
      end

      it "takes a Destination object" do
        client.create_job("remove-background", asset_id, destination: Snapnedit::Destination.new("id" => "dest-2"))
        expect(http.requests.first.json["destination"]).to eq("type" => "saved", "id" => "dest-2")
      end

      it "rejects anything else" do
        expect { client.create_job("remove-background", asset_id, destination: 7) }
          .to raise_error(ArgumentError, /destination must be/)
      end
    end

    it "reports a cache hit — 200 rather than 202, already succeeded" do
      http_hit = FakeHTTP.new
      http_hit.stub(:post, "/jobs", status: 200, json: {
                      jobId: job_id, status: succeeded_job.slice("state", "outputAssetId", "download"),
                      input: { kind: "asset" }, destination: nil, delivery: nil
                    })
      hit = described_class.new(api_key: "k", base_url: "https://api.example", http: http_hit)
                           .create_job("remove-background", asset_id)

      expect(hit.cache_hit?).to be(true)
      expect(hit.succeeded?).to be(true)
      expect(hit.output_asset_id).to eq("cccccccc-cccc-4ccc-8ccc-cccccccccccc")
    end
  end

  describe "#get_job" do
    it "reads the FLATTENED shape GET /jobs/{id} uses" do
      http.stub(:get, "/jobs/", json: succeeded_job)

      job = client.get_job(job_id)
      expect(job.id).to eq(job_id)
      expect(job.state).to eq("succeeded")
      expect(job.succeeded?).to be(true)
      expect(job.terminal?).to be(true)
      expect(job.settled?).to be(true)
      expect(job.input_kind).to eq("asset")
      expect(job.download.url).to eq("/_local/results/abc.png?sig=y")
    end

    it "reports a failed job's error code without raising" do
      http.stub(:get, "/jobs/", json: { "state" => "failed", "errorCode" => "input_fetch_failed",
                                        "message" => "could not fetch", "input" => { "kind" => "url" },
                                        "destination" => nil, "delivery" => nil })

      job = client.get_job(job_id)
      expect(job.failed?).to be(true)
      expect(job.error_code).to eq("input_fetch_failed")
      expect(job.input_kind).to eq("url")
    end

    it "surfaces someone else's job as not_found" do
      http.stub(:get, "/jobs/", status: 404, json: { error: { code: "not_found", message: "no such job" } })
      expect { client.get_job(job_id) }
        .to raise_error(Snapnedit::Error) { |e| expect([e.code, e.status]).to eq(["not_found", 404]) }
    end
  end

  describe "#wait_for_job" do
    it "polls until terminal" do
      http.stub_sequence(:get, "/jobs/", [
                           { json: { "state" => "queued", "input" => { "kind" => "asset" },
                                     "destination" => nil, "delivery" => nil } },
                           { json: { "state" => "processing", "input" => { "kind" => "asset" },
                                     "destination" => nil, "delivery" => nil } },
                           { json: succeeded_job }
                         ])

      expect(client.wait_for_job(job_id, poll_interval: 0).state).to eq("succeeded")
      expect(http.requests_for(:get).size).to eq(3)
    end

    it "keeps polling a succeeded job whose delivery is still pending (a cache hit with a destination)" do
      http.stub_sequence(:get, "/jobs/", [
                           { json: succeeded_job("destination" => { "type" => "saved", "id" => "d1" },
                                                 "delivery" => { "status" => "pending", "attempts" => 0 }) },
                           { json: succeeded_job("destination" => { "type" => "saved", "id" => "d1" },
                                                 "delivery" => { "status" => "delivered", "attempts" => 1 }) }
                         ])

      job = client.wait_for_job(job_id, poll_interval: 0)
      expect(job.delivery.delivered?).to be(true)
      expect(http.requests_for(:get).size).to eq(2)
    end

    it "stops on a delivery that FAILED — a failed delivery does not fail the job" do
      http.stub(:get, "/jobs/", json: succeeded_job("destination" => { "type" => "presigned-put" },
                                                    "delivery" => { "status" => "failed", "attempts" => 3,
                                                                    "error" => "403" }))

      job = client.wait_for_job(job_id, poll_interval: 0)
      expect(job.succeeded?).to be(true)
      expect(job.delivery.failed?).to be(true)
      expect(job.download).not_to be_nil
    end

    it "raises TimeoutError when the budget runs out" do
      http.stub(:get, "/jobs/", json: { "state" => "processing", "input" => { "kind" => "asset" },
                                        "destination" => nil, "delivery" => nil })

      expect { client.wait_for_job(job_id, poll_interval: 0, timeout: 0) }
        .to raise_error(Snapnedit::TimeoutError, /exceeded timeout/)
    end
  end

  describe "#run" do
    before do
      stub_upload
      http.stub(:get, "/_local/results/abc.png", body: "RESULTBYTES".b, headers: { "content-type" => "image/png" })
    end

    it "uploads, creates, polls and downloads" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "asset" }, destination: nil, delivery: nil })
      http.stub(:get, "/jobs/", json: succeeded_job)

      result = client.run("remove-background", StringIO.new(png), poll_interval: 0)
      expect(result).to be_downloaded
      expect(result.output).to eq("RESULTBYTES".b)
      expect(result.mime).to eq("image/png")
      expect(result.job_id).to eq(job_id)
      expect(result.input_kind).to eq("asset")
    end

    it "skips the upload for a { url: } input" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "url" }, destination: nil, delivery: nil })
      http.stub(:get, "/jobs/", json: succeeded_job("input" => { "kind" => "url" }))

      result = client.run("remove-background", { url: "https://cdn.example/cat.png" }, poll_interval: 0)
      expect(http.requests_for(:post, %r{/uploads\z})).to be_empty
      expect(result.input_kind).to eq("url")
    end

    it "uploads a mask and sets params[:maskAssetId]" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "asset" }, destination: nil, delivery: nil })
      http.stub(:get, "/jobs/", json: succeeded_job)

      client.run("magic-eraser", StringIO.new(png), mask: StringIO.new(png), poll_interval: 0)

      expect(http.requests_for(:post, %r{/uploads\z}).size).to eq(2)
      expect(http.requests_for(:post, "/jobs").first.json["params"]).to eq("maskAssetId" => asset_id)
    end

    it "does NOT download when an explicit destination delivered — the bytes are in your bucket" do
      delivered = succeeded_job("destination" => { "type" => "presigned-put" },
                                "delivery" => { "status" => "delivered", "attempts" => 1,
                                                "deliveredAt" => "2026-09-13T00:00:01.000Z" })
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "asset" },
                                                     destination: { type: "presigned-put" }, delivery: nil })
      http.stub(:get, "/jobs/", json: delivered)

      destination = { type: "presigned-put", url: "https://b.example/k" }
      result = client.run("remove-background", StringIO.new(png), poll_interval: 0, destination: destination)

      expect(result).not_to be_downloaded
      expect(result.output).to be_nil
      expect(result.delivery.delivered?).to be(true)
      expect(result.download).not_to be_nil
      expect(http.requests_for(:get, "/_local/results/")).to be_empty
    end

    it "still downloads when the delivery FAILED, so a caller is never left empty-handed" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "asset" },
                                                     destination: { type: "presigned-put" }, delivery: nil })
      http.stub(:get, "/jobs/", json: succeeded_job("destination" => { "type" => "presigned-put" },
                                                    "delivery" => { "status" => "failed", "attempts" => 3 }))

      destination = { type: "presigned-put", url: "https://b.example/k" }
      result = client.run("remove-background", StringIO.new(png), poll_interval: 0, destination: destination)
      expect(result).to be_downloaded
    end

    it "still downloads when an ACCOUNT DEFAULT delivered — only an explicit destination flips the default" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "asset" },
                                                     destination: { type: "saved", id: "d1" }, delivery: nil })
      http.stub(:get, "/jobs/", json: succeeded_job("destination" => { "type" => "saved", "id" => "d1" },
                                                    "delivery" => { "status" => "delivered", "attempts" => 1 }))

      result = client.run("remove-background", StringIO.new(png), poll_interval: 0)
      expect(result).to be_downloaded
    end

    it "honours download: false" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "asset" }, destination: nil, delivery: nil })
      http.stub(:get, "/jobs/", json: succeeded_job)

      result = client.run("remove-background", StringIO.new(png), poll_interval: 0, download: false)
      expect(result).not_to be_downloaded
      expect(result.download.url).to eq("/_local/results/abc.png?sig=y")
    end

    it "honours download: true even when a destination delivered" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "asset" },
                                                     destination: { type: "saved", id: "d1" }, delivery: nil })
      http.stub(:get, "/jobs/", json: succeeded_job("destination" => { "type" => "saved", "id" => "d1" },
                                                    "delivery" => { "status" => "delivered", "attempts" => 1 }))

      result = client.run("remove-background", StringIO.new(png), poll_interval: 0,
                                                                  destination: "d1", download: true)
      expect(result).to be_downloaded
    end

    it "reports downloaded: false rather than raising when delete_after_delivery removed our copy" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "asset" },
                                                     destination: { type: "saved", id: "d1" }, delivery: nil })
      http.stub(:get, "/jobs/", json: succeeded_job(
        "download" => nil,
        "destination" => { "type" => "saved", "id" => "d1" },
        "delivery" => { "status" => "delivered", "attempts" => 1, "bucket" => "b",
                        "key" => "k.png", "localCopyDeleted" => true }
      ))

      result = client.run("remove-background", StringIO.new(png), poll_interval: 0,
                                                                  destination: "d1", download: true)
      expect(result).not_to be_downloaded
      expect(result.download).to be_nil
      expect(result.delivery.local_copy_deleted?).to be(true)
      expect(result.delivery.key).to eq("k.png")
    end

    it "short-circuits a settled cache hit without polling at all" do
      http.stub(:post, "/jobs", status: 200, json: {
                  jobId: job_id, status: succeeded_job.slice("state", "outputAssetId", "download"),
                  input: { kind: "asset" }, destination: nil, delivery: nil
                })

      result = client.run("remove-background", StringIO.new(png), poll_interval: 0)
      expect(result).to be_downloaded
      expect(http.requests_for(:get, "/jobs/")).to be_empty
    end

    it "raises the job's own error code when the job fails" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "url" }, destination: nil, delivery: nil })
      http.stub(:get, "/jobs/", json: { "state" => "failed", "errorCode" => "input_fetch_failed",
                                        "message" => "could not fetch the input url",
                                        "input" => { "kind" => "url" }, "destination" => nil, "delivery" => nil })

      expect { client.run("remove-background", { url: "https://cdn.example/missing.png" }, poll_interval: 0) }
        .to raise_error(Snapnedit::Error) { |e|
          expect(e.code).to eq("input_fetch_failed")
          expect(e.message).to eq("could not fetch the input url")
        }
    end

    it "writes the bytes to a path" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "asset" }, destination: nil, delivery: nil })
      http.stub(:get, "/jobs/", json: succeeded_job)

      result = client.run("remove-background", StringIO.new(png), poll_interval: 0)
      Tempfile.create(["out", ".png"]) do |file|
        result.write(file.path)
        expect(File.binread(file.path)).to eq("RESULTBYTES".b)
      end
    end

    it "refuses to write a result it never downloaded" do
      http.stub(:post, "/jobs", status: 202, json: { jobId: job_id, status: { state: "queued" },
                                                     input: { kind: "asset" }, destination: nil, delivery: nil })
      http.stub(:get, "/jobs/", json: succeeded_job)

      result = client.run("remove-background", StringIO.new(png), poll_interval: 0, download: false)
      expect { result.write("/tmp/never-written.png") }.to raise_error(Snapnedit::Error, /no bytes/)
    end
  end

  describe "#download_result" do
    it "downloads from a Job" do
      http.stub(:get, "/_local/results/abc.png", body: "BYTES".b, headers: { "content-type" => "image/png" })
      job = Snapnedit::Job.new(succeeded_job, job_id: job_id)
      expect(client.download_result(job)).to eq("BYTES".b)
    end

    it "does not send the bearer token with a presigned download" do
      http.stub(:get, "/_local/results/abc.png", body: "BYTES".b)
      client.download_result(Snapnedit::Job.new(succeeded_job, job_id: job_id))
      expect(http.requests_for(:get).first.headers).not_to have_key("authorization")
    end

    it "raises not_found when there is no copy left to download" do
      job = Snapnedit::Job.new(succeeded_job("download" => nil), job_id: job_id)
      expect { client.download_result(job) }
        .to raise_error(Snapnedit::Error) { |e| expect(e.code).to eq("not_found") }
    end
  end

  it "can be built with no api key at all, for the public endpoints" do
    anon_http = FakeHTTP.new.stub(:get, "/operations", json: [])
    described_class.new(base_url: "https://api.example", http: anon_http).list_operations
    expect(anon_http.requests.first.headers).not_to have_key("authorization")
  end
end
