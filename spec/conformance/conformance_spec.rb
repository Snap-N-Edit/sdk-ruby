# frozen_string_literal: true

require_relative "conformance_helper"

# THE 24 SCENARIOS OF `test/conformance/scenarios.json`, one `describe` per id.
#
# The server is the real Fastify api and the real worker, over a real socket —
# see docs/sdk-conformance.md. Run with:
#
#   bundle exec rspec --tag conformance
#
# The final example fails if `scenarios.json` contains an id this file does
# not implement, so a new scenario upstream shows up here as a red test rather
# than as silence.
RSpec.describe "snapnedit SDK conformance", :conformance,
               skip: (RSpec.configuration.monorepo_root ? false : "requires a snapnedit monorepo checkout") do
  def self.scenario(id, &block)
    Conformance::IMPLEMENTED << id
    describe(id, &block)
  end

  before(:all) { Conformance.start!(RSpec.configuration.monorepo_root) }
  after(:all) { Conformance.stop! }

  let(:api) { Conformance.api }
  let(:anon) { Conformance.anon }

  # ---------------------------------------------------------------- auth ---

  scenario "auth.missing-credential" do
    it "is 401 unauthorized with the standard envelope" do
      expect { anon.destinations.list }.to raise_error(Snapnedit::Error) { |e|
        expect(e.status).to eq(401)
        expect(e.code).to eq(Snapnedit::ErrorCodes::UNAUTHORIZED)
      }

      response = Conformance.raw(:get, "/destinations")
      expect(response.status).to eq(401)
      body = JSON.parse(response.body)
      expect(body.keys).to eq(["error"])
      expect(body["error"]["code"]).to eq("unauthorized")
      expect(body["error"]["message"]).not_to be_empty
    end
  end

  scenario "auth.bad-key" do
    it "is 401, not 403, and reveals nothing about any account" do
      client = Conformance.client_with("sk_live_this_key_does_not_exist")
      expect { client.destinations.list }.to raise_error(Snapnedit::Error) { |e|
        expect(e.status).to eq(401)
        expect(e.code).to eq("unauthorized")
      }

      body = Conformance.raw(:get, "/destinations", token: "sk_live_this_key_does_not_exist").body
      expect(body).not_to include(Conformance.account_id)
    end
  end

  scenario "auth.publishable-key-is-not-a-bearer" do
    it "resolves a pk_ key presented as a bearer to anonymous" do
      client = Conformance.client_with(Conformance.publishable_key)
      expect { client.destinations.list }.to raise_error(Snapnedit::Error) { |e|
        expect(e.status).to eq(401)
        expect(e.code).to eq("unauthorized")
      }
    end
  end

  # ---------------------------------------------------------- operations ---

  scenario "operations.list" do
    it "returns all 17 operations with their params contracts" do
      operations = anon.list_operations
      expect(operations.size).to eq(17)
      expect(operations.map(&:id)).to eq(Snapnedit::Operations::ALL)

      operations.each do |operation|
        expect(operation.label).to be_a(String)
        expect(operation.accept).not_to be_empty
        expect(operation.max_input_dimension).to be > 0
        expect(operation.params_json_schema).to be_a(Hash)
        expect(operation.description).to be_a(String)
        expect(operation.seo_title).to be_a(String)
      end

      expect(operations.select(&:requires_mask?).map(&:id))
        .to match_array(Snapnedit::Operations::REQUIRES_MASK)

      factor = operations.find { |o| o.id == "upscale" }.params_json_schema.dig("properties", "factor")
      expect(factor["enum"]).to eq(%w[2 4])
      expect(factor["default"]).to eq("2")
    end

    it "publishes credit costs on the OpenAPI document, and this gem agrees" do
      spec = JSON.parse(Conformance.raw(:get, "/openapi.json").body)
      costs = spec.dig("paths", "/operations", "get", "x-credit-cost")
      expect(costs["resize-image"]).to eq(0)
      expect(costs["remove-background"]).to eq(1)
      expect(costs["upscale"]).to eq(2)
      expect(spec.dig("components", "schemas", "OperationParams.resize-image", "x-credit-cost")).to eq(0)
      expect(Snapnedit::Operations::CREDIT_COSTS).to eq(costs)
    end
  end

  # ------------------------------------------------------- the core flow ---

  scenario "jobs.happy-path" do
    it "uploads, confirms, creates, polls and downloads" do
      bytes = Conformance.fixture("small.png", Conformance.nonce("happy"))

      created = Conformance.raw(:post, "/uploads", body: { mime: "image/png", bytes: bytes.bytesize },
                                                   token: Conformance.api_key)
      expect(created.status).to eq(200)
      upload = JSON.parse(created.body)
      expect(upload["assetId"]).to be_a(String)
      expect(upload.dig("upload", "url")).to be_a(String)

      put = Conformance.raw(:put, upload.dig("upload", "url"), raw_body: bytes,
                                                               headers: { "content-type" => "image/png" })
      expect(put.status).to eq(204)

      confirmed = Conformance.raw(:post, "/uploads/#{upload["assetId"]}/confirm", token: Conformance.api_key)
      expect(confirmed.status).to eq(200)
      confirm = JSON.parse(confirmed.body)
      expect(confirm["assetId"]).to eq(upload["assetId"])
      expect(confirm["contentHash"]).to match(/\A[0-9a-f]{64}\z/)
      expect(confirm["bytes"]).to eq(bytes.bytesize)

      job = api.create_job(Snapnedit::Operations::REMOVE_BACKGROUND, upload["assetId"])
      expect(job.http_status).to eq(202)
      expect(job.state).to eq("queued")
      expect(job.input_kind).to eq("asset")
      expect(job.destination).to be_nil
      expect(job.delivery).to be_nil

      done = api.wait_for_job(job.id, poll_interval: 0.05)
      expect(done.state).to eq("succeeded")
      expect(done.output_asset_id).to be_a(String)
      expect(done.download).not_to be_nil

      downloaded = Conformance.raw(:get, done.download.url)
      expect(downloaded.status).to eq(200)
      expect(downloaded.body).not_to be_empty
      expect(downloaded.content_type).to include("image/png")
    end

    it "does the whole thing in one call with #run" do
      bytes = Conformance.fixture("small.png", Conformance.nonce("happy-run"))
      result = api.run(Snapnedit::Operations::REMOVE_BACKGROUND, StringIO.new(bytes),
                       mime: "image/png", poll_interval: 0.05)

      expect(result).to be_downloaded
      expect(result.output).not_to be_empty
      expect(result.mime).to include("image/png")
      expect(result.input_kind).to eq("asset")
    end
  end

  scenario "jobs.params-validation" do
    it "rejects a factor outside the operation's own enum and accepts one inside it" do
      asset = Conformance.unique_upload("params")

      expect { api.create_job("upscale", asset.asset_id, params: { factor: "3" }) }
        .to raise_error(Snapnedit::Error) { |e|
          expect(e.status).to eq(400)
          expect(e.code).to eq(Snapnedit::ErrorCodes::INVALID_INPUT)
        }

      accepted = api.create_job("upscale", asset.asset_id, params: { factor: "4" })
      expect(accepted.http_status).to eq(202)
    end
  end

  scenario "jobs.unknown-param-rejected" do
    it "rejects an unrecognized param key rather than ignoring it" do
      asset = Conformance.unique_upload("strict-params")

      expect { api.create_job("upscale", asset.asset_id, params: { factor: "2", nope: "x" }) }
        .to raise_error(Snapnedit::Error) { |e|
          expect(e.status).to eq(400)
          expect(e.code).to eq("invalid_input")
        }
    end
  end

  # ------------------------------------------------------------- credits ---

  scenario "jobs.free-operation" do
    it "debits nothing for resize-image" do
      before_balance = Conformance.balance
      asset = Conformance.unique_upload("free-op")

      job = api.create_job(Snapnedit::Operations::RESIZE_IMAGE, asset.asset_id, params: { width: 4 })
      expect(job.http_status).to eq(202)
      expect(api.wait_for_job(job.id, poll_interval: 0.05).state).to eq("succeeded")

      expect(Conformance.balance).to eq(before_balance)
      expect(Snapnedit::Operations.credit_cost("resize-image")).to eq(0)
    end
  end

  scenario "jobs.credit-debit" do
    it "debits exactly the operation's cost, at creation time" do
      before_balance = Conformance.balance
      asset = Conformance.unique_upload("debit")

      job = api.create_job(Snapnedit::Operations::REMOVE_BACKGROUND, asset.asset_id)
      expect(job.http_status).to eq(202)
      # The debit lands before the worker ever sees the job.
      expect(Conformance.balance).to eq(before_balance - 1)

      expect(api.wait_for_job(job.id, poll_interval: 0.05).state).to eq("succeeded")
      expect(Conformance.balance).to eq(before_balance - 1)
    end
  end

  scenario "jobs.cache-hit" do
    it "is 200 rather than 202, already succeeded, and free" do
      asset = Conformance.unique_upload("cache")
      first = api.create_job(Snapnedit::Operations::REMOVE_BACKGROUND, asset.asset_id)
      done = api.wait_for_job(first.id, poll_interval: 0.05)
      expect(done.state).to eq("succeeded")

      before_balance = Conformance.balance
      second = api.create_job(Snapnedit::Operations::REMOVE_BACKGROUND, asset.asset_id)

      expect(second.http_status).to eq(200)
      expect(second).to be_cache_hit
      expect(second.state).to eq("succeeded")
      expect(second.output_asset_id).to eq(done.output_asset_id)
      expect(Conformance.balance).to eq(before_balance)
    end
  end

  # --------------------------------------------- bring your own storage ---

  scenario "jobs.url-input" do
    it "fetches the input from a url, never echoes it, and refuses anonymous callers" do
      url = "#{Conformance.url}/__conformance/fixtures/small.png?nonce=#{Conformance.nonce("url-input")}"

      expect { anon.create_job(Snapnedit::Operations::REMOVE_BACKGROUND, { url: url }) }
        .to raise_error(Snapnedit::Error) { |e|
          expect(e.status).to eq(403)
          expect(e.code).to eq(Snapnedit::ErrorCodes::FORBIDDEN)
        }

      job = api.create_job(Snapnedit::Operations::REMOVE_BACKGROUND, { url: url })
      expect(job.http_status).to eq(202)
      expect(job.input_kind).to eq("url")
      expect(JSON.generate(job.to_h)).not_to include("nonce=")

      done = api.wait_for_job(job.id, poll_interval: 0.05)
      expect(done.state).to eq("succeeded")
      expect(done.input_kind).to eq("url")
      expect(api.download_result(done)).not_to be_empty
    end
  end

  scenario "jobs.url-input-fetch-failed" do
    it "fails terminally with input_fetch_failed and refunds the credits" do
      before_balance = Conformance.balance

      job = api.create_job(
        Snapnedit::Operations::REMOVE_BACKGROUND,
        { url: "#{Conformance.url}/__conformance/fixtures/does-not-exist.png" }
      )
      expect(job.http_status).to eq(202)

      done = api.wait_for_job(job.id, poll_interval: 0.05)
      expect(done.state).to eq("failed")
      expect(done.error_code).to eq(Snapnedit::ErrorCodes::INPUT_FETCH_FAILED)
      expect(Conformance.balance).to eq(before_balance)
    end

    it "surfaces the same failure as a typed error from #run" do
      expect do
        api.run(Snapnedit::Operations::REMOVE_BACKGROUND,
                { url: "#{Conformance.url}/__conformance/fixtures/nope.png" }, poll_interval: 0.05)
      end.to raise_error(Snapnedit::Error) { |e| expect(e.code).to eq("input_fetch_failed") }
    end
  end

  scenario "jobs.presigned-destination" do
    it "PUTs the result to a url you signed, and never echoes that url" do
      key = "presigned/#{Conformance.nonce("put")}.png"
      asset = Conformance.unique_upload("presigned-dest")

      job = api.create_job(
        Snapnedit::Operations::REMOVE_BACKGROUND, asset.asset_id,
        destination: { type: "presigned-put",
                       url: "#{Conformance.url}/__conformance/bucket/#{key}",
                       headers: { "content-type" => "image/png" } }
      )
      expect(job.http_status).to eq(202)
      expect(job.destination.type).to eq("presigned-put")
      expect(job.destination.to_h).to eq("type" => "presigned-put")
      expect(JSON.generate(job.to_h)).not_to include("__conformance/bucket")

      done = api.wait_for_job(job.id, poll_interval: 0.05)
      expect(done.state).to eq("succeeded")
      expect(done.destination.presigned_put?).to be(true)
      expect(done.delivery.delivered?).to be(true)
      expect(done.delivery.attempts).to be >= 1
      expect(done.delivery.delivered_at).to be_a(String)
      # A presigned-put delivery never removes our copy.
      expect(done.download).not_to be_nil

      object = Conformance.bucket_object(key)
      expect(object).not_to be_nil
      expect(object["bytes"]).to be > 0
      expect(object["contentType"]).to eq("image/png")
    end
  end

  # ------------------------------------------------ saved destinations ---

  scenario "destinations.crud" do
    it "creates, lists, patches, tests and deletes" do
      destination = Conformance.create_destination(key_prefix: "crud/", access_key_id: "CONFORMANCEKEYID")

      expect(destination.id).to be_a(String)
      expect(destination.provider).to eq("s3-compatible")
      expect(destination.bucket).to eq(Conformance.bucket)
      expect(destination.key_prefix).to eq("crud/")
      expect(destination.access_key_id_last4).to eq("EYID")
      expect(destination.default?).to be(false)
      expect(destination.delete_after_delivery?).to be(false)
      expect(destination.created_at).to be_a(String)
      expect(destination.updated_at).to be_a(String)

      listed = Conformance.raw(:get, "/destinations", token: Conformance.api_key)
      expect(listed.status).to eq(200)
      expect(listed.body).not_to include("conformance-secret-access-key")
      expect(api.destinations.list.map(&:id)).to include(destination.id)

      patched = api.destinations.update(destination.id, name: "renamed by conformance")
      expect(patched.name).to eq("renamed by conformance")

      probe = api.destinations.test(destination.id)
      expect(probe.ok?).to be(true)
      expect(probe.latency_ms).to be_a(Integer)

      deleted = Conformance.raw(:delete, "/destinations/#{destination.id}", token: Conformance.api_key)
      expect(deleted.status).to eq(204)
      expect(deleted.body).to be_empty

      expect { api.destinations.update(destination.id, name: "nope") }
        .to raise_error(Snapnedit::Error) { |e|
          expect(e.status).to eq(404)
          expect(e.code).to eq(Snapnedit::ErrorCodes::NOT_FOUND)
        }
    end

    it "treats another account's destination id as 404, never 403" do
      expect { api.destinations.update("00000000-0000-4000-8000-000000000000", name: "x") }
        .to raise_error(Snapnedit::Error) { |e| expect([e.status, e.code]).to eq([404, "not_found"]) }
    end
  end

  scenario "destinations.presign" do
    it "mints a one-shot signed PUT and refuses a mismatched ext/contentType pair" do
      destination = Conformance.create_destination(key_prefix: "exports/")

      expect { api.destinations.presign_upload(destination.id, ext: "png", content_type: "image/jpeg") }
        .to raise_error(Snapnedit::Error) { |e|
          expect(e.status).to eq(400)
          expect(e.code).to eq("invalid_input")
        }

      signed = api.destinations.presign_upload(destination.id, ext: "png", content_type: "image/png")
      expect(signed.method).to eq("PUT")
      expect(signed.bucket).to eq(Conformance.bucket)
      expect(signed.key).to match(%r{\Aexports/\d{4}/\d{2}/\d{2}/export-\d+-[a-z0-9]{6}\.png\z})
      expect(signed.headers["content-type"]).to eq("image/png")
      expect(Time.parse(signed.expires_at)).to be > Time.now

      payload = "conformance export bytes"
      put = Conformance.raw(:put, signed.url, raw_body: payload, headers: signed.headers)
      expect(put.status).to eq(200)
      expect(Conformance.bucket_object(signed.key)["bytes"]).to eq(payload.bytesize)

      api.destinations.delete(destination.id)
    end
  end

  scenario "jobs.saved-destination" do
    it "delivers to a saved destination the worker signs itself" do
      destination = Conformance.create_destination(key_prefix: "saved/")

      expect do
        api.create_job(Snapnedit::Operations::REMOVE_BACKGROUND,
                       Conformance.unique_upload("saved-foreign").asset_id,
                       destination: { type: "saved", id: "00000000-0000-4000-8000-000000000000" })
      end.to raise_error(Snapnedit::Error) { |e| expect([e.status, e.code]).to eq([404, "not_found"]) }

      asset = Conformance.unique_upload("saved-dest")
      job = api.create_job(Snapnedit::Operations::REMOVE_BACKGROUND, asset.asset_id, destination: destination)
      expect(job.http_status).to eq(202)

      done = api.wait_for_job(job.id, poll_interval: 0.05)
      expect(done.state).to eq("succeeded")
      expect(done.destination.saved?).to be(true)
      expect(done.destination.id).to eq(destination.id)
      expect(done.destination.name).to be_a(String)
      expect(done.delivery.delivered?).to be(true)
      expect(done.delivery.bucket).to eq(Conformance.bucket)
      expect(done.delivery.key).to match(%r{\Asaved/\d{4}/\d{2}/\d{2}/#{Regexp.escape(job.id)}\.png\z})

      expect(Conformance.bucket_object(done.delivery.key)["bytes"]).to be > 0

      api.destinations.delete(destination.id)
    end

    it "skips the download by default when an explicit destination delivered" do
      destination = Conformance.create_destination(key_prefix: "saved-run/")
      bytes = Conformance.fixture("small.png", Conformance.nonce("saved-run"))

      result = api.run(Snapnedit::Operations::REMOVE_BACKGROUND, StringIO.new(bytes),
                       mime: "image/png", destination: destination, poll_interval: 0.05)

      expect(result).not_to be_downloaded
      expect(result.output).to be_nil
      expect(result.delivery.delivered?).to be(true)
      expect(Conformance.bucket_object(result.delivery.key)["bytes"]).to be > 0

      api.destinations.delete(destination.id)
    end
  end

  scenario "jobs.default-destination-and-opt-out" do
    it "applies the account default when no destination is named, and honours an explicit nil" do
      destination = Conformance.create_destination(key_prefix: "default/", is_default: true)
      expect(destination.default?).to be(true)

      inherited = api.create_job(Snapnedit::Operations::REMOVE_BACKGROUND,
                                 Conformance.unique_upload("default-on").asset_id)
      expect(inherited.http_status).to eq(202)
      inherited_done = api.wait_for_job(inherited.id, poll_interval: 0.05)
      expect(inherited_done.destination.saved?).to be(true)
      expect(inherited_done.destination.id).to eq(destination.id)
      expect(inherited_done.delivery.delivered?).to be(true)
      expect(inherited_done.delivery.key).to start_with("default/")

      opted_out = api.create_job(Snapnedit::Operations::REMOVE_BACKGROUND,
                                 Conformance.unique_upload("default-off").asset_id, destination: nil)
      expect(opted_out.destination).to be_nil
      opted_out_done = api.wait_for_job(opted_out.id, poll_interval: 0.05)
      expect(opted_out_done.destination).to be_nil
      expect(opted_out_done.delivery).to be_nil

      api.destinations.delete(destination.id)
    end
  end

  # --------------------------------------------- masks, errors, ownership ---

  scenario "jobs.mask-required" do
    it "demands params.maskAssetId and names it in the message" do
      asset = Conformance.unique_upload("mask-missing")

      expect { api.create_job(Snapnedit::Operations::MAGIC_ERASER, asset.asset_id) }
        .to raise_error(Snapnedit::Error) { |e|
          expect(e.status).to eq(400)
          expect(e.code).to eq("invalid_input")
          expect(e.message).to include("maskAssetId")
        }

      expect(anon.list_operations.find { |o| o.id == "magic-eraser" }.requires_mask?).to be(true)

      mask = Conformance.unique_upload("mask-bytes")
      accepted = api.create_job(Snapnedit::Operations::MAGIC_ERASER, asset.asset_id,
                                params: { maskAssetId: mask.asset_id })
      expect(accepted.http_status).to eq(202)
    end

    it "uploads the mask for you when #run is given one" do
      bytes = Conformance.fixture("small.png", Conformance.nonce("mask-run"))
      mask = Conformance.fixture("small.png", Conformance.nonce("mask-run-mask"))

      result = api.run(Snapnedit::Operations::MAGIC_ERASER, StringIO.new(bytes),
                       mask: StringIO.new(mask), mime: "image/png", poll_interval: 0.05)
      expect(result).to be_downloaded
    end
  end

  scenario "jobs.foreign-job-is-404" do
    it "is 404 for every caller but the owner, and identical to a job that never existed" do
      job = api.create_job(Snapnedit::Operations::REMOVE_BACKGROUND,
                           Conformance.unique_upload("ownership").asset_id)

      expect(api.get_job(job.id).state).to be_a(String)

      anonymous = Conformance.raw(:get, "/jobs/#{job.id}")
      expect(anonymous.status).to eq(404)
      expect(JSON.parse(anonymous.body).dig("error", "code")).to eq("not_found")

      wrong_key = Conformance.raw(:get, "/jobs/#{job.id}", token: "sk_live_some_other_account")
      expect(wrong_key.status).to eq(404)

      never_existed = Conformance.raw(:get, "/jobs/00000000-0000-4000-8000-000000000000")
      expect(never_existed.status).to eq(404)

      # Identical envelopes: same keys, same code, and a message that differs
      # only by the id echoed back. A job id must not be an existence oracle.
      foreign = JSON.parse(anonymous.body)
      missing = JSON.parse(never_existed.body)
      expect(missing.keys).to eq(foreign.keys)
      expect(missing["error"].keys).to eq(foreign["error"].keys)
      expect(missing["error"]["code"]).to eq(foreign["error"]["code"])
      expect(missing["error"]["message"].sub("00000000-0000-4000-8000-000000000000", "ID"))
        .to eq(foreign["error"]["message"].sub(job.id, "ID"))
    end
  end

  scenario "errors.envelope" do
    it "is always { error: { code, message } } with a code from the closed set" do
      responses = [
        Conformance.raw(:post, "/jobs", body: {}, token: Conformance.api_key),
        Conformance.raw(:get, "/jobs/00000000-0000-4000-8000-000000000000", token: Conformance.api_key),
        Conformance.raw(:get, "/destinations"),
        Conformance.raw(:post, "/uploads", body: { mime: "application/pdf", bytes: 10 },
                                           token: Conformance.api_key)
      ]
      expect(responses.map(&:status)).to eq([400, 404, 401, 400])

      responses.each do |response|
        body = JSON.parse(response.body)
        expect(body.keys).to eq(["error"])
        expect(body["error"].keys.sort).to eq(%w[code message])
        expect(Snapnedit::ErrorCodes::ALL).to include(body["error"]["code"])
        expect(body["error"]["message"]).not_to be_empty
      end
    end

    it "maps every envelope onto Snapnedit::Error with the same code and status" do
      expect { anon.get_job("00000000-0000-4000-8000-000000000000") }
        .to raise_error(Snapnedit::Error) { |e| expect([e.code, e.status]).to eq(["not_found", 404]) }
      expect { anon.destinations.list }
        .to raise_error(Snapnedit::Error) { |e| expect([e.code, e.status]).to eq(["unauthorized", 401]) }
    end
  end

  scenario "uploads.unsupported-mime" do
    it "refuses an unsupported mime before any bytes move" do
      response = Conformance.raw(:post, "/uploads", body: { mime: "application/pdf", bytes: 1024 },
                                                    token: Conformance.api_key)
      expect(response.status).to eq(400)
      expect(JSON.parse(response.body).dig("error", "code")).to eq(Snapnedit::ErrorCodes::UNSUPPORTED_MIME)

      accepted = anon.list_operations.flat_map(&:accept).uniq.sort
      expect(accepted).to eq(["image/jpeg", "image/png", "image/webp"])
      expect(accepted).to eq(Snapnedit::Mime::SUPPORTED.sort)
    end
  end

  # -------------------------------------------------------------- embed ---

  scenario "embed.session" do
    it "exchanges a publishable key for a token, and refuses a disallowed origin" do
      allowed = anon.embed.create_session(publishable_key: Conformance.publishable_key,
                                          host_origin: "http://localhost:3000")
      expect(allowed.token).to be_a(String)
      expect(Time.parse(allowed.expires_at)).to be > Time.now

      expect do
        anon.embed.create_session(publishable_key: Conformance.publishable_key,
                                  host_origin: "https://not-allowed.example")
      end.to raise_error(Snapnedit::Error) { |e|
        expect(e.status).to eq(403)
        expect(e.code).to eq("forbidden")
      }
    end

    it "mints a scoped token from a secret key, and that token authenticates as the account" do
      expect { anon.embed.create_token(ttl_seconds: 600) }
        .to raise_error(Snapnedit::Error) { |e|
          expect(e.status).to eq(401)
          expect(e.code).to eq("unauthorized")
        }

      minted = api.embed.create_token(ttl_seconds: 600)
      expect(minted.token).to be_a(String)

      as_embed = Conformance.client_with(minted.token)
      expect(as_embed.destinations.list).to be_an(Array)
    end
  end

  # ----------------------------------------------------------- webhooks ---

  scenario "webhooks.signature" do
    let(:vector) { Conformance.scenarios_doc["webhookVector"] }

    it "agrees with the fixed test vector every SDK is checked against" do
      recomputed = OpenSSL::HMAC.hexdigest("SHA256", vector["secret"],
                                           "#{vector["timestamp"]}.#{vector["rawBody"]}")
      expect(recomputed).to eq(vector["signature"])
      expect(vector["signatureHeaderValue"]).to eq("t=#{vector["timestamp"]},v1=#{vector["signature"]}")

      body = vector["rawBody"]
      header = vector["signatureHeaderValue"]
      secret = vector["secret"]
      timestamp = vector["timestamp"]
      tampered = "t=#{timestamp},v1=#{vector["signature"][0..-2]}#{vector["signature"].end_with?("a") ? "b" : "a"}"

      expect(Snapnedit::Webhooks.verify(body, header, secret)).to be(true)
      expect(Snapnedit::Webhooks.verify(body, tampered, secret)).to be(false)
      expect(Snapnedit::Webhooks.verify(body, header, "wrong secret")).to be(false)
      expect(Snapnedit::Webhooks.verify("#{body} ", header, secret)).to be(false)
      expect(Snapnedit::Webhooks.verify(body, "not a signature header", secret)).to be(false)
      expect(Snapnedit::Webhooks.verify(body, "v1=#{vector["signature"]}", secret)).to be(false)
      expect(Snapnedit::Webhooks.verify(body, "t=#{timestamp}", secret)).to be(false)
      expect(Snapnedit::Webhooks.verify(body, header, secret, tolerance: 300, now: timestamp + 10)).to be(true)
      expect(Snapnedit::Webhooks.verify(body, header, secret, tolerance: 300, now: timestamp + 3600)).to be(false)
    end

    it "uses the same signing secret the conformance server advertises" do
      expect(Conformance.config["webhookSecret"]).to eq(vector["secret"])
    end
  end

  # --------------------------------------------------------------- meta ---

  scenario "openapi.document" do
    it "describes itself, and is byte-identical to the committed document" do
      response = Conformance.raw(:get, "/openapi.json")
      expect(response.status).to eq(200)
      expect(response.content_type).to include("application/json")

      spec = JSON.parse(response.body)
      expect(spec["openapi"]).to eq("3.1.0")
      expect(spec.dig("info", "version")).to match(/\A\d+\.\d+\.\d+/)

      %w[
        /operations /uploads /uploads/{assetId}/confirm /jobs /jobs/{id}
        /destinations /destinations/{id} /destinations/{id}/test
        /destinations/{id}/presign /embed/sessions /embed/tokens
      ].each { |path| expect(spec["paths"].keys).to include(path) }

      expect(spec.dig("components", "securitySchemes").keys.sort).to eq(%w[ApiKey EmbedToken Session])
      expect(spec.dig("components", "schemas", "OperationParams.resize-image", "x-credit-cost")).to eq(0)

      committed = File.binread(File.join(Conformance.root, "docs/openapi.json"))
      expect(response.body.b).to eq(committed)
    end
  end

  # ----------------------------------------------------------- coverage ---

  it "implements every scenario in scenarios.json" do
    documented = Conformance.scenarios_doc["scenarios"].map { |s| s["id"] }
    expect(Conformance::IMPLEMENTED.sort).to eq(documented.sort)
    expect(Conformance.scenarios_doc["version"]).to eq(1)
  end
end
