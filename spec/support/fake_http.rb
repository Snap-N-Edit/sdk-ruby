# frozen_string_literal: true

# An in-memory HTTP adapter, injected as `Snapnedit::Client.new(http: ...)`.
#
# The gem's only seam with the network is `#call(method:, url:, headers:,
# body:)`, so the unit specs need no WebMock, no VCR and no sockets: they
# stub that one method and read back what the client actually sent.
class FakeHTTP
  # One request the client made.
  Recorded = Struct.new(:verb, :url, :headers, :body, keyword_init: true) do
    def path
      URI.parse(url).request_uri
    end

    def json
      JSON.parse(body)
    end
  end

  attr_reader :requests

  def initialize
    @stubs = []
    @requests = []
  end

  # Registers a response reused for every matching request.
  #
  # @param method [Symbol]
  # @param matcher [String, Regexp] matched against the request url.
  def stub(method, matcher, status: 200, body: nil, json: nil, headers: nil, error: nil)
    @stubs << {
      method: method, matcher: matcher, error: error,
      responses: [response_for(status:, body:, json:, headers:)], persistent: true
    }
    self
  end

  # Registers a sequence of responses for the same request, consumed in order;
  # the last one repeats. Used for polling.
  #
  # @param method [Symbol]
  # @param matcher [String, Regexp]
  # @param responses [Array<Hash>] each `{ status:, json:, body:, headers:, error: }`.
  def stub_sequence(method, matcher, responses)
    @stubs << {
      method: method, matcher: matcher, error: nil,
      responses: responses.map { |r| r[:error] || response_for(**r) }, persistent: false
    }
    self
  end

  def call(method:, url:, headers: {}, body: nil)
    @requests << Recorded.new(verb: method, url: url, headers: headers, body: body)
    stub = @stubs.find { |s| s[:method] == method && matches?(s[:matcher], url) }
    raise "FakeHTTP: no stub for #{method.to_s.upcase} #{url}" if stub.nil?

    raise stub[:error] if stub[:error]

    result = stub[:persistent] || stub[:responses].size == 1 ? stub[:responses].first : stub[:responses].shift
    raise result if result.is_a?(Exception)

    result
  end

  # @return [Array<Recorded>] every request matching a method (and optionally a url fragment).
  def requests_for(method, matcher = nil)
    @requests.select { |r| r.verb == method && (matcher.nil? || matches?(matcher, r.url)) }
  end

  private

  def matches?(matcher, url)
    matcher.is_a?(Regexp) ? matcher.match?(url) : url.include?(matcher)
  end

  def response_for(status: 200, body: nil, json: nil, headers: nil)
    Snapnedit::HTTP::Response.new(
      status: status,
      headers: headers || { "content-type" => json.nil? ? "application/octet-stream" : "application/json" },
      body: json.nil? ? (body || "") : JSON.generate(json)
    )
  end
end
