# frozen_string_literal: true

module Snapnedit
  # The 17 operation ids the api serves, as constants, plus the two pieces of
  # catalog metadata worth having offline: which operations demand a mask and
  # what each one costs in credits.
  #
  # The authoritative catalog is `GET /operations`
  # ({Client#list_operations}) — including each operation's JSON Schema for
  # `params`. These constants exist so an id is a compile-time-ish typo rather
  # than a runtime 400.
  #
  # @example
  #   client.run(Snapnedit::Operations::REMOVE_BACKGROUND, "cat.png")
  module Operations
    # Cut the subject out of its background (1 credit).
    REMOVE_BACKGROUND = "remove-background"
    # Enlarge 2x or 4x (2 credits). `params: { factor: "2" | "4" }`.
    UPSCALE = "upscale"
    # Deblur / sharpen (1 credit).
    UNBLUR = "unblur"
    # Colorize a black-and-white photo (1 credit).
    COLORIZE = "colorize"
    # Apply an artistic style (2 credits).
    STYLE_TRANSFER = "style-transfer"
    # Portrait retouch (1 credit).
    RETOUCH = "retouch"
    # Face beautify (1 credit).
    BEAUTIFY = "beautify"
    # Erase whatever the mask covers (2 credits). Requires `maskAssetId`.
    MAGIC_ERASER = "magic-eraser"
    # Generate new content inside the mask (3 credits). Requires `maskAssetId`.
    GENERATIVE_FILL = "generative-fill"
    # Remove a masked watermark (2 credits). Requires `maskAssetId`.
    REMOVE_WATERMARK = "remove-watermark"
    # Denoise (1 credit).
    AI_DENOISE = "ai-denoise"
    # Replace the sky (2 credits).
    REPLACE_SKY = "replace-sky"
    # Relight the scene (2 credits).
    RELIGHT = "relight"
    # Replace the background (2 credits).
    REPLACE_BACKGROUND = "replace-background"
    # Strip EXIF/metadata (1 credit).
    STRIP_METADATA = "strip-metadata"
    # Detect and remove a watermark with no mask (2 credits).
    AUTO_REMOVE_WATERMARK = "auto-remove-watermark"
    # Resize (FREE, 0 credits). `params: { width:, height:, fit:, ... }`.
    RESIZE_IMAGE = "resize-image"

    # Every operation id, in catalog order — the same order `GET /operations`
    # returns them in.
    # @return [Array<String>]
    ALL = [
      REMOVE_BACKGROUND,
      UPSCALE,
      UNBLUR,
      COLORIZE,
      STYLE_TRANSFER,
      RETOUCH,
      BEAUTIFY,
      MAGIC_ERASER,
      GENERATIVE_FILL,
      REMOVE_WATERMARK,
      AI_DENOISE,
      REPLACE_SKY,
      RELIGHT,
      REPLACE_BACKGROUND,
      STRIP_METADATA,
      AUTO_REMOVE_WATERMARK,
      RESIZE_IMAGE
    ].freeze

    # The operations that refuse a job without `params[:maskAssetId]`.
    # {Client#run}'s `mask:` argument uploads one and sets it for you.
    # @return [Array<String>]
    REQUIRES_MASK = [MAGIC_ERASER, GENERATIVE_FILL, REMOVE_WATERMARK].freeze

    # Credit cost per operation, mirroring
    # `paths['/operations'].get['x-credit-cost']` in the api's OpenAPI
    # document. A cache hit is billed nothing regardless.
    # @return [Hash{String => Integer}]
    CREDIT_COSTS = {
      REMOVE_BACKGROUND => 1,
      UPSCALE => 2,
      UNBLUR => 1,
      COLORIZE => 1,
      STYLE_TRANSFER => 2,
      RETOUCH => 1,
      BEAUTIFY => 1,
      MAGIC_ERASER => 2,
      GENERATIVE_FILL => 3,
      REMOVE_WATERMARK => 2,
      AI_DENOISE => 1,
      REPLACE_SKY => 2,
      RELIGHT => 2,
      REPLACE_BACKGROUND => 2,
      STRIP_METADATA => 1,
      AUTO_REMOVE_WATERMARK => 2,
      RESIZE_IMAGE => 0
    }.freeze

    # @param id [Object]
    # @return [Boolean] whether +id+ is one of {ALL}.
    def self.valid?(id)
      ALL.include?(id)
    end

    # @param id [String]
    # @return [Boolean] whether the operation demands a caller-painted mask.
    def self.requires_mask?(id)
      REQUIRES_MASK.include?(id)
    end

    # @param id [String]
    # @return [Integer, nil] the credit cost, or nil for an unknown id.
    def self.credit_cost(id)
      CREDIT_COSTS[id]
    end
  end
end
