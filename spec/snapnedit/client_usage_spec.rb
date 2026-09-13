# frozen_string_literal: true

RSpec.describe Snapnedit::Client, "#usage" do
  let(:http) { FakeHTTP.new }
  let(:client) { described_class.new(api_key: "sk_live_test", base_url: "https://api.example", http: http) }

  let(:report_body) do
    {
      "range" => { "from" => "2026-08-14T00:00:00.000Z", "to" => "2026-09-13T23:59:59.999Z" },
      "groupBy" => "operation",
      "totals" => {
        "jobs" => 12, "credits" => 17, "cacheHits" => 3, "free" => 2, "failed" => 1,
        "delivered" => 4, "deliveryFailed" => 1, "sessions" => 5, "activeSessions" => 2
      },
      "series" => [
        {
          "key" => "upscale", "label" => "upscale", "jobs" => 8, "credits" => 16, "cacheHits" => 2,
          "free" => 0, "failed" => 1, "delivered" => 4, "deliveryFailed" => 1, "sessions" => 0
        },
        {
          "key" => "resize-image", "label" => "resize-image", "jobs" => 4, "credits" => 0, "cacheHits" => 1,
          "free" => 2, "failed" => 0, "delivered" => 0, "deliveryFailed" => 0, "sessions" => 0
        }
      ],
      "keys" => [
        { "id" => "key-1", "name" => "server", "kind" => "secret", "dailyCreditLimit" => nil, "usedToday" => 9 },
        { "id" => "key-2", "name" => "web", "kind" => "publishable", "dailyCreditLimit" => 50, "usedToday" => 12 }
      ]
    }
  end

  it "GETs /usage with no query string when nothing is filtered" do
    http.stub(:get, "/usage", json: report_body)

    client.usage
    expect(http.requests.first.path).to eq("/usage")
  end

  it "sends only the filters that were given, in the api's camelCase" do
    http.stub(:get, "/usage", json: report_body)

    client.usage(group_by: :key, source: :embed, key_id: "key-2", origin: "https://app.example", operation: "upscale")

    query = URI.decode_www_form(URI.parse(http.requests.first.url).query).to_h
    expect(query).to eq(
      "groupBy" => "key", "source" => "embed", "keyId" => "key-2",
      "origin" => "https://app.example", "operation" => "upscale"
    )
  end

  it "accepts Time and Date for the window, and passes a String through untouched" do
    http.stub(:get, "/usage", json: report_body)

    client.usage(from: Time.utc(2026, 9, 1, 12, 30, 45), to: Date.new(2026, 9, 13))
    query = URI.decode_www_form(URI.parse(http.requests.first.url).query).to_h
    expect(query).to eq("from" => "2026-09-01T12:30:45.000Z", "to" => "2026-09-13")

    client.usage(from: "2026-09-01", to: "2026-09-13")
    query = URI.decode_www_form(URI.parse(http.requests.last.url).query).to_h
    expect(query).to eq("from" => "2026-09-01", "to" => "2026-09-13")
  end

  it "rejects a window argument that is neither a time nor a string" do
    expect { client.usage(from: 1_757_800_000) }.to raise_error(ArgumentError, /expected a Time/)
  end

  it "parses the range, the totals and the grouped series" do
    http.stub(:get, "/usage", json: report_body)

    report = client.usage(group_by: "operation")

    expect(report.from).to eq("2026-08-14T00:00:00.000Z")
    expect(report.to).to eq("2026-09-13T23:59:59.999Z")
    expect(report.group_by).to eq("operation")
    expect(report.totals).to have_attributes(
      jobs: 12, credits: 17, cache_hits: 3, free: 2, failed: 1,
      delivered: 4, delivery_failed: 1, sessions: 5, active_sessions: 2
    )
    expect(report.series.map(&:key)).to eq(%w[upscale resize-image])
    expect(report.bucket("upscale")).to have_attributes(label: "upscale", jobs: 8, credits: 16, cache_hits: 2)
    expect(report.bucket("resize-image").credits).to eq(0)
    expect(report.bucket("magic-eraser")).to be_nil
  end

  it "parses the key cap gauge, including an uncapped key" do
    http.stub(:get, "/usage", json: report_body)

    keys = client.usage.keys

    expect(keys.map(&:id)).to eq(%w[key-1 key-2])
    expect(keys.first).to have_attributes(name: "server", kind: "secret", daily_credit_limit: nil, used_today: 9)
    expect(keys.first.secret?).to be(true)
    expect(keys.first.capped?).to be(false)
    expect(keys.first.remaining_today).to be_nil
    expect(keys.last.publishable?).to be(true)
    expect(keys.last.remaining_today).to eq(38)
  end

  it "never lets remaining_today go negative when a key is over its cap" do
    over = report_body.merge(
      "keys" => [{ "id" => "k", "name" => "web", "kind" => "publishable",
                   "dailyCreditLimit" => 10, "usedToday" => 14 }]
    )
    http.stub(:get, "/usage", json: over)

    expect(client.usage.keys.first.remaining_today).to eq(0)
  end

  it "reads an embed token's report, which carries no keys and no series" do
    http.stub(:get, "/usage", json: {
                "range" => { "from" => "2026-09-01T00:00:00.000Z", "to" => "2026-09-13T00:00:00.000Z" },
                "groupBy" => "day",
                "totals" => { "jobs" => 0, "credits" => 0 },
                "series" => []
              })

    report = client.usage

    expect(report.keys).to eq([])
    expect(report.series).to eq([])
    # Absent counters read as 0 — "absent" and "none" mean the same for a count.
    expect(report.totals.cache_hits).to eq(0)
    expect(report.totals.active_sessions).to eq(0)
  end

  it "surfaces a 400 from a backwards range as invalid_input" do
    http.stub(:get, "/usage", status: 400,
                              json: { error: { code: "invalid_input", message: "from must not be after to" } })

    expect { client.usage(from: "2026-09-13", to: "2026-09-01") }.to raise_error(Snapnedit::Error) { |e|
      expect(e.status).to eq(400)
      expect(e.code).to eq(Snapnedit::ErrorCodes::INVALID_INPUT)
    }
  end

  it "surfaces a missing credential as unauthorized" do
    http.stub(:get, "/usage", status: 401, json: { error: { code: "unauthorized", message: "nope" } })

    expect { described_class.new(base_url: "https://api.example", http: http).usage }
      .to raise_error(Snapnedit::Error) { |e| expect(e.code).to eq(Snapnedit::ErrorCodes::UNAUTHORIZED) }
  end

  it "exposes the dimension vocabulary the api validates against" do
    expect(Snapnedit::Usage::GROUP_BY).to eq(%w[day key origin operation source])
    expect(Snapnedit::Usage::SOURCES).to eq(%w[api embed session anonymous])
    expect(Snapnedit::Usage::UNATTRIBUTED).to eq("none")
  end
end
