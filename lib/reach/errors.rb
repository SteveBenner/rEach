module Reach
  class Error < StandardError
  end

  class Refused < Error
  end

  class GateBlocked < Error
    attr_reader :message_id

    def initialize(message_id, text)
      super(text)
      @message_id = message_id
    end
  end

  class VerificationFailed < Error
  end

  class NetworkError < Error
  end

  class Offline < NetworkError
  end

  class InstallError < Error
  end

  class RemoteRefused < Error
    attr_reader :code, :status

    def initialize(code, status, message)
      @code = code
      @status = status
      super(message)
    end
  end
end
