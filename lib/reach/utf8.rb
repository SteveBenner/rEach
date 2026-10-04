# SPDX-License-Identifier: MIT

module Reach
  module Utf8
    module_function

    def clean(value)
      case value
      when String
        value.dup.force_encoding(Encoding::UTF_8).scrub
      when Hash
        value.each_with_object({}) { |(key, item), out| out[clean(key)] = clean(item) }
      when Array
        value.map { |item| clean(item) }
      else
        value
      end
    end
  end
end
