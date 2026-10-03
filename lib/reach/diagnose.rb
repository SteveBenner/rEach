require "json"
require "open3"
require "rbconfig"

module Reach
  module Diagnose
    PROBE_TIMEOUT_S = 30
    PACKAGE_KINDS = %w[guardrails workspace shape].freeze
    ENV_FLAGS = %w[CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED CODEX_HOME CODEX_THREAD_ID PLUGIN_ROOT CLAUDE_PLUGIN_ROOT CLAUDECODE CLAUDE_CODE_ENTRYPOINT REACH_RUBY REACH_KIT_FALLBACK REACH_KIT_REEXEC REACH_OFFLINE REACH_UPDATE_DISABLE].freeze
    PROBE_SCRIPT = 'require "json"; require "reach"; puts JSON.generate(Reach::CryptoProbe.facts.merge("gcm" => Reach::CryptoProbe.gcm_self_test))'.freeze
    STAGES = [
      [/malformed envelope|unexpected envelope/, "header"],
      [/unknown signing key/, "signing_key"],
      [/signature does not verify/, "signature"],
      [/could not unwrap/, "unwrap"],
      [/could not decrypt/, "decrypt"],
      [/content digest mismatch/, "digest"]
    ].freeze

    module_function

    def report(network: true)
      {
        "reach" => Reach::VERSION,
        "runtime" => Reach::CryptoProbe.facts,
        "kit" => kit,
        "environment" => environment,
        "self_test" => {
          "gcm" => Reach::CryptoProbe.gcm_self_test, "envelope_gcm" => envelope_gcm_test, "rsa" => Reach::CryptoProbe.rsa_self_test
        },
        "rubies" => rubies,
        "packages" => packages(network: network)
      }
    end

    def envelope_gcm_test
      aad = Reach::CryptoProbe.aad_sample
      plaintext = "rEach self-test " * 64
      sealed = Reach::Crypto.encrypt_gcm(plaintext, aad: aad)
      opened = Reach::Crypto.decrypt_gcm(key: sealed[:key], nonce: sealed[:nonce], ciphertext: sealed[:ciphertext], tag: sealed[:tag], aad: aad)
      { "ok" => opened == plaintext, "path" => Reach::GCM.native_aad? ? "openssl" : "ruby" }
    rescue StandardError => e
      { "ok" => false, "path" => Reach::GCM.native_aad? ? "openssl" : "ruby", "error" => "#{e.class.name}: #{e.message}" }
    end

    def kit
      active = Reach::RuntimeKit.active
      return { "active" => false, "platform" => safe { Reach::RuntimeKit.platform } } unless active

      {
        "active" => true, "runtime_id" => active["runtime_id"], "platform" => safe { Reach::RuntimeKit.platform },
        "ruby" => active["ruby_exe"] ? Reach::CryptoProbe.display_path(active["ruby_exe"]) : nil,
        "chrome" => !active["chrome_exe"].nil?
      }
    rescue StandardError => e
      { "active" => false, "error" => e.message }
    end

    def environment
      root = Reach::Paths.root
      {
        "home" => Reach::CryptoProbe.display_path(File.expand_path("~")),
        "reach_home" => Reach::CryptoProbe.display_path(root),
        "reach_home_set" => !ENV["REACH_HOME"].to_s.empty?,
        "reach_home_writable" => File.directory?(root) ? File.writable?(root) : nil,
        "cwd" => Reach::CryptoProbe.display_path(Dir.pwd),
        "set" => ENV_FLAGS.select { |name| !ENV[name].to_s.empty? },
        "harness" => safe { Reach::Transcript.resolve_harness(nil) }
      }
    end

    def ruby_candidates
      list = []
      list << ["running", RbConfig.ruby]
      path_ruby = which("ruby")
      list << ["path", path_ruby] if path_ruby
      list << ["system", "/usr/bin/ruby"] if File.executable?("/usr/bin/ruby")
      kit_ruby = Reach::CryptoProbe.kit_ruby_exe
      list << ["kit", kit_ruby] if kit_ruby
      seen = {}
      list.select do |_label, exe|
        real = begin
          File.realpath(exe)
        rescue SystemCallError
          exe
        end
        next false if seen[real]

        seen[real] = true
      end
    end

    def which(name)
      exts = Reach::Untar.windows? ? %w[.exe .bat .cmd] : [""]
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
        exts.each do |ext|
          path = File.join(dir, name + ext)
          return path if File.file?(path) && File.executable?(path)
        end
      end
      nil
    end

    def rubies
      lib = File.join(Reach::Runtime.root, "lib")
      ruby_candidates.map do |label, exe|
        entry = { "label" => label, "path" => Reach::CryptoProbe.display_path(exe) }
        if label == "running"
          entry.merge("gcm_ok" => Reach::CryptoProbe.gcm_self_test["ok"])
        else
          entry.merge(probe(exe, lib))
        end
      end
    end

    def probe(exe, lib)
      env = { "REACH_KIT_FALLBACK" => "0", "RUBYOPT" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil }
      out, err, status = run_with_timeout(env, [exe, "-I", lib, "-e", PROBE_SCRIPT])
      return { "error" => "exited #{status.inspect}: #{err.to_s.lines.last.to_s.strip[0, 300]}" } unless status == 0

      data = JSON.parse(out.lines.last.to_s)
      gcm = data.delete("gcm") || {}
      data.merge("gcm_ok" => gcm["ok"], "gcm_stage" => gcm["stage"], "gcm_error" => gcm["error"])
    rescue StandardError => e
      { "error" => "#{e.class.name}: #{e.message}" }
    end

    def run_with_timeout(env, argv)
      Open3.popen3(env, *argv) do |stdin, stdout, stderr, thread|
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }
        unless thread.join(PROBE_TIMEOUT_S)
          begin
            Process.kill("KILL", thread.pid)
          rescue SystemCallError
            nil
          end
          thread.join
          return [out_reader.value.to_s, "timed out after #{PROBE_TIMEOUT_S}s", :timeout]
        end
        [out_reader.value.to_s, err_reader.value.to_s, thread.value.exitstatus]
      end
    end

    def packages(network: true)
      install = Reach::Enroll.current
      return { "enrolled" => false } unless install

      store = Reach::Packages.new
      result = { "enrolled" => true }
      PACKAGE_KINDS.each do |kind|
        entry = {}
        version = safe { store.latest_version(kind) }
        entry["stored_version"] = version
        if version
          envelope = safe { store.stored_envelope(kind, version) }
          entry["stored"] = envelope ? open_staged(store, kind, envelope) : { "ok" => false, "stage" => "read" }
        end
        entry["latest"] = network ? fetch_staged(store, install, kind) : { "skipped" => "network off" }
        result[kind] = entry
      end
      result
    rescue StandardError => e
      { "error" => "#{e.class.name}: #{e.message}" }
    end

    def fetch_staged(store, install, kind)
      response = Reach::Client.for_install(install).get("/api/v1/packages/#{kind}")
      envelope = response.json
      return { "ok" => false, "stage" => "fetch", "error" => "not an envelope" } unless envelope.is_a?(Hash)

      open_staged(store, kind, envelope)
    rescue Reach::RemoteRefused => e
      { "ok" => false, "stage" => "fetch", "error" => e.code.to_s }
    rescue StandardError => e
      detail = e.respond_to?(:detail) && e.detail ? " (#{e.detail})" : ""
      { "ok" => false, "stage" => "fetch", "error" => "#{e.class.name}: #{e.message}#{detail}" }
    end

    def open_staged(store, kind, envelope)
      header, _plaintext = store.send(:open_envelope, kind, envelope)
      { "ok" => true, "version" => header["version"], "content_digest" => header["content_digest"].to_s[0, 12] }
    rescue StandardError => e
      message = e.message.to_s
      stage = STAGES.find { |pattern, _name| pattern.match?(message) }
      {
        "ok" => false, "stage" => stage ? stage[1] : "other", "error" => "#{e.class.name}: #{message}",
        "version" => envelope.is_a?(Hash) && envelope["header"].is_a?(Hash) ? envelope["header"]["version"] : nil
      }
    end

    def safe
      yield
    rescue StandardError
      nil
    end

    def text_lines(data, prefix = "")
      data.flat_map do |name, value|
        label = prefix.empty? ? name.to_s : "#{prefix}.#{name}"
        case value
        when Hash
          text_lines(value, label)
        when Array
          if value.all? { |item| item.is_a?(Hash) }
            value.each_with_index.flat_map { |item, index| text_lines(item, "#{label}[#{index}]") }
          else
            ["#{label}: #{value.join(', ')}"]
          end
        else
          ["#{label}: #{value.nil? ? '-' : value}"]
        end
      end
    end
  end
end
