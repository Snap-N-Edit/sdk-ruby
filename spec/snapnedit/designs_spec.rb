# frozen_string_literal: true

RSpec.describe Snapnedit::Designs do
  let(:http) { FakeHTTP.new }
  let(:client) { Snapnedit::Client.new(base_url: "https://api.example", http: http) }
  let(:spec) { { width: 1080, height: 1080, layers: [{ type: "text", text: "hi" }] } }

  it "compiles a spec into a document" do
    http.stub(:post, "/designs", json: { document: { id: "doc_1" } })
    expect(client.designs.create(spec)).to eq("document" => { "id" => "doc_1" })
  end

  it "renders to raw bytes" do
    http.stub(:post, "/designs/render", body: "\x89PNG".b, headers: { "content-type" => "image/png" })

    expect(client.designs.render(spec: spec, format: "png")).to eq("\x89PNG".b)
    expect(http.requests.first.json).to include("format" => "png")
  end

  it "renders multiple pages to a PDF" do
    http.stub(:post, "/designs/render", body: "%PDF-1.7", headers: { "content-type" => "application/pdf" })

    expect(client.designs.render(pages: [spec, spec], format: "pdf")).to start_with("%PDF")
    expect(http.requests.first.json["pages"].size).to eq(2)
  end

  it "refuses more than one source" do
    expect { client.designs.render(spec: spec, document: { id: "d" }) }
      .to raise_error(ArgumentError, /exactly one/)
  end

  it "refuses no source at all" do
    expect { client.designs.render }.to raise_error(ArgumentError, /exactly one/)
  end

  it "calls the design endpoints anonymously — they take no credential" do
    http.stub(:post, "/designs", json: { document: {} })
    client.designs.create(spec)
    expect(http.requests.first.headers).not_to have_key("authorization")
  end

  it "lists the formats the renderer can produce" do
    expect(described_class::FORMATS).to eq(%w[png jpeg webp avif pdf])
  end
end
