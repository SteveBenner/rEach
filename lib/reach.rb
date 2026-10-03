# SPDX-License-Identifier: MIT

module Reach
  VERSION = File.read(File.join(__dir__, "..", "VERSION")).strip

  def self.ports
    return nil if Reach::Paths.persona_id
    return nil unless defined?(Rplugin::Ports)

    Rplugin::Ports.for("reach", root: File.expand_path("..", __dir__))
  rescue StandardError
    nil
  end
end

require_relative "reach/errors"
require_relative "reach/paths"
require_relative "reach/locks"
require_relative "reach/messages"
require_relative "reach/course_time"
require_relative "reach/wire"
require_relative "reach/tarball"
require_relative "reach/crypto"
require_relative "reach/crypto_probe"
require_relative "reach/diagnose"
require_relative "reach/debug"
require_relative "reach/os_info"
require_relative "reach/debug_render"
require_relative "reach/link"
require_relative "reach/client"
require_relative "reach/packages"
require_relative "reach/brain_spool"
require_relative "reach/brain_index"
require_relative "reach/brain"
require_relative "reach/corpus"
require_relative "reach/course_corpus"
require_relative "reach/storage"
require_relative "reach/json_stream"
require_relative "reach/picker"
require_relative "reach/export_import"

require_relative "reach/runtime"
require_relative "reach/profile"
require_relative "reach/greetings"

require_relative "reach/identity"
require_relative "reach/fingerprint"
require_relative "reach/stamp"
require_relative "reach/enroll"
require_relative "reach/instructor"
require_relative "reach/persona"
require_relative "reach/enrollment_lock"
require_relative "reach/guardrails"
require_relative "reach/workspace"
require_relative "reach/sync"
require_relative "reach/session"
require_relative "reach/retired_capture"

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

require_relative "reach/download"
require_relative "reach/untar"
require_relative "reach/unzip"
require_relative "reach/zip"
require_relative "reach/archive"
require_relative "reach/guide"
require_relative "reach/runtime_kit"
require_relative "reach/runtime_auto"
require_relative "reach/suite"
require_relative "reach/submit"
require_relative "reach/receipts"
require_relative "reach/receipt_acks"
require_relative "reach/pace"
require_relative "reach/late_work"
require_relative "reach/grades"
require_relative "reach/extra_credit"
require_relative "reach/imports"
require_relative "reach/limits"
require_relative "reach/policy"
require_relative "reach/login"
require_relative "reach/enroll_flow"
require_relative "reach/consent"
require_relative "reach/modules"
require_relative "reach/transfer"
require_relative "reach/part"
require_relative "reach/next"
require_relative "reach/support"
require_relative "reach/hands"
require_relative "reach/ladder"
require_relative "reach/qualify"

require_relative "reach/update"
require_relative "reach/harness"
require_relative "reach/hello"
require_relative "reach/codex_cache"
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
