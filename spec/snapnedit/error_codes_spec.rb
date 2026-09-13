# frozen_string_literal: true

RSpec.describe Snapnedit::ErrorCodes do
  it "lists every code the api can send, in the api's own order" do
    expect(described_class::ALL).to eq(
      %w[
        invalid_input unsupported_mime too_large not_found input_fetch_failed
        provider_failed provider_exhausted rate_limited bot_check_failed
        unauthorized forbidden payment_required internal
      ]
    )
  end

  it "matches the ErrorEnvelope enum in the api's OpenAPI document" do
    root = RSpec.configuration.monorepo_root
    skip "not running inside the snapnedit monorepo" unless root

    spec = JSON.parse(File.read(File.join(root, "docs/openapi.json")))
    enum = spec.dig("components", "schemas", "ErrorEnvelope", "properties", "error", "properties", "code", "enum")
    expect(described_class::ALL).to eq(enum)
  end

  it "exposes each code as a constant" do
    constants = described_class.constants.reject { |c| c == :ALL }.map { |c| described_class.const_get(c) }
    expect(constants.sort).to eq(described_class::ALL.sort)
  end

  describe ".coerce" do
    it "passes a known code through" do
      expect(described_class.coerce("rate_limited")).to eq("rate_limited")
    end

    it "falls back to internal for an unknown code, so future codes degrade gracefully" do
      expect(described_class.coerce("teapot")).to eq("internal")
    end

    it "falls back to internal for a non-string" do
      expect(described_class.coerce(nil)).to eq("internal")
    end
  end
end
