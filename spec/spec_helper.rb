# frozen_string_literal: true

require "json"
require "snapnedit"

require_relative "support/fake_http"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # The conformance suite spawns the monorepo's node server; it is excluded
  # from the default run (`bundle exec rspec`) and selected with
  # `bundle exec rspec --tag conformance`.
  config.filter_run_excluding(:conformance) unless config.filter_manager.inclusions.rules.key?(:conformance)

  # The path to the snapnedit monorepo checkout, when this gem is sitting
  # inside it. Nil in the standalone mirror, where the conformance server and
  # the OpenAPI document are not available.
  config.add_setting(:monorepo_root, default: nil)
  root = File.expand_path("../../..", __dir__)
  config.monorepo_root = root if File.exist?(File.join(root, "test/conformance/scenarios.json"))
end
