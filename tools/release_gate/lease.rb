require "timeout"
require "json"
require "net/http"
require "time"
require "uri"
require "yaml"

module ReleaseGate
  module Lease
    ID = /\Agtl_[0-9a-f]{20}\z/.freeze
    TIMEOUT = 2
    MAX_SECONDS = 86_400

    module_function

    def source_path
      given = ENV["RELEASE_GATE_LEASE_SOURCE"].to_s
      File.expand_path(given.empty? ? "~/.config/release-gate/lease_source.yml" : given)
    end

    def source
      data = YAML.safe_load(File.read(source_path), permitted_classes: [], aliases: false)
      return nil unless data.is_a?(Hash)

      url = data["url"].to_s.strip
      return nil unless url =~ %r{\Ahttps?://[^\s]+\z}

      console = data["console_url"].to_s.strip
      { "url" => url, "console_url" => console.empty? ? nil : console }
    rescue StandardError
      nil
    end

    def parse_time(value)
      return nil unless value.is_a?(String)

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def valid?(lease, repo, now)
      return false unless lease.is_a?(Hash) && lease["id"].is_a?(String) && lease["id"].match?(ID)
      return false unless lease["repos"].is_a?(Array) && lease["repos"].include?(repo)

      granted = parse_time(lease["granted_at"])
      expires = parse_time(lease["expires_at"])
      return false if granted.nil? || expires.nil?

      granted <= now && now < expires && expires - granted <= MAX_SECONDS
    end

    def fetch(url, repo)
      uri = URI.parse(url)
      query = URI.decode_www_form(uri.query.to_s) << ["repo", repo]
      uri.query = URI.encode_www_form(query)
      net = Net::HTTP.new(uri.host, uri.port)
      net.use_ssl = uri.scheme == "https"
      net.open_timeout = TIMEOUT
      net.read_timeout = TIMEOUT
      response = net.request(Net::HTTP::Get.new(uri.request_uri, "Accept" => "application/json"))
      return nil unless response.code == "200"

      body = JSON.parse(response.body.to_s)
      body.is_a?(Hash) ? body["lease"] : nil
    end

    def active(repo, now: Time.now.utc)
      found = source
      return nil if found.nil?

      lease = Timeout.timeout(TIMEOUT * 2 + 1) { fetch(found["url"], repo.to_s) }
      valid?(lease, repo.to_s, now) ? lease : nil
    rescue StandardError, Timeout::Error
      nil
    end
  end
end
