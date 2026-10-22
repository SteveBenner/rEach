# frozen_string_literal: true

require "json"

def preview_fail(message)
  warn "reach-preview: #{message}"
  exit 1
end

begin
  port = Integer(ENV.fetch("REACH_PREVIEW_PORT"))
  workspace = ENV.fetch("REACH_PREVIEW_WORKSPACE")
  owned = JSON.parse(ENV.fetch("REACH_PREVIEW_OWNED", "[]"))
  idle_s = Integer(ENV.fetch("REACH_PREVIEW_IDLE_S", "1800"))
rescue KeyError, ArgumentError, JSON::ParserError => e
  preview_fail("bad environment: #{e.message}"[0, 200])
end
preview_fail("bad environment: owned paths") unless owned.is_a?(Array)
preview_fail("bad environment: idle seconds") unless idle_s.positive?

run_dir = Dir.pwd
$LOAD_PATH.unshift(File.join(run_dir, "lib"))
Dir.glob(File.join(run_dir, "modules", "*", "lib")).sort.each do |dir|
  $LOAD_PATH.unshift(dir)
end

ENV["GROKIT_ROOT"] ||= run_dir

begin
  require "grokit"
  require "grokit/api"
  Grokit.load_modules
  begin
    require "rackup/handler/webrick"
  rescue LoadError
    require "rack/handler/webrick"
  end
rescue LoadError, StandardError => e
  preview_fail("cannot load the practice app: #{e.message}"[0, 200])
end

class PreviewGate
  LIVE = %r{\Amodules/[^/]+/panel/src/.+\.svelte\z}
  FORBIDDEN = [403, { "content-type" => "text/plain; charset=utf-8" },
               ["preview answers only on this computer's own address"]].freeze

  attr_reader :last_request

  def initialize(app, port, workspace, owned)
    @app = app
    @hosts = ["127.0.0.1:#{port}", "localhost:#{port}"]
    @workspace = File.expand_path(workspace)
    @owned = owned.select { |item| item.is_a?(String) }
    @last_request = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def call(env)
    @last_request = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return FORBIDDEN.dup unless @hosts.include?(env["HTTP_HOST"].to_s)

    if env["REQUEST_METHOD"] == "GET" && env["PATH_INFO"].to_s.start_with?("/live/")
      served = live(env["PATH_INFO"].sub(%r{\A/live/}, ""))
      return served if served
    end
    @app.call(env)
  end

  private

  def live(relative)
    return nil unless relative.match?(LIVE)
    return nil if relative.include?("..") || relative.include?("\0")
    return nil unless @owned.include?(relative)

    path = File.join(@workspace, relative)
    return nil if File.symlink?(path) || !File.file?(path)

    body = File.binread(path)
    [200, { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store",
            "content-length" => body.bytesize.to_s }, [body]]
  rescue SystemCallError
    nil
  end
end

gate = PreviewGate.new(Grokit::Api.freeze.app, port, workspace, owned)
handler = defined?(Rackup::Handler::WEBrick) ? Rackup::Handler::WEBrick : Rack::Handler::WEBrick

stopping = false
server = nil
stop = lambda do
  next if stopping

  stopping = true
  Thread.new { server&.shutdown }
end

Signal.trap("TERM") { stop.call }
Signal.trap("INT") { stop.call }

watcher = Thread.new do
  loop do
    sleep 30
    idle = Process.clock_gettime(Process::CLOCK_MONOTONIC) - gate.last_request
    if idle >= idle_s
      stop.call
      break
    end
  end
end

begin
  handler.run(gate, Host: "127.0.0.1", Port: port, AccessLog: [], Logger: WEBrick::Log.new(nil, 0)) do |started|
    server = started
    $stdout.puts "reach-preview: listening #{port}"
    $stdout.flush
    stop.call if stopping
  end
rescue StandardError, SystemExit => e
  raise if e.is_a?(SystemExit)

  preview_fail("server stopped: #{e.message}"[0, 200])
ensure
  watcher.kill
end
exit 0
