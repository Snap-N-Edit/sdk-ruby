# frozen_string_literal: true

require_relative "snapnedit/version"
require_relative "snapnedit/errors"
require_relative "snapnedit/operations"
require_relative "snapnedit/util"
require_relative "snapnedit/mime"
require_relative "snapnedit/http"
require_relative "snapnedit/models"
require_relative "snapnedit/transport"
require_relative "snapnedit/destinations"
require_relative "snapnedit/embed"
require_relative "snapnedit/designs"
require_relative "snapnedit/client"
require_relative "snapnedit/webhooks"

# The official Ruby client for the snapnedit AI image-editing API.
#
# Standard library only — `net/http`, `json` and `openssl`. Nothing else is
# required at runtime.
#
# @example
#   client = Snapnedit::Client.new(api_key: ENV.fetch("SNAPNEDIT_API_KEY"))
#   client.run(Snapnedit::Operations::REMOVE_BACKGROUND, "cat.jpg").write("out.png")
#
# @see https://snapnedit.com/docs/api-reference The API reference
module Snapnedit
end
