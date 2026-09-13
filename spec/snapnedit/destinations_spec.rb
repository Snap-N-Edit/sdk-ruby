# frozen_string_literal: true

RSpec.describe Snapnedit::Destinations do
  let(:http) { FakeHTTP.new }
  let(:client) { Snapnedit::Client.new(api_key: "sk_live_test", base_url: "https://api.example", http: http) }

  let(:row) do
    {
      "id" => "11111111-1111-4111-8111-111111111111", "name" => "exports",
      "provider" => "s3-compatible", "bucket" => "my-bucket", "region" => "auto",
      "endpoint" => "https://s3.example", "forcePathStyle" => true, "keyPrefix" => "out/",
      "accessKeyIdLast4" => "EYID", "isDefault" => true, "deleteAfterDelivery" => false,
      "lastTest" => { "status" => "ok", "at" => "2026-09-13T00:00:00.000Z" },
      "createdAt" => "2026-09-13T00:00:00.000Z", "updatedAt" => "2026-09-13T00:00:00.000Z"
    }
  end

  it "lists destinations out of the { destinations: [...] } envelope" do
    http.stub(:get, "/destinations", json: { destinations: [row] })

    destinations = client.destinations.list
    expect(destinations.map(&:id)).to eq([row["id"]])
    expect(destinations.first).to have_attributes(
      name: "exports", provider: "s3-compatible", bucket: "my-bucket",
      key_prefix: "out/", access_key_id_last4: "EYID"
    )
    expect(destinations.first.default?).to be(true)
    expect(destinations.first.force_path_style?).to be(true)
    expect(destinations.first.delete_after_delivery?).to be(false)
  end

  it "sends snake_case keyword arguments as the api's camelCase" do
    http.stub(:post, "/destinations", status: 201, json: { destination: row })

    client.destinations.create(
      name: "exports", provider: "cloudflare-r2", bucket: "my-bucket",
      access_key_id: "AKIAEXAMPLEKEYID", secret_access_key: "shhh",
      account_id: "abc123def456", key_prefix: "out/", is_default: true,
      delete_after_delivery: true, force_path_style: false
    )

    expect(http.requests_for(:post, "/destinations").first.json).to eq(
      "name" => "exports", "provider" => "cloudflare-r2", "bucket" => "my-bucket",
      "accessKeyId" => "AKIAEXAMPLEKEYID", "secretAccessKey" => "shhh",
      "accountId" => "abc123def456", "keyPrefix" => "out/", "isDefault" => true,
      "deleteAfterDelivery" => true, "forcePathStyle" => false
    )
  end

  it "omits optional fields that were not given, rather than sending null" do
    http.stub(:post, "/destinations", status: 201, json: { destination: row })

    client.destinations.create(name: "n", provider: "aws-s3", bucket: "b",
                               access_key_id: "k", secret_access_key: "s")

    expect(http.requests.first.json.keys)
      .to contain_exactly("name", "provider", "bucket", "accessKeyId", "secretAccessKey")
  end

  it "patches with PATCH and returns the updated destination" do
    http.stub(:patch, "/destinations/", json: { destination: row.merge("name" => "renamed") })

    expect(client.destinations.update(row["id"], name: "renamed").name).to eq("renamed")
    request = http.requests.first
    expect(request.verb).to eq(:patch)
    expect(request.json).to eq("name" => "renamed")
  end

  it "deletes with no body and returns nil" do
    http.stub(:delete, "/destinations/", status: 204, body: "")
    expect(client.destinations.delete(row["id"])).to be_nil
  end

  it "reports a bucket probe that succeeded" do
    http.stub(:post, "/test", json: { ok: true, latencyMs: 42 })

    result = client.destinations.test(row["id"])
    expect(result.ok?).to be(true)
    expect(result.latency_ms).to eq(42)
    expect(result.error).to be_nil
  end

  it "reports a bucket probe that failed without raising — the HTTP call succeeded" do
    http.stub(:post, "/test", json: { ok: false, latencyMs: 900, error: "AccessDenied" })

    result = client.destinations.test(row["id"])
    expect(result.ok?).to be(false)
    expect(result.error).to eq("AccessDenied")
  end

  it "presigns a one-shot PUT" do
    http.stub(:post, "/presign", json: {
                url: "https://s3.example/my-bucket/out/2026/09/13/export-1-abc123.png",
                method: "PUT", headers: { "content-type" => "image/png" },
                key: "out/2026/09/13/export-1-abc123.png", bucket: "my-bucket",
                expiresAt: "2026-09-13T00:15:00.000Z"
              })

    signed = client.destinations.presign_upload(row["id"], ext: "png", content_type: "image/png")
    expect(signed.method).to eq("PUT")
    expect(signed.bucket).to eq("my-bucket")
    expect(signed.headers).to eq("content-type" => "image/png")
    expect(http.requests.first.json).to eq("ext" => "png", "contentType" => "image/png")
  end

  it "percent-encodes an id so it cannot break out of the path" do
    http.stub(:patch, "/destinations/", json: { destination: row })
    client.destinations.update("../../admin", name: "x")
    expect(http.requests.first.url).to eq("https://api.example/destinations/..%2F..%2Fadmin")
  end

  it "surfaces a foreign destination id as not_found, never forbidden" do
    http.stub(:patch, "/destinations/", status: 404, json: { error: { code: "not_found", message: "no" } })

    expect { client.destinations.update(row["id"], name: "x") }
      .to raise_error(Snapnedit::Error) { |e| expect([e.code, e.status]).to eq(["not_found", 404]) }
  end
end
