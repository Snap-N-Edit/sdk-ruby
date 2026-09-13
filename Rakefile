# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

# Unit specs only — the conformance suite needs the monorepo's node server.
RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = "--tag ~conformance"
end

RSpec::Core::RakeTask.new(:conformance) do |t|
  t.rspec_opts = "--tag conformance"
end

RuboCop::RakeTask.new

task default: %i[rubocop spec]
