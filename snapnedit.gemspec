# frozen_string_literal: true

require_relative "lib/snapnedit/version"

Gem::Specification.new do |spec|
  spec.name = "snapnedit"
  spec.version = Snapnedit::VERSION
  spec.authors = ["snapnedit"]
  spec.email = ["support@snapnedit.com"]

  spec.summary = "Ruby client for the snapnedit AI image-editing API."
  spec.description = <<~DESC
    The official Ruby SDK for snapnedit — upload an image, run an AI operation
    (remove-background, upscale, magic-eraser, ...), poll the job and get the
    result, with bring-your-own-storage inputs and deliveries, saved storage
    destinations and webhook signature verification. Standard library only:
    no runtime dependencies.
  DESC

  spec.homepage = "https://snapnedit.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/Snap-N-Edit/sdk-ruby",
    "changelog_uri" => "https://github.com/Snap-N-Edit/sdk-ruby/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://snapnedit.com/docs/api-reference",
    "bug_tracker_uri" => "https://github.com/Snap-N-Edit/sdk-ruby/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "sig/**/*.rbs",
    "README.md",
    "CHANGELOG.md",
    "LICENSE"
  ]
  spec.require_paths = ["lib"]
end
