# frozen_string_literal: true

RSpec.describe Snapnedit::Transport do
  let(:http) { FakeHTTP.new }
  let(:slept) { [] }
  let(:transport) do
    described_class.new(
      base_url: "https://api.example/", api_key: "sk_live_test", adapter: http,
      max_retries: 2, retry_base_delay: 0.5, sleeper: ->(seconds) { slept << seconds }
    )
  end

  it "sends the api key as a bearer token and a versioned user agent" do
    http.stub(:get, "/operations", json: [])
    transport.json(:get, "/operations", idempotent: true)

    headers = http.requests.first.headers
    expect(headers["authorization"]).to eq("Bearer sk_live_test")
    expect(headers["user-agent"]).to eq("snapnedit-ruby/#{Snapnedit::VERSION}")
  end

  it "omits the authorization header when auth is false" do
    http.stub(:post, "/embed/sessions", json: {})
    transport.json(:post, "/embed/sessions", body: {}, auth: false)
    expect(http.requests.first.headers).not_to have_key("authorization")
  end

  it "trims a trailing slash off the base url" do
    http.stub(:get, "/operations", json: [])
    transport.json(:get, "/operations", idempotent: true)
    expect(http.requests.first.url).to eq("https://api.example/operations")
  end

  describe "error mapping" do
    it "turns the api's error envelope into a typed error" do
      http.stub(:get, "/destinations", status: 401, json: { error: { code: "unauthorized", message: "no key" } })

      expect { transport.json(:get, "/destinations", idempotent: true) }
        .to raise_error(Snapnedit::Error) { |e|
          expect([e.code, e.status, e.message]).to eq(["unauthorized", 401, "no key"])
        }
    end

    it "coerces an unrecognized code to internal rather than blowing up" do
      http.stub(:get, "/x", status: 418, json: { error: { code: "teapot", message: "short and stout" } })
      expect { transport.json(:get, "/x") }.to raise_error(Snapnedit::Error) { |e|
        expect([e.code, e.status]).to eq(["internal", 418])
      }
    end

    it "falls back for a non-envelope error body" do
      http.stub(:get, "/x", status: 502, body: "<html>bad gateway</html>")
      expect { transport.json(:get, "/x") }.to raise_error(Snapnedit::Error, /failed with status 502/)
    end

    it "raises internal for a 2xx that is not JSON" do
      http.stub(:get, "/x", status: 200, body: "not json")
      expect { transport.json(:get, "/x") }.to raise_error(Snapnedit::Error, /expected JSON/)
    end
  end

  describe "retries" do
    it "retries an idempotent request on 429 and succeeds" do
      http.stub_sequence(:get, "/jobs/", [
                           { status: 429, json: { error: { code: "rate_limited", message: "slow down" } } },
                           { status: 200, json: { state: "succeeded" } }
                         ])

      expect(transport.json(:get, "/jobs/abc", idempotent: true)).to eq({ "state" => "succeeded" })
      expect(http.requests.size).to eq(2)
      expect(slept.size).to eq(1)
    end

    it "retries an idempotent request on 500 up to max_retries and then raises" do
      http.stub(:get, "/jobs/", status: 500, json: { error: { code: "internal", message: "boom" } })

      expect { transport.json(:get, "/jobs/abc", idempotent: true) }.to raise_error(Snapnedit::Error)
      expect(http.requests.size).to eq(3) # 1 attempt + 2 retries
    end

    it "never retries a non-idempotent request — a replayed POST /jobs could bill twice" do
      http.stub(:post, "/jobs", status: 503, json: { error: { code: "internal", message: "boom" } })

      expect { transport.json(:post, "/jobs", body: {}) }.to raise_error(Snapnedit::Error)
      expect(http.requests.size).to eq(1)
    end

    it "does not retry a 4xx that is not 408 or 429" do
      http.stub(:get, "/jobs/", status: 404, json: { error: { code: "not_found", message: "gone" } })

      expect { transport.json(:get, "/jobs/abc", idempotent: true) }.to raise_error(Snapnedit::Error)
      expect(http.requests.size).to eq(1)
    end

    it "retries a network failure for an idempotent request" do
      network = Snapnedit::Error.new("connection refused", code: "internal", status: 0)
      call_count = 0
      adapter = lambda do |**|
        call_count += 1
        raise network if call_count == 1

        Snapnedit::HTTP::Response.new(status: 200, headers: {}, body: "{}")
      end
      transport = described_class.new(
        base_url: "https://api.example", api_key: nil,
        adapter: Struct.new(:fn) { def call(**kwargs) = fn.call(**kwargs) }.new(adapter),
        sleeper: ->(seconds) { slept << seconds }
      )

      expect(transport.json(:get, "/jobs/abc", idempotent: true)).to eq({})
      expect(call_count).to eq(2)
    end

    it "does not retry a network failure for a non-idempotent request" do
      adapter = Class.new do
        attr_reader :calls

        def initialize = @calls = 0

        def call(**)
          @calls += 1
          raise Snapnedit::Error.new("refused", code: "internal", status: 0)
        end
      end.new
      transport = described_class.new(base_url: "https://api.example", api_key: nil, adapter: adapter)

      expect { transport.json(:post, "/jobs", body: {}) }.to raise_error(Snapnedit::Error, /refused/)
      expect(adapter.calls).to eq(1)
    end

    it "honours Retry-After exactly, without jitter" do
      http.stub_sequence(:get, "/jobs/", [
                           { status: 429, headers: { "retry-after" => "2" },
                             json: { error: { code: "rate_limited", message: "wait" } } },
                           { status: 200, json: {} }
                         ])

      transport.json(:get, "/jobs/abc", idempotent: true)
      expect(slept).to eq([2.0])
    end

    it "jitters its own backoff within the exponential window" do
      http.stub(:get, "/jobs/", status: 500, json: { error: { code: "internal", message: "boom" } })
      expect { transport.json(:get, "/jobs/abc", idempotent: true) }.to raise_error(Snapnedit::Error)

      expect(slept.size).to eq(2)
      expect(slept[0]).to be_between(0, 0.5)
      expect(slept[1]).to be_between(0, 1.0)
    end
  end

  it "returns nil and parses nothing for a 204" do
    http.stub(:delete, "/destinations/abc", status: 204, body: "")
    expect(transport.json(:delete, "/destinations/abc", idempotent: true, expect_empty: true)).to be_nil
  end

  it "returns raw bytes untouched" do
    http.stub(:get, "/_local/results/x.png", status: 200, body: "\x89PNG\r\n\x1A\n".b,
                                             headers: { "content-type" => "image/png" })
    response = transport.raw(:get, "/_local/results/x.png", idempotent: true)
    expect(response.body).to eq("\x89PNG\r\n\x1A\n".b)
    expect(response.content_type).to eq("image/png")
  end
end
