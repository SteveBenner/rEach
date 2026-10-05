require "openssl"
require "json"
require "rbconfig"

module Reach
  module CryptoProbe
    REEXEC_ENV = "REACH_KIT_REEXEC"
    DISABLE_ENV = "REACH_KIT_FALLBACK"
    SAMPLE_HEADER = {
      "schema" => "teach.package/v1", "kind" => "guardrails", "id" => "pkg_00000000000000000000", "version" => 1,
      "course" => "COURSE000000000000", "student_id" => "0000000", "assignment" => "A1",
      "created_at" => "2026-01-01T00:00:00Z", "content_digest" => "0" * 64, "signing_key_id" => "sk_00000000",
      "title" => "Hawaiʻi time, 8:59 p.m."
    }.freeze

    module_function

    def facts
      {
        "ruby_path" => display_path(RbConfig.ruby),
        "ruby_version" => RUBY_VERSION,
        "ruby_platform" => RUBY_PLATFORM,
        "openssl_library" => OpenSSL::OPENSSL_LIBRARY_VERSION.to_s,
        "openssl_compiled" => OpenSSL::OPENSSL_VERSION.to_s,
        "openssl_gem" => OpenSSL::VERSION.to_s,
        "gcm_native" => Reach::GCM.native_aad?,
        "kit_ruby" => kit_ruby?
      }
    end

    def display_path(path)
      home = Reach::Paths.user_home
      text = path.to_s
      return "~" if text == home

      text.start_with?(home + File::SEPARATOR) ? "~" + text[home.length..-1] : text
    rescue StandardError
      path.to_s
    end

    def kit_ruby?
      kit = kit_ruby_exe
      return false unless kit

      real(kit) == real(RbConfig.ruby)
    rescue StandardError
      false
    end

    def real(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end

    def kit_ruby_exe
      active = Reach::RuntimeKit.active
      active && active["ruby_exe"]
    rescue StandardError
      nil
    end

    def aad_sample
      Reach::Crypto.canonical_json(SAMPLE_HEADER)
    end

    def gcm_self_test
      stage = "encrypt"
      plaintext = "rEach self-test " * 64
      aad = aad_sample
      sealed = Reach::Crypto.encrypt_gcm(plaintext, aad: aad)
      stage = "decrypt"
      cipher = OpenSSL::Cipher.new(Reach::Crypto::GCM_CIPHER)
      cipher.decrypt
      stage = "set_key"
      cipher.key = sealed[:key]
      stage = "set_nonce"
      cipher.iv = sealed[:nonce]
      stage = "set_tag"
      cipher.auth_tag = sealed[:tag]
      stage = "set_aad"
      cipher.auth_data = aad
      stage = "update"
      out = cipher.update(sealed[:ciphertext])
      stage = "final"
      out << cipher.final
      stage = "compare"
      raise OpenSSL::Cipher::CipherError, "round trip mismatch" unless out == plaintext

      { "ok" => true, "aad_bytes" => aad.bytesize }
    rescue StandardError => e
      { "ok" => false, "stage" => stage, "error" => "#{e.class.name}: #{e.message}", "aad_bytes" => aad ? aad.bytesize : nil }
    end

    def rsa_self_test
      stage = "generate"
      rsa = OpenSSL::PKey::RSA.new(2048)
      stage = "oaep"
      data = OpenSSL::Random.random_bytes(32)
      wrapped = rsa.public_key.public_encrypt(data, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)
      raise OpenSSL::PKey::RSAError, "oaep round trip mismatch" unless rsa.private_decrypt(wrapped, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING) == data

      stage = "pss"
      signature = Reach::Crypto.sign_pss(rsa, "rEach self-test")
      raise OpenSSL::PKey::PKeyError, "pss does not verify" unless Reach::Crypto.verify_pss(rsa.public_key, signature, "rEach self-test")

      { "ok" => true }
    rescue StandardError => e
      { "ok" => false, "stage" => stage, "error" => "#{e.class.name}: #{e.message}" }
    end

    def disabled?
      ENV[DISABLE_ENV].to_s == "0"
    end

    def fallback!(argv, exe)
      return nil if disabled? || ENV[REEXEC_ENV].to_s == "1" || kit_ruby?

      return nil if Reach::GCM.native_aad?

      result = gcm_self_test

      kit = kit_ruby_exe
      unless kit && File.executable?(kit)
        begin
          Reach::RuntimeAuto.start
        rescue StandardError
          nil
        end
        Reach::Debug.emit_always("fault", fault_fields(result, "kit_missing"))
        return nil
      end

      Reach::Debug.emit_always("fault", fault_fields(result, "kit_reexec"))
      env = Reach::RuntimeKit.clean_env(REEXEC_ENV => "1")
      exec(env, kit, exe, *argv)
    rescue SystemCallError, NotImplementedError
      nil
    end

    def fault_fields(result, outcome)
      {
        "where" => "crypto_self_test", "exception" => "OpenSSL::Cipher::CipherError", "stage" => result["stage"],
        "outcome" => outcome, "detail" => result["error"]
      }.merge(facts)
    end
  end
end
