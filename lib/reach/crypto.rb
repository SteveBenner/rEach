require "openssl"
require "securerandom"
require "base64"
require "json"
require_relative "gcm"

module Reach
  module Crypto
    AES_KEY_BYTES = 32
    AES_IV_BYTES = 12
    RSA_KEY_BITS = 4096
    PSS_SALT_LENGTH = 32
    PSS_DIGEST = "SHA256"
    GCM_CIPHER = "aes-256-gcm"
    ENVELOPE_FIELDS = %w[header wrapped_key nonce ciphertext tag signature].freeze
    HEADER_REQUIRED_FIELDS = %w[schema kind id version course student_id created_at content_digest signing_key_id].freeze

    module_function

    def generate_install_key
      OpenSSL::PKey::RSA.new(RSA_KEY_BITS)
    end

    def canonical_json(value)
      JSON.generate(canonicalize(value))
    end

    def canonicalize(value)
      if value.is_a?(Hash)
        pairs = value.map { |k, v| [k.to_s, v] }.sort_by { |pair| pair[0] }
        pairs.each_with_object({}) { |pair, acc| acc[pair[0]] = canonicalize(pair[1]) }
      elsif value.is_a?(Array)
        value.map { |v| canonicalize(v) }
      else
        value
      end
    end

    def sign_pss(private_key, data)
      private_key.sign_pss(PSS_DIGEST, data, salt_length: PSS_SALT_LENGTH, mgf1_hash: PSS_DIGEST)
    end

    def verify_pss(public_key, signature, data)
      public_key.verify_pss(PSS_DIGEST, signature, data, salt_length: PSS_SALT_LENGTH, mgf1_hash: PSS_DIGEST)
    rescue OpenSSL::PKey::PKeyError
      false
    end

    def digest_hex(data)
      OpenSSL::Digest::SHA256.hexdigest(data.to_s)
    end

    def load_public_key(pem)
      OpenSSL::PKey::RSA.new(pem)
    end

    def load_private_key(pem)
      OpenSSL::PKey::RSA.new(pem)
    end

    def encrypt_gcm(plaintext, aad:)
      unless Reach::GCM.native_aad?
        key = SecureRandom.random_bytes(AES_KEY_BYTES)
        nonce = SecureRandom.random_bytes(AES_IV_BYTES)
        ciphertext, tag = Reach::GCM.encrypt(key: key, nonce: nonce, plaintext: plaintext, aad: aad)
        return { key: key, nonce: nonce, ciphertext: ciphertext, tag: tag }
      end

      cipher = OpenSSL::Cipher.new(GCM_CIPHER)
      cipher.encrypt
      key = cipher.random_key
      nonce = cipher.random_iv
      cipher.auth_data = aad
      ciphertext = cipher.update(plaintext) + cipher.final
      { key: key, nonce: nonce, ciphertext: ciphertext, tag: cipher.auth_tag }
    end

    def decrypt_gcm(key:, nonce:, ciphertext:, tag:, aad:)
      unless Reach::GCM.native_aad?
        return Reach::GCM.decrypt(key: key, nonce: nonce, ciphertext: ciphertext, tag: tag, aad: aad)
      end

      cipher = OpenSSL::Cipher.new(GCM_CIPHER)
      cipher.decrypt
      cipher.key = key
      cipher.iv = nonce
      cipher.auth_tag = tag
      cipher.auth_data = aad
      cipher.update(ciphertext) + cipher.final
    rescue OpenSSL::Cipher::CipherError => e
      raise Reach::VerificationFailed, "reach: could not decrypt (#{e.message})"
    end

    def wrap_key(recipient_public_key, data_key)
      recipient_public_key.public_encrypt(data_key, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)
    end

    def unwrap_key(recipient_private_key, wrapped_key)
      recipient_private_key.private_decrypt(wrapped_key, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)
    rescue OpenSSL::PKey::RSAError => e
      raise Reach::VerificationFailed, "reach: could not unwrap envelope key (#{e.message})"
    end

    def seal(header:, plaintext:, recipient_public_key:, signer_private_key:)
      header = header.merge("content_digest" => digest_hex(plaintext))
      aad = canonical_json(header)
      enc = encrypt_gcm(plaintext, aad: aad)
      wrapped = wrap_key(recipient_public_key, enc[:key])
      ciphertext_digest = digest_hex(enc[:ciphertext])
      signature = sign_pss(signer_private_key, aad + ciphertext_digest)

      {
        "header" => header,
        "wrapped_key" => Base64.strict_encode64(wrapped),
        "nonce" => Base64.strict_encode64(enc[:nonce]),
        "ciphertext" => Base64.strict_encode64(enc[:ciphertext]),
        "tag" => Base64.strict_encode64(enc[:tag]),
        "signature" => Base64.strict_encode64(signature)
      }
    end

    def open_envelope(envelope, expected_kind:, expected_student_id:, recipient_private_key:, signer_public_key_for:)
      unless envelope.is_a?(Hash) && ENVELOPE_FIELDS.all? { |f| envelope.key?(f) } && envelope.keys.size == ENVELOPE_FIELDS.size
        raise Reach::VerificationFailed, "reach: malformed envelope"
      end

      header = envelope["header"]
      unless header.is_a?(Hash) && HEADER_REQUIRED_FIELDS.all? { |f| header.key?(f) }
        raise Reach::VerificationFailed, "reach: malformed envelope header"
      end
      raise Reach::VerificationFailed, "reach: unexpected envelope schema" unless header["schema"] == "teach.package/v1"
      raise Reach::VerificationFailed, "reach: unexpected envelope kind" unless header["kind"] == expected_kind
      raise Reach::VerificationFailed, "reach: unexpected envelope student" unless header["student_id"] == expected_student_id

      signer_public_key = signer_public_key_for.call(header["signing_key_id"])
      raise Reach::VerificationFailed, "reach: unknown signing key #{header['signing_key_id']}" unless signer_public_key

      aad = canonical_json(header)
      ciphertext = decode64!(envelope["ciphertext"])
      ciphertext_digest = digest_hex(ciphertext)
      signature = decode64!(envelope["signature"])

      unless verify_pss(signer_public_key, signature, aad + ciphertext_digest)
        raise Reach::VerificationFailed, "reach: envelope signature does not verify"
      end

      wrapped_key = decode64!(envelope["wrapped_key"])
      data_key = unwrap_key(recipient_private_key, wrapped_key)
      nonce = decode64!(envelope["nonce"])
      tag = decode64!(envelope["tag"])
      plaintext = decrypt_gcm(key: data_key, nonce: nonce, ciphertext: ciphertext, tag: tag, aad: aad)

      if digest_hex(plaintext) != header["content_digest"]
        raise Reach::VerificationFailed, "reach: content digest mismatch"
      end

      [header, plaintext]
    end

    def decode64!(value)
      Base64.strict_decode64(value.to_s)
    rescue ArgumentError
      raise Reach::VerificationFailed, "reach: invalid base64 in envelope"
    end

    def sign_request(private_key, method:, target:, timestamp:, nonce:, body:)
      payload = [method.to_s.upcase, target, timestamp, nonce, digest_hex(body.to_s)].join("\n")
      Base64.strict_encode64(sign_pss(private_key, payload))
    end
  end
end
