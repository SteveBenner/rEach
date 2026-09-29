require "yaml"
require "time"
require "date"

module Reach
  module Messages
    DEFAULT_LOCALE = "en-US"

    LOCALES_DIR = File.expand_path("../../locales", __dir__)

    class << self
      def text(id, locale: DEFAULT_LOCALE, **fields)
        template = catalogue(locale).fetch("messages", {})[id.to_s]
        raise Reach::Error, "reach: unknown message id #{id.inspect}" unless template

        interpolate(template, fields)
      end

      def failure_reason(category, locale: DEFAULT_LOCALE)
        catalogue(locale).fetch("failure_reasons", {})[category.to_s] ||
          "The check found a problem in this scenario."
      end

      def rejection_fix(code, locale: DEFAULT_LOCALE)
        fixes = catalogue(locale).fetch("rejection_fixes", {})
        fixes[code.to_s] || fixes["default"]
      end

      def extracurricular_rules(locale: DEFAULT_LOCALE)
        Array(catalogue(locale)["extracurricular_rules"])
      end

      def course_time(value)
        Reach::CourseTime.format(value)
      end

      def catalogue(locale)
        @catalogues ||= {}
        @catalogues[locale] ||= load_locale(locale)
      end

      private

      def load_locale(locale)
        path = File.join(LOCALES_DIR, "#{locale}.yml")
        path = File.join(LOCALES_DIR, "#{DEFAULT_LOCALE}.yml") unless File.file?(path)
        YAML.safe_load(File.read(path))
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
