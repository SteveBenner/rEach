# frozen_string_literal: true

require "json"
require "time"
require "base64"
require "fileutils"
require "rbconfig"
require "timeout"

module Reach
  module Device
    SCHEMA = "reach.device/v1"
    OUTBOX_SCHEMA = "reach.device_outbox/v1"
    STATE_SCHEMA = "reach.device_state/v1"
    ROUTE = "/api/v1/devices/report"
    LADDER = %w[
      install.started install.downloaded install.installed setup.started setup.done session.first prompt.first
      enroll.code validation.started validation.passed enroll.username enroll.student_id enroll.confirmed
      enroll.password_chosen enroll.done signin.done materials.done assignment.first
    ].freeze
    UNINSTALLED = "uninstall.done"
    INSTALLER_ORIGINS = %w[installer setup].freeze
    PROBLEM_PATTERN = /\A[A-Z][A-Z0-9-]{1,47}\z/.freeze
    DEVICE_ID_PATTERN = /\Adev_[0-9a-f]{32}\z/.freeze
    OUTBOX_MAX = 64
    BATCH_MAX = 32
    DRAIN_TIMEOUT_S = 20
    SEND_TIMEOUT_S = 5
    DISABLED_WAIT_S = 3600
    BACKOFF_CAP_S = 3600
    BACKOFF_BASE_S = 60
    MIN_NEXT_S = 60
    NEXT_MARGIN_S = 30
    LOCK_WAIT_S = 1.0
    JOB_WINDOW_S = 30 * 86_400
    FAST_WINDOW_S = 72 * 3600
    FAST_INTERVAL_S = 300
    FILES = %w[device.json device.pem device-outbox.json device-state.json].freeze

    module_function

    def boundary(where)
      yield
    rescue StandardError => e
      Reach::Debug.fault(e, where)
      nil
    end

    def guarded(where)
      return nil if Thread.current[:reach_device_busy]

      Thread.current[:reach_device_busy] = true
      begin
        boundary(where) { yield }
      ensure
        Thread.current[:reach_device_busy] = false
      end
    end

    def dir
      File.dirname(Reach::Sidecar.path)
    end

    def identity_file
      File.join(dir, "device.json")
    end

    def key_file
      File.join(dir, "device.pem")
    end

    def outbox_file
      File.join(dir, "device-outbox.json")
    end

    def state_file
      File.join(dir, "device-state.json")
    end

    def lock_file
      File.join(dir, "device-drain.lock")
    end

    def edit_lock
      "#{state_file}.lock"
    end

    def enabled?
      boundary("device:enabled") do
        ENV["REACH_DEVICE_DISABLE"] != "1" && Reach::Paths.persona_id.nil? && !switched_off?("enabled")
      end == true
    end

    def switched_off?(key)
      return true if Reach::Update.install_config_broken?

      [Reach::Update.install_config, Reach::Runtime.load_config].any? do |config|
        section = config["device"]
        section.is_a?(Hash) && section[key] == false
      end
    end

    def live_without_yes?
      boundary("device:live_without_yes") { !switched_off?("live_without_yes") } != false
    end

    def offline?
      ENV["REACH_OFFLINE"] == "1" || Reach::Sandbox.network_blocked?
    end

    def iso(time = Time.now.utc)
      time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def now_i
      Time.now.to_i
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def read_json(path)
      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def write_json(path, data)
      Reach::StateFile.write_atomic(path, JSON.generate(data))
    end

    def edit(&block)
      FileUtils.mkdir_p(dir)
      outcome = Reach::Locks.exclusive(edit_lock, wait_s: LOCK_WAIT_S, &block)
      outcome == :busy ? block.call : outcome
    end

    def default_state
      {
        "schema" => STATE_SCHEMA, "reached" => {}, "problem" => nil, "told" => false, "next_at" => nil, "retry_at" => nil,
        "failures" => 0, "disabled_until" => nil, "stopped" => false, "backfilled" => false, "linked_install" => nil,
        "linked_attempt" => nil, "harness" => nil
      }
    end

    def read_state
      parsed = read_json(state_file)
      return default_state unless parsed

      merged = default_state.merge(parsed)
      merged["reached"] = {} unless merged["reached"].is_a?(Hash)
      merged
    end

    def write_state(state)
      write_json(state_file, state.merge("schema" => STATE_SCHEMA))
    end

    def default_outbox
      { "schema" => OUTBOX_SCHEMA, "entries" => [], "problem" => nil }
    end

    def read_outbox
      parsed = read_json(outbox_file)
      return default_outbox unless parsed

      merged = default_outbox.merge(parsed)
      merged["entries"] = Array(merged["entries"]).select { |entry| entry.is_a?(Hash) && entry["id"].is_a?(String) && entry["at"].is_a?(String) }
      merged
    end

    def write_outbox(outbox)
      write_json(outbox_file, outbox.merge("schema" => OUTBOX_SCHEMA))
    end

    def fingerprint_of(key)
      public_key = key.respond_to?(:private?) && key.private? ? key.public_key : key
      Reach::Crypto.digest_hex(public_key.to_der)
    end

    def code_for(fingerprint)
      head = fingerprint[0, 8].upcase
      "#{head[0, 4]}-#{head[4, 4]}"
    end

    def valid_identity?(data)
      return false unless data.is_a?(Hash) && data["schema"] == SCHEMA
      return false unless data["device_id"].to_s.match?(DEVICE_ID_PATTERN)

      fingerprint = data["fingerprint"].to_s
      return false unless fingerprint.match?(/\A[0-9a-f]{64}\z/)
      return false unless data["device_id"] == "dev_#{fingerprint[0, 32]}" && data["code"] == code_for(fingerprint)

      !data["public_key"].to_s.empty? && File.file?(key_file)
    end

    def identity
      data = read_json(identity_file)
      valid_identity?(data) ? data : nil
    end

    def private_key
      Reach::Crypto.load_private_key(File.read(key_file))
    end

    def aside(path)
      return nil unless File.exist?(path)

      target = "#{path}.bad"
      FileUtils.rm_f(target)
      File.rename(path, target)
      nil
    end

    def ensure_identity!(origin = "session")
      boundary("device:ensure_identity") { make_identity(origin) }
    end

    def make_identity(origin)
      found = identity
      return found if found

      FileUtils.mkdir_p(dir)
      outcome = Reach::Locks.exclusive(edit_lock, wait_s: 5.0) do
        existing = identity
        next existing if existing

        aside(identity_file)
        aside(key_file)
        create_identity(origin)
      end
      outcome == :busy ? identity : outcome
    end

    def create_identity(origin)
      key = Reach::Crypto.generate_install_key
      fingerprint = fingerprint_of(key)
      data = {
        "schema" => SCHEMA, "device_id" => "dev_#{fingerprint[0, 32]}", "fingerprint" => fingerprint,
        "code" => code_for(fingerprint), "public_key" => key.public_key.to_pem, "created_at" => iso,
        "origin" => origin.to_s
      }
      Reach::StateFile.write_atomic(key_file, key.to_pem, mode: 0o600)
      write_json(identity_file, data)
      data
    end

    def attempt_on_this_server?
      data = Reach::EnrollOutbox.read
      data.is_a?(Hash) && data["teach_url"].to_s.sub(%r{/+\z}, "") == Reach::Client.device_base_url.to_s.sub(%r{/+\z}, "")
    end

    def enrolled_install
      install = Reach::Enroll.current
      install.is_a?(Hash) && install["install_id"] && !install["revoked"] ? install : nil
    rescue Reach::Refused
      nil
    end

    def add_reached(state, outbox, id, at)
      return false if state["reached"].key?(id)

      stamp = at.is_a?(Time) ? iso(at) : at.to_s
      state["reached"][id] = stamp
      state["problem"] = nil
      state["stopped"] = false
      outbox["entries"] = (outbox["entries"] + [{ "id" => id, "at" => stamp }]).last(OUTBOX_MAX)
      true
    end

    def note(id, at: Time.now.utc)
      guarded("device:note") do
        id = id.to_s
        next nil unless LADDER.include?(id) && enabled?

        added = edit do
          state = read_state
          outbox = read_outbox
          next false unless add_reached(state, outbox, id, at)

          write_state(state)
          write_outbox(outbox)
          true
        end
        spawn_drain(read_state) if added
        added ? id : nil
      end
    end

    def note_problem(code, at: Time.now.utc)
      guarded("device:note_problem") do
        code = code.to_s
        next nil unless PROBLEM_PATTERN.match?(code) && enabled?

        added = edit do
          state = read_state
          held = state["problem"]
          next false if held.is_a?(Hash) && held["code"] == code

          problem = { "code" => code, "at" => iso(at) }
          state["problem"] = problem
          outbox = read_outbox
          outbox["problem"] = problem
          write_state(state)
          write_outbox(outbox)
          true
        end
        spawn_drain(read_state) if added
        added ? code : nil
      end
    end

    def link_attempt(_attempt_id = nil)
      guarded("device:link_attempt") do
        enabled? ? spawn_drain(read_state) : nil
      end
    end

    def link_install(_install = nil)
      guarded("device:link_install") do
        enabled? ? spawn_drain(read_state) : nil
      end
    end

    def set_harness(name)
      guarded("device:set_harness") do
        value = name.to_s
        next nil if value.empty? || value == "unknown" || !enabled?

        edit do
          state = read_state
          next nil if state["harness"] == value

          state["harness"] = value
          write_state(state)
        end
        value
      end
    end

    def blocked_now?(state)
      at = now_i
      state["disabled_until"].to_i > at || state["retry_at"].to_i > at
    end

    def spawn_drain(state = read_state)
      return nil if offline? || blocked_now?(state)

      script = 'begin; require "reach/ca_roots"; Reach::CaRoots.apply!; rescue ScriptError, StandardError; nil; end; require "reach"; Reach::Device.drain!'
      lib = File.expand_path("..", __dir__)
      Reach::Runtime.spawn_background(RbConfig.ruby, "-I", lib, "-e", script)
    end

    def drain!(origin: nil)
      boundary("device:drain") do
        next nil unless enabled? && !offline?

        FileUtils.mkdir_p(dir)
        Reach::Locks.exclusive(lock_file, wait_s: 0.0) { drain_locked(origin || "session") }
        nil
      end
    end

    def drain_locked(origin)
      device = make_identity(origin)
      backfill!(device)
      state = read_state
      outbox = read_outbox
      at = now_i
      return :disabled if state["disabled_until"].to_i > at
      return :backoff if state["retry_at"].to_i > at

      links = build_links(device, state)
      fresh = !outbox["entries"].empty? || !outbox["problem"].nil? || !links.empty?
      return :waiting if !fresh && (state["stopped"] || at + NEXT_MARGIN_S < state["next_at"].to_i)

      deliver(device, state, outbox, links, origin)
    end

    def harness_name(state)
      detected = Reach::Session.detect_harness
      return detected unless detected.to_s.empty? || detected == "unknown"

      hint = state["harness"].to_s
      hint.empty? || hint == "unknown" ? nil : hint
    end

    def report_body(device, state, sent, problem, links, origin)
      body = {
        "public_key" => device["public_key"], "reach_version" => Reach::VERSION, "origin" => origin,
        "checkpoints" => sent.map { |entry| { "id" => entry["id"], "at" => entry["at"] } }
      }
      unless Reach::Environment.report_disabled?
        fields = Reach::Environment.static_fields
        body.merge!("os" => fields["os"], "os_release" => fields["os_release"], "arch" => fields["arch"], "ruby" => fields["ruby"])
        harness = harness_name(state)
        body["harness"] = harness if harness
      end
      body["problem"] = { "code" => problem["code"], "at" => problem["at"] } if problem.is_a?(Hash)
      body["links"] = links unless links.empty?
      body
    end

    def build_links(device, state)
      links = []
      install = enrolled_install
      if install && state["linked_install"] != install["install_id"].to_s
        proof = install_proof(install, device)
        links << proof if proof
      end
      attempt = Reach::EnrollOutbox.attempt
      if attempt && !attempt.id.to_s.empty? && state["linked_attempt"] != attempt.id.to_s && attempt_on_this_server?
        proof = attempt_proof(attempt.id, attempt.key, device)
        links << proof if proof
      end
      links.first(2)
    end

    def link_proof(kind, id, key, device, at)
      payload = ["reach-device-link", kind, id.to_s, device["device_id"], at].join("\n")
      { "kind" => kind, "id" => id.to_s, "at" => at, "signature" => Base64.strict_encode64(Reach::Crypto.sign_pss(key, payload)) }
    end

    def install_proof(install, device = identity, at: iso)
      return nil unless device

      boundary("device:install_proof") do
        key = Reach::Crypto.load_private_key(File.read(Reach::Paths.install_key_file))
        link_proof("install", install["install_id"], key, device, at)
      end
    end

    def attempt_proof(attempt_id, key, device = identity, at: iso)
      return nil unless device && key

      boundary("device:attempt_proof") { link_proof("attempt", attempt_id, key, device, at) }
    end

    def deliver(device, state, outbox, links, origin)
      sent = outbox["entries"].first(BATCH_MAX)
      problem = outbox["problem"]
      body = report_body(device, state, sent, problem, links, origin)
      reply = Reach::Client.for_device(device).post_json(ROUTE, body).json
      settle(sent, problem, links, reply.is_a?(Hash) ? reply : {})
    rescue Reach::RemoteRefused => e
      e.status.to_i == 404 ? hold_off : failed(e)
    rescue Reach::Error => e
      failed(e)
    end

    def settle(sent, problem, links, reply)
      return hold_off if reply["disabled"] == true

      at = now_i
      next_s = reply["next_s"].is_a?(Integer) ? reply["next_s"] : MIN_NEXT_S
      edit do
        state = read_state
        state["failures"] = 0
        state["retry_at"] = nil
        state["disabled_until"] = nil
        state["next_at"] = at + [next_s, MIN_NEXT_S].max
        state["stopped"] = reply["stop"] == true
        links.each do |link|
          state["linked_install"] = link["id"] if link["kind"] == "install"
          state["linked_attempt"] = link["id"] if link["kind"] == "attempt"
        end
        write_state(state)
        outbox = read_outbox
        outbox["entries"] = outbox["entries"].reject { |entry| sent.any? { |item| item["id"] == entry["id"] && item["at"] == entry["at"] } }
        outbox["problem"] = nil if problem.is_a?(Hash) && outbox["problem"] == problem
        write_outbox(outbox)
      end
      Reach::Live.spawn_runner if reply["live"] == true
      :sent
    end

    def hold_off
      edit do
        state = read_state
        state["disabled_until"] = now_i + DISABLED_WAIT_S
        write_state(state)
      end
      :disabled
    end

    def failed(error)
      Reach::Debug.fault(error, "device:report")
      edit do
        state = read_state
        state["failures"] = state["failures"].to_i + 1
        ceiling = [BACKOFF_CAP_S, BACKOFF_BASE_S * (2**[state["failures"], 12].min)].min
        state["retry_at"] = now_i + (rand * ceiling).ceil
        write_state(state)
      end
      :failed
    end

    def backfill!(device)
      boundary("device:backfill") do
        next nil if read_state["backfilled"]

        edit do
          held = read_state
          next nil if held["backfilled"]

          outbox = read_outbox
          backfill_entries(held, outbox) unless INSTALLER_ORIGINS.include?(device["origin"])
          held["backfilled"] = true
          write_state(held)
          write_outbox(outbox)
        end
      end
    end

    def backfill_entries(state, outbox)
      now = Time.now.utc
      %w[install.installed setup.done session.first].each { |id| add_reached(state, outbox, id, now) }
      install = enrolled_install
      if install
        enrolled_at = parse_time(install["enrolled_at"]) || now
        add_reached(state, outbox, "prompt.first", enrolled_at)
        add_reached(state, outbox, "enroll.done", enrolled_at)
      else
        flow = Reach::EnrollFlow.read_flow
        add_reached(state, outbox, "enroll.code", now) if flow && !flow["code"].to_s.empty?
      end
      progress = Reach::Progress.read["reached"]
      signin = parse_time(progress["setup.signin"])
      add_reached(state, outbox, "signin.done", signin) if signin
      started = progress.select { |key, _| Reach::Progress.assignment_started_key?(key) }.values.map { |value| parse_time(value) }.compact.min
      add_reached(state, outbox, "assignment.first", started) if started
      cache = Reach::Paths.status_cache_file
      add_reached(state, outbox, "materials.done", File.mtime(cache).utc) if File.file?(cache)
    end

    def last_checkpoint_at(state)
      state["reached"].values.map { |value| parse_time(value) }.compact.max
    end

    def job_wanted?
      boundary("device:job_wanted") do
        next false unless enabled?

        state = read_state
        next false if state["stopped"]
        next true if enrolled_install

        last = last_checkpoint_at(state)
        !last.nil? && Time.now.to_i - last.to_i <= JOB_WINDOW_S
      end == true
    end

    def fast_cadence?
      boundary("device:fast_cadence") do
        next false if enrolled_install

        made = identity
        next true unless made

        created = parse_time(made["created_at"])
        created.nil? || Time.now.to_i - created.to_i <= FAST_WINDOW_S
      end == true
    end

    def tick(source = "background")
      boundary("device:tick") do
        next nil unless enabled?

        drain_in_time(source.to_s == "background" ? "background" : "session")
        Reach::Subscribe.ensure! if source.to_s == "background"
        nil
      end
    end

    def drain_in_time(origin)
      Timeout.timeout(DRAIN_TIMEOUT_S) { drain!(origin: origin) }
    rescue Timeout::Error => e
      overrun = Reach::NetworkError.new(Reach::Messages.text("M-TEACH-DEADLINE"))
      overrun.cause_name = e.class.name
      overrun.set_backtrace(e.backtrace)
      Reach::Debug.fault(overrun, "device:tick")
      nil
    end

    def pending_notice
      boundary("device:pending_notice") do
        next nil unless enabled? && identity

        told = edit do
          state = read_state
          next false if state["told"]

          state["told"] = true
          write_state(state)
          true
        end
        told ? Reach::Messages.text("M-DEVICE-NOTICE") : nil
      end
    end

    def mark_told!
      boundary("device:mark_told") do
        edit do
          state = read_state
          next nil if state["told"]

          state["told"] = true
          write_state(state)
        end
        nil
      end
    end

    def code_line
      boundary("device:code_line") do
        made = identity
        made ? Reach::Messages.text("M-DEVICE-CODE", code: made["code"]) : nil
      end
    end

    def local_stage
      boundary("device:local_stage") do
        state = read_state
        LADDER.reverse.find { |id| state["reached"].key?(id) }
      end
    end

    def uninstalling!(tell: true)
      guarded("device:uninstalling") do
        next nil unless enabled?

        device = identity
        next nil unless device

        if tell
          edit do
            outbox = read_outbox
            outbox["entries"] = (outbox["entries"] + [{ "id" => UNINSTALLED, "at" => iso }]).last(OUTBOX_MAX)
            write_outbox(outbox)
          end
        end
        unless offline? || !tell
          begin
            Timeout.timeout(SEND_TIMEOUT_S) { deliver(device, read_state, read_outbox, [], "session") }
          rescue Timeout::Error => e
            Reach::Debug.fault(e, "device:uninstalling")
          end
        end
        edit do
          state = read_state
          state["reached"] = {}
          state["problem"] = nil
          state["linked_install"] = nil
          state["linked_attempt"] = nil
          write_state(state)
        end
        nil
      end
    end

    def purge!
      boundary("device:purge") do
        (FILES + FILES.map { |name| "#{name}.bad" }).each { |name| FileUtils.rm_f(File.join(dir, name)) }
        FileUtils.rm_f(edit_lock)
        FileUtils.rm_f(lock_file)
        nil
      end
    end
  end
end
