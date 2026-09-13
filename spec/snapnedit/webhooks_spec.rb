# frozen_string_literal: true

RSpec.describe Snapnedit::Webhooks do
  # The FIXED test vector from test/conformance/scenarios.json — the same one
  # every snapnedit SDK checks its verifier against.
  let(:secret) { "whsec_conformance_fixed_test_vector" }
  let(:timestamp) { 1_700_000_000 }
  let(:raw_body) do
    '{"id":"whd_00000000-0000-4000-8000-000000000001","type":"job.succeeded","created":1700000000,' \
      '"data":{"jobId":"9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d","operation":"remove-background",' \
      '"status":"succeeded","outputAssetId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301",' \
      '"download":"https://snapnedit.com/_local/results/abc.png?exp=1700003600&sig=deadbeef",' \
      '"input":{"kind":"asset"},"destination":null,"delivery":null}}'
  end
  let(:signature) { "8a587f5869207b7da3be52c9d2695b0201c442c27cc37d2176551349e6461d90" }
  let(:header) { "t=#{timestamp},v1=#{signature}" }

  it "reproduces the fixed vector's hex exactly" do
    expect(OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{raw_body}")).to eq(signature)
  end

  it "agrees with the vector as committed in the monorepo" do
    root = RSpec.configuration.monorepo_root
    skip "not running inside the snapnedit monorepo" unless root

    vector = JSON.parse(File.read(File.join(root, "test/conformance/scenarios.json")))["webhookVector"]
    expect(vector).to include("secret" => secret, "timestamp" => timestamp,
                              "rawBody" => raw_body, "signature" => signature,
                              "signatureHeaderValue" => header)
  end

  describe ".verify" do
    it "accepts the correct header" do
      expect(described_class.verify(raw_body, header, secret)).to be(true)
    end

    it "rejects the correct header under a different secret" do
      expect(described_class.verify(raw_body, header, "whsec_some_other_secret")).to be(false)
    end

    it "rejects a header with one hex character of v1 changed" do
      tampered = "t=#{timestamp},v1=#{signature[0..-2]}#{signature.end_with?("a") ? "b" : "a"}"
      expect(described_class.verify(raw_body, tampered, secret)).to be(false)
    end

    it "rejects a body with one byte appended" do
      expect(described_class.verify("#{raw_body} ", header, secret)).to be(false)
    end

    it "rejects a header that is not a signature header" do
      expect(described_class.verify(raw_body, "not a signature header", secret)).to be(false)
    end

    it "rejects a header with no t=" do
      expect(described_class.verify(raw_body, "v1=#{signature}", secret)).to be(false)
    end

    it "rejects a header with no v1=" do
      expect(described_class.verify(raw_body, "t=#{timestamp}", secret)).to be(false)
    end

    it "rejects a nil header without raising" do
      expect(described_class.verify(raw_body, nil, secret)).to be(false)
    end

    it "accepts a fresh delivery inside a 300s window" do
      expect(described_class.verify(raw_body, header, secret, tolerance: 300, now: timestamp + 10)).to be(true)
    end

    it "rejects a stale delivery outside a 300s window even though the MAC is correct" do
      expect(described_class.verify(raw_body, header, secret, tolerance: 300, now: timestamp + 3600)).to be(false)
    end

    it "rejects a delivery from too far in the future" do
      expect(described_class.verify(raw_body, header, secret, tolerance: 300, now: timestamp - 3600)).to be(false)
    end

    it "accepts any matching v1 during a secret rotation" do
      rotating = "t=#{timestamp},v1=#{"0" * 64},v1=#{signature}"
      expect(described_class.verify(raw_body, rotating, secret)).to be(true)
    end

    it "ignores unknown keys in the header" do
      expect(described_class.verify(raw_body, "v0=whatever,t=#{timestamp},v1=#{signature}", secret)).to be(true)
    end

    it "compares hex case-insensitively" do
      expect(described_class.verify(raw_body, "t=#{timestamp},v1=#{signature.upcase}", secret)).to be(true)
    end
  end

  describe ".construct_event" do
    it "returns the parsed event for a valid signature" do
      event = described_class.construct_event(raw_body, header, secret)
      expect(event["type"]).to eq("job.succeeded")
      expect(event.dig("data", "jobId")).to eq("9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d")
      expect(event.dig("data", "input", "kind")).to eq("asset")
    end

    it "raises SignatureVerificationError for a bad signature" do
      expect { described_class.construct_event(raw_body, "t=#{timestamp},v1=#{"0" * 64}", secret) }
        .to raise_error(Snapnedit::SignatureVerificationError)
    end

    it "raises SignatureVerificationError for a stale delivery" do
      expect { described_class.construct_event(raw_body, header, secret, tolerance: 300, now: timestamp + 3600) }
        .to raise_error(Snapnedit::SignatureVerificationError)
    end

    it "carries the unauthorized error code" do
      described_class.construct_event(raw_body, "bogus", secret)
    rescue Snapnedit::SignatureVerificationError => e
      expect(e.code).to eq(Snapnedit::ErrorCodes::UNAUTHORIZED)
    end
  end
end
