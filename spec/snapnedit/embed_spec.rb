# frozen_string_literal: true

RSpec.describe Snapnedit::Embed do
  let(:http) { FakeHTTP.new }
  let(:client) { Snapnedit::Client.new(api_key: "sk_live_test", base_url: "https://api.example", http: http) }

  describe "#create_session" do
    it "exchanges a publishable key for a token WITHOUT sending the secret key" do
      http.stub(:post, "/embed/sessions", json: { token: "et_abc", expiresAt: "2026-09-13T00:10:00.000Z" })

      token = client.embed.create_session(publishable_key: "pk_live_x", host_origin: "https://app.example.com")
      expect(token.token).to eq("et_abc")
      expect(token.expires_at).to eq("2026-09-13T00:10:00.000Z")

      request = http.requests.first
      expect(request.headers).not_to have_key("authorization")
      expect(request.json).to eq("publishableKey" => "pk_live_x", "hostOrigin" => "https://app.example.com")
    end

    it "accepts a native shell id as the host origin" do
      http.stub(:post, "/embed/sessions", json: { token: "et", expiresAt: "x" })
      client.embed.create_session(publishable_key: "pk_live_x", host_origin: "native:com.acme.photos")
      expect(http.requests.first.json["hostOrigin"]).to eq("native:com.acme.photos")
    end

    it "raises forbidden for an origin that is not on the key's allowlist" do
      http.stub(:post, "/embed/sessions", status: 403,
                                          json: { error: { code: "forbidden", message: "origin not allowed" } })

      expect { client.embed.create_session(publishable_key: "pk_live_x", host_origin: "https://evil.example") }
        .to raise_error(Snapnedit::Error) { |e| expect([e.code, e.status]).to eq(["forbidden", 403]) }
    end
  end

  describe "#create_token" do
    it "mints a scoped token with the secret key" do
      http.stub(:post, "/embed/tokens", json: { token: "et_scoped", expiresAt: "2026-09-13T00:10:00.000Z" })

      client.embed.create_token(ttl_seconds: 600, end_user_id: "u_1", max_credits: 20,
                                allowed_operations: [Snapnedit::Operations::UPSCALE],
                                origin: "https://app.example.com")

      request = http.requests.first
      expect(request.headers["authorization"]).to eq("Bearer sk_live_test")
      expect(request.json).to eq(
        "ttlSeconds" => 600, "endUserId" => "u_1", "maxCredits" => 20,
        "allowedOperations" => ["upscale"], "origin" => "https://app.example.com"
      )
    end

    it "sends an empty body when nothing is scoped" do
      http.stub(:post, "/embed/tokens", json: { token: "et", expiresAt: "x" })
      client.embed.create_token
      expect(http.requests.first.json).to eq({})
    end

    it "raises unauthorized without a secret key" do
      http.stub(:post, "/embed/tokens", status: 401, json: { error: { code: "unauthorized", message: "no" } })
      expect { client.embed.create_token }
        .to raise_error(Snapnedit::Error) { |e| expect(e.code).to eq("unauthorized") }
    end
  end
end
