require "openssl"

module Reach
  module Wire
    PROTOCOL = 1

    module_function

    def path
      File.expand_path("../../specs/wire.yml", __dir__)
    end

    def digest
      @digest ||= OpenSSL::Digest::SHA256.hexdigest(File.read(path))
    end
  end
end
