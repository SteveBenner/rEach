require "json"
require "net/http"
require "open3"
require "uri"
require_relative "repo"

module ReleaseGate
  class Closeout
    TIMEOUT = 3
    ATTEMPTS = 2
    MAX_PATHS = 200
    SKIP_SUBJECT = /\A(?:fixup|squash|amend)!/.freeze
    ID_PATTERN = /\Aiss_[0-9a-f]{20}\z/.freeze
    TRAILERS = %w[Fixes-Issue Probably-Fixes].freeze

    def self.run(argv)
      new(argv[1]).commit_msg if argv[0] == "commit-msg" && argv[1]
    rescue StandardError, Timeout::Error
      nil
    ensure
      exit(0)
    end

    def initialize(file)
      @file = file
    end

    def commit_msg
      return if ENV["CLOSEOUT_DISABLE"] == "1"
      return if git("config", "--bool", "closeout.enabled").strip == "false"
      return if merge_in_progress?

      repo = Repo.detect
      return if repo.nil?

      token = repo.token
      url = repo.teach_url
      return if token.nil? || url.nil? || !url.match?(Repo::HTTP_PATTERN)

      lines = message_lines
      subject = lines.find { |line| !line.strip.empty? }.to_s.strip
      return if subject.empty? || subject.match?(SKIP_SUBJECT)

      message = lines.join("\n").strip
      answer = post(url, token, request_body(repo.name, subject, message))
      return unless answer.is_a?(Hash) && answer["matches"].is_a?(Array)

      answer["matches"].each { |match| add_trailer(match, message, subject) }
    end

    private

    def git(*args)
      out, status = Open3.capture2("git", *args, err: File::NULL)
      status.success? ? out : ""
    rescue StandardError
      ""
    end

    def merge_in_progress?
      path = git("rev-parse", "--git-path", "MERGE_HEAD").strip
      !path.empty? && File.exist?(path)
    end

    def comment_char
      char = git("config", "core.commentChar").strip
      char.empty? || char == "auto" ? "#" : char
    end

    def message_lines
      char = comment_char
      File.read(@file).lines.map(&:chomp).reject { |line| line.start_with?(char) }
    end

    def request_body(name, subject, message)
      branch = git("symbolic-ref", "--short", "-q", "HEAD").strip
      paths = git("diff", "--cached", "--name-only").lines.map(&:strip).reject(&:empty?).first(MAX_PATHS)
      JSON.generate("repo" => name, "subject" => subject[0, 300], "message" => message[0, 8000],
                    "branch" => branch[0, 200], "paths" => paths.map { |path| path[0, 300] })
    end

    def post(base, token, body)
      uri = URI.parse("#{base}/api/v1/ops/release-gate/closeout/match")
      ATTEMPTS.times do |attempt|
        sleep(0.2 + rand * 0.4) if attempt.positive?
        begin
          net = Net::HTTP.new(uri.host, uri.port)
          net.use_ssl = uri.scheme == "https"
          net.open_timeout = TIMEOUT
          net.read_timeout = TIMEOUT
          net.write_timeout = TIMEOUT if net.respond_to?(:write_timeout=)
          request = Net::HTTP::Post.new(uri.request_uri)
          request["Authorization"] = "Bearer #{token}"
          request["Accept"] = "application/json"
          request["Content-Type"] = "application/json"
          request.body = body
          response = net.request(request)
          code = response.code.to_i
          return JSON.parse(response.body.to_s) if code >= 200 && code < 300
          return nil if code >= 400 && code < 500 && code != 429
        rescue StandardError, Timeout::Error
          next
        end
      end
      nil
    end

    def add_trailer(match, message, subject)
      return unless match.is_a?(Hash)

      id = match["id"].to_s
      trailer = match["trailer"].to_s
      return unless id.match?(ID_PATTERN) && TRAILERS.include?(trailer)
      return if message.include?(id)

      _out, status = Open3.capture2("git", "interpret-trailers", "--in-place", "--if-exists", "addIfDifferent",
                                    "--trailer", "#{trailer}: #{id}", @file, err: File::NULL)
      $stderr.puts("closeout: #{trailer} #{id} (#{subject})") if status.success?
    end
  end
end

ReleaseGate::Closeout.run(ARGV) if $PROGRAM_NAME == __FILE__
