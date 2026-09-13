# frozen_string_literal: true

RSpec.describe Snapnedit::Operations do
  it "lists exactly the 17 operation ids, in catalog order" do
    expect(described_class::ALL).to eq(
      %w[
        remove-background upscale unblur colorize style-transfer retouch beautify
        magic-eraser generative-fill remove-watermark ai-denoise replace-sky relight
        replace-background strip-metadata auto-remove-watermark resize-image
      ]
    )
  end

  it "exposes every id as a constant" do
    ids = described_class.constants
                         .reject { |c| %i[ALL REQUIRES_MASK CREDIT_COSTS].include?(c) }
                         .map { |c| described_class.const_get(c) }
    expect(ids.sort).to eq(described_class::ALL.sort)
  end

  it "matches the operation enum in the api's OpenAPI document" do
    root = RSpec.configuration.monorepo_root
    skip "not running inside the snapnedit monorepo" unless root

    spec = JSON.parse(File.read(File.join(root, "docs/openapi.json")))
    enum = spec.dig("components", "schemas", "CreateJobRequest", "properties", "operation", "enum")
    expect(described_class::ALL).to eq(enum)
  end

  it "matches the credit costs published on the OpenAPI document" do
    root = RSpec.configuration.monorepo_root
    skip "not running inside the snapnedit monorepo" unless root

    spec = JSON.parse(File.read(File.join(root, "docs/openapi.json")))
    expect(described_class::CREDIT_COSTS).to eq(spec.dig("paths", "/operations", "get", "x-credit-cost"))
  end

  it "knows which operations demand a caller-painted mask" do
    expect(described_class::REQUIRES_MASK).to contain_exactly(
      "magic-eraser", "generative-fill", "remove-watermark"
    )
    expect(described_class.requires_mask?("magic-eraser")).to be(true)
    expect(described_class.requires_mask?("upscale")).to be(false)
  end

  it "knows resize-image is free and upscale costs 2" do
    expect(described_class.credit_cost("resize-image")).to eq(0)
    expect(described_class.credit_cost("upscale")).to eq(2)
    expect(described_class.credit_cost("not-an-operation")).to be_nil
  end

  it "validates ids" do
    expect(described_class.valid?("upscale")).to be(true)
    expect(described_class.valid?("Upscale")).to be(false)
  end

  it "prices every operation it lists" do
    expect(described_class::CREDIT_COSTS.keys).to match_array(described_class::ALL)
  end
end
