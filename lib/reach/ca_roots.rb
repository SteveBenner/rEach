require "rbconfig"

module Reach
  module CaRoots
    ENV_NAME = "SSL_CERT_FILE".freeze

    module_function

    def bundled_file(ruby = RbConfig.ruby)
      File.expand_path(File.join("..", "..", "libexec", "cert.pem"), ruby)
    end

    def apply!(env = ENV, ruby = RbConfig.ruby)
      current = env[ENV_NAME].to_s
      return current if !current.empty? && File.file?(current)

      bundled = bundled_file(ruby)
      return nil unless File.file?(bundled)

      env[ENV_NAME] = bundled
    rescue StandardError
      nil
    end
  end
end
