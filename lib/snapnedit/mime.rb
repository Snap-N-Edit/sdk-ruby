# frozen_string_literal: true

module Snapnedit
  # Works out what to declare in `POST /uploads`' `mime` field.
  #
  # snapnedit accepts exactly `image/png`, `image/jpeg` and `image/webp`, and
  # verifies the bytes server-side, so guessing from the file extension alone
  # is not good enough — the magic bytes win.
  module Mime
    # The mimes `POST /uploads` accepts (the union of every operation's
    # `accept[]` in `GET /operations`).
    # @return [Array<String>]
    SUPPORTED = ["image/png", "image/jpeg", "image/webp"].freeze

    # Fallback when nothing can be determined.
    DEFAULT = "application/octet-stream"

    EXTENSIONS = {
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".webp" => "image/webp",
      ".gif" => "image/gif",
      ".avif" => "image/avif"
    }.freeze
    private_constant :EXTENSIONS

    module_function

    # Sniffs the leading bytes of an image.
    #
    # @param bytes [String] the file contents (binary).
    # @return [String, nil] a mime type, or nil if the bytes are unrecognized.
    def sniff(bytes)
      return nil if bytes.nil? || bytes.bytesize < 12

      head = bytes.byteslice(0, 12).b
      return "image/png" if head.start_with?("\x89PNG\r\n\x1A\n".b)
      return "image/jpeg" if head.start_with?("\xFF\xD8\xFF".b)
      return "image/webp" if head.start_with?("RIFF".b) && head.byteslice(8, 4) == "WEBP".b
      return "image/gif" if head.start_with?("GIF87a".b, "GIF89a".b)

      nil
    end

    # @param path [String, nil] a file name or path.
    # @return [String, nil] the mime implied by the extension, if any.
    def from_path(path)
      return nil if path.nil?

      EXTENSIONS[File.extname(path.to_s).downcase]
    end

    # Best guess, in order: the bytes themselves, then the file extension,
    # then {DEFAULT}.
    #
    # @param bytes [String, nil]
    # @param path [String, nil]
    # @return [String]
    def detect(bytes, path = nil)
      sniff(bytes) || from_path(path) || DEFAULT
    end
  end
end
