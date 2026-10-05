require "yaml"

module Reach
  module Greetings
    DEFAULT_LOCALE = "en-US"

    LOCALES_DIR = File.expand_path("../../locales", __dir__)

    class << self
      def text(id, **fields)
        template = catalogue(DEFAULT_LOCALE).fetch("greetings", {})[id.to_s]
        raise Reach::Error, "reach: unknown greeting id #{id.inspect}" unless template

        interpolate(template, fields)
      end

      def catalogue(locale)
        @catalogues ||= {}
        @catalogues[locale] ||= load_locale(locale)
      end

      def preload
        catalogue(DEFAULT_LOCALE)
        true
      rescue StandardError
        false
      end

      private

      def load_locale(locale)
        name = "greetings.#{locale}.yml"
        YAML.safe_load(File.read(Reach::Messages.locale_file(name) || File.join(LOCALES_DIR, name)))
      end

      def interpolate(template, fields)
        template.gsub(/\{([a-z_]+)\}/) do
          key = Regexp.last_match(1).to_sym
          fields.key?(key) ? fields[key].to_s : "{#{key}}"
        end
      end
    end
  end
end
