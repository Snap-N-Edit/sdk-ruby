# frozen_string_literal: true

RSpec.describe Snapnedit::Mime do
  let(:png) { "\x89PNG\r\n\x1A\n\x00\x00\x00\x0DIHDR".b }
  let(:jpeg) { "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01".b }
  let(:webp) { "RIFF\x24\x00\x00\x00WEBPVP8 ".b }

  it "accepts exactly the three mimes POST /uploads takes" do
    expect(described_class::SUPPORTED).to eq(["image/png", "image/jpeg", "image/webp"])
  end

  describe ".sniff" do
    it "recognises PNG" do
      expect(described_class.sniff(png)).to eq("image/png")
    end

    it "recognises JPEG" do
      expect(described_class.sniff(jpeg)).to eq("image/jpeg")
    end

    it "recognises WebP" do
      expect(described_class.sniff(webp)).to eq("image/webp")
    end

    it "returns nil for bytes it does not recognise" do
      expect(described_class.sniff("just some text, long enough".b)).to be_nil
    end

    it "returns nil rather than raising for a short or nil input" do
      expect(described_class.sniff("abc")).to be_nil
      expect(described_class.sniff(nil)).to be_nil
    end
  end

  describe ".detect" do
    it "prefers the magic bytes over a lying file extension" do
      expect(described_class.detect(png, "photo.jpg")).to eq("image/png")
    end

    it "falls back to the extension when the bytes are unrecognised" do
      expect(described_class.detect("nothing recognisable".b, "photo.webp")).to eq("image/webp")
    end

    it "falls back to the generic binary type when nothing is known" do
      expect(described_class.detect("nothing recognisable".b, "photo.bin"))
        .to eq(Snapnedit::Mime::DEFAULT)
    end
  end
end
