require "uri"

module Reach
  module TeachUrl
    module_function

    def canonical(url)
      text = url.to_s
      return url if text.empty?
      return url if ENV["REACH_TEACH_URL_MIGRATE_DISABLE"] == "1"
      override = ENV["REACH_TEACH_URL"]
      return url if override && !override.empty?

      configured = Reach::Runtime.configured_teach_url
      return url if configured.nil? || normalize(configured).empty?

      legacy = legacy_list
      return url unless legacy.include?(normalize(text))
      return url if legacy.include?(normalize(configured))

      configured.to_s.sub(%r{/+\z}, "")
    rescue StandardError
      url
    end

    def legacy?(url)
      legacy_list.include?(normalize(url))
    rescue StandardError
      false
    end

    def legacy_list
      config = Reach::Runtime.load_config
      teach = config["teach"] if config.is_a?(Hash)
      list = teach["legacy_urls"] if teach.is_a?(Hash)
      return [] unless list.is_a?(Array)

      list.map { |entry| normalize(entry) }.reject(&:empty?)
    end

    def normalize(url)
      text = url.to_s.strip.sub(%r{/+\z}, "")
      return "" if text.empty?

      match = text.match(%r{\A([A-Za-z][A-Za-z0-9+.\-]*)://([^/?#]*)(.*)\z}m)
      return text unless match

      "#{match[1].downcase}://#{match[2].downcase}#{match[3]}"
    end
  end
end
