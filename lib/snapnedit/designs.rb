# frozen_string_literal: true

module Snapnedit
  # The declarative design endpoints: compile a JSON spec into editor
  # documents, and render one server-side (no browser) to image bytes or a
  # PDF. Reach it as {Client#designs}. Both endpoints are unauthenticated.
  #
  # The spec vocabulary (layers, text runs, adjustments, effects, crops) is
  # documented with the API reference — this client passes your hash straight
  # through, so nothing here needs updating when the spec grows.
  #
  # @example Render a one-page design to PNG bytes
  #   png = client.designs.render(spec: { width: 1080, height: 1080, layers: [...] })
  #   File.binwrite("card.png", png)
  class Designs
    # Formats `POST /designs/render` can produce. A multi-page render is a PDF.
    FORMATS = %w[png jpeg webp avif pdf].freeze

    # @param transport [Transport]
    # @api private
    def initialize(transport)
      @transport = transport
    end

    # `POST /designs` — compile a spec into real editor documents.
    #
    # @param spec [Hash] a single-page `DesignSpec`, or a multi-page
    #   `{ pages: [...] }` spec.
    # @return [Hash] `{ "document" => {...} }` for a single-page spec,
    #   `{ "documents" => [...] }` for a multi-page one.
    # @raise [Snapnedit::Error]
    def create(spec)
      @transport.json(:post, "/designs", body: spec, auth: false)
    end

    # `POST /designs/render` — render to bytes.
    #
    # Pass exactly one source: +spec+, +document+, +pages+ or +documents+.
    #
    # @param spec [Hash, nil] one design spec.
    # @param document [Hash, nil] one already-compiled document.
    # @param pages [Array<Hash>, nil] one spec per page, in order.
    # @param documents [Array<Hash>, nil] one document per page, in order.
    # @param format [String, nil] one of {FORMATS}; defaults to the api's own
    #   default (`png`, or `pdf` for a multi-page render).
    # @return [String] the rendered bytes (binary).
    # @raise [ArgumentError] if no source, or more than one, is given.
    # @raise [Snapnedit::Error]
    def render(spec: nil, document: nil, pages: nil, documents: nil, format: nil)
      sources = Util.compact(spec: spec, document: document, pages: pages, documents: documents)
      if sources.size != 1
        raise ArgumentError, "pass exactly one of spec:, document:, pages: or documents: (got #{sources.size})"
      end

      payload = Util.camelize_keys(sources)
      payload["format"] = format if format
      response = @transport.raw(
        :post, "/designs/render",
        headers: { "content-type" => "application/json", "accept" => "*/*" },
        body: JSON.generate(payload), auth: false
      )
      response.body
    end
  end
end
