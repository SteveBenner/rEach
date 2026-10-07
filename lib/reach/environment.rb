# SPDX-License-Identifier: MIT

require "open3"
require "rbconfig"
require "timeout"

module Reach
  module Environment
    module_function

    READER_TIMEOUT_S = 3
    VALUE_LIMIT = 64
    HEADER_LIMIT = 320
    UNKNOWN = "unknown".freeze

    def report
      @report ||= build
    end

    def header
      return nil if ENV["REACH_ENV_REPORT_DISABLE"].to_s == "1"

      data = report
      value = %w[harness os os_release arch ruby].map { |key| "#{key}=#{clean(data[key])}" }.join(";")
      value.bytesize > HEADER_LIMIT ? nil : value
    rescue StandardError
      nil
    end

    def build
      {
        "harness" => harness,
        "os" => Reach::KnownIssues.os_name,
        "os_release" => os_release,
        "arch" => arch,
        "ruby" => RUBY_VERSION
      }
    end

    def harness
      found = Reach::KnownIssues.harness.to_s
      return found unless found.empty?

      $stdin.tty? ? "terminal" : UNKNOWN
    rescue StandardError
      UNKNOWN
    end

    def arch
      raw = RbConfig::CONFIG["host_cpu"].to_s
      case raw
      when /\A(x86_64|amd64|x64)\z/i then "x86_64"
      when /\A(arm64|aarch64)\z/i then "arm64"
      else raw.empty? ? UNKNOWN : raw
      end
    end

    def os_release
      value = case Reach::KnownIssues.os_name
              when "macos" then macos_release
              when "windows" then windows_release
              else linux_release
              end
      value.to_s.empty? ? UNKNOWN : value
    rescue StandardError
      UNKNOWN
    end

    def macos_release
      version = read("sw_vers", "-productVersion")
      version.empty? ? nil : "macOS #{version}"
    end

    def windows_release
      match = read("cmd", "/c", "ver").match(/Version\s+(\d+)\.(\d+)\.(\d+)/)
      return nil unless match

      build = match[3].to_i
      "#{build >= 22_000 ? 'Windows 11' : 'Windows 10'} (#{match[1]}.#{match[2]}.#{match[3]})"
    end

    def linux_release
      fields = os_release_fields
      name = fields["NAME"].to_s
      version = fields["VERSION_ID"].to_s
      return "#{name} #{version}".strip unless name.empty?

      kernel = read("uname", "-r")
      kernel.empty? ? nil : "Linux #{kernel}"
    end

    def os_release_fields
      path = ["/etc/os-release", "/usr/lib/os-release"].find { |candidate| File.file?(candidate) }
      return {} unless path

      Timeout.timeout(READER_TIMEOUT_S) do
        File.readlines(path).each_with_object({}) do |line, acc|
          match = line.chomp.match(/\A([A-Z_]+)=(.*)\z/)
          acc[match[1]] = match[2].strip.gsub(/\A["']|["']\z/, "") if match
        end
      end
    rescue StandardError, Timeout::Error
      {}
    end

    def read(*command)
      Timeout.timeout(READER_TIMEOUT_S) do
        out, _err, status = Open3.capture3(*command)
        status.success? ? out.to_s.strip : ""
      end
    rescue StandardError, Timeout::Error
      ""
    end

    def clean(value)
      text = value.to_s.gsub(/[^A-Za-z0-9 ._()+-]/, "")[0, VALUE_LIMIT]
      text.empty? ? UNKNOWN : text
    end
  end
end
