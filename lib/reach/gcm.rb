require "openssl"

module Reach
  module GCM
    KEY_BYTES = 32
    NONCE_BYTES = 12
    TAG_BYTES = 16
    REDUCTION = 0xE1 << 120
    LOW64 = 0xffff_ffff_ffff_ffff

    module_function

    def native_aad?
      return @native_aad unless @native_aad.nil?

      @native_aad = begin
        cipher = OpenSSL::Cipher.new("aes-256-gcm")
        cipher.encrypt
        cipher.key = "\0" * KEY_BYTES
        cipher.iv = "\0" * NONCE_BYTES
        cipher.auth_data = "a"
        true
      rescue OpenSSL::Cipher::CipherError
        false
      end
    end

    def encrypt(key:, nonce:, plaintext:, aad:)
      check!(key, nonce)
      ciphertext = ctr(key, nonce, plaintext)
      [ciphertext, tag(key, nonce, ciphertext, aad)]
    end

    def decrypt(key:, nonce:, ciphertext:, tag:, aad:)
      check!(key, nonce)
      unless tag.bytesize == TAG_BYTES && same?(tag(key, nonce, ciphertext, aad), tag)
        raise Reach::VerificationFailed, "reach: could not decrypt (authentication failed)"
      end

      ctr(key, nonce, ciphertext)
    end

    def check!(key, nonce)
      raise Reach::VerificationFailed, "reach: could not decrypt (bad key length)" unless key.bytesize == KEY_BYTES
      raise Reach::VerificationFailed, "reach: could not decrypt (bad nonce length)" unless nonce.bytesize == NONCE_BYTES
    end

    def ctr(key, nonce, data)
      return "".b if data.empty?

      cipher = OpenSSL::Cipher.new("aes-256-ctr")
      cipher.encrypt
      cipher.key = key
      cipher.iv = nonce.b + [2].pack("N")
      cipher.update(data) + cipher.final
    end

    def tag(key, nonce, ciphertext, aad)
      block = OpenSSL::Cipher.new("aes-256-ecb")
      block.encrypt
      block.key = key
      block.padding = 0
      hash_key = to_int(block.update("\0" * 16))
      mask = to_int(block.update(nonce.b + [1].pack("N")))
      from_int(ghash(hash_key, aad.b, ciphertext.b) ^ mask)
    end

    def ghash(hash_key, aad, ciphertext)
      table = table_for(hash_key)
      y = 0
      [aad, ciphertext].each do |part|
        words = pad(part).unpack("Q>*")
        i = 0
        while i < words.size
          y = multiply(table, y ^ ((words[i] << 64) | words[i + 1]))
          i += 2
        end
      end
      multiply(table, y ^ (((aad.bytesize * 8) << 64) | (ciphertext.bytesize * 8)))
    end

    def table_for(hash_key)
      singles = Array.new(128)
      v = hash_key
      128.times do |i|
        singles[i] = v
        v = (v & 1) == 1 ? (v >> 1) ^ REDUCTION : v >> 1
      end
      Array.new(16) do |j|
        row = Array.new(256, 0)
        (1..255).each do |b|
          low = b & -b
          row[b] = row[b ^ low] ^ singles[(8 * j) + 7 - (low.bit_length - 1)]
        end
        row
      end
    end

    def multiply(table, x)
      z = 0
      j = 0
      shift = 120
      while j < 16
        z ^= table[j][(x >> shift) & 0xff]
        j += 1
        shift -= 8
      end
      z
    end

    def pad(data)
      remainder = data.bytesize % 16
      remainder.zero? ? data : data + ("\0" * (16 - remainder))
    end

    def to_int(block)
      high, low = block.unpack("Q>Q>")
      (high << 64) | low
    end

    def from_int(value)
      [value >> 64, value & LOW64].pack("Q>Q>")
    end

    def same?(left, right)
      return false unless left.bytesize == right.bytesize

      diff = 0
      left.bytes.zip(right.bytes) { |a, b| diff |= a ^ b }
      diff.zero?
    end
  end
end
