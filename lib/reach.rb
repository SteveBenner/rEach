# SPDX-License-Identifier: MIT

module Reach
  VERSION = File.read(File.join(__dir__, "..", "VERSION")).strip

  def self.ports
    return nil unless defined?(Rplugin::Ports)

    Rplugin::Ports.for("reach", root: Reach::Paths.home)
  rescue StandardError
    nil
  end
end

require_relative "reach/errors"
require_relative "reach/paths"
require_relative "reach/messages"
require_relative "reach/course_time"
require_relative "reach/wire"
require_relative "reach/tarball"
require_relative "reach/crypto"
require_relative "reach/client"
require_relative "reach/packages"
require_relative "reach/corpus"

require_relative "reach/runtime"
require_relative "reach/profile"
require_relative "reach/greetings"

require_relative "reach/enrol"
require_relative "reach/guardrails"
require_relative "reach/workspace"
require_relative "reach/sync"
require_relative "reach/transcript"

require_relative "reach/gate"
require_relative "reach/shape"
require_relative "reach/attempts"

require_relative "reach/ledger"
require_relative "reach/sidecar"
require_relative "reach/integrity"
require_relative "reach/seal"
require_relative "reach/directives"
require_relative "reach/reference"
require_relative "reach/check"
require_relative "reach/checkpoint"
require_relative "reach/plan"

require_relative "reach/suite"
require_relative "reach/submit"
require_relative "reach/receipts"
require_relative "reach/hands"

require_relative "reach/harness"
require_relative "reach/hello"
require_relative "reach/setup"
require_relative "reach/mcp_bridge"
require_relative "reach/status"
require_relative "reach/cli"

module Plugin
  ID = "reach"

  module_function

  def run(args)
    Reach::CLI.run(args)
  end
end
