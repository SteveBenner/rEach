require "yaml"
require "time"
require "date"

module Reach
  module Messages
    DEFAULT_LOCALE = "en-US"

    LOCALES_DIR = File.expand_path("../../locales", __dir__)

    PART_MESSAGES = %w[
      M-SUBMIT-ASK M-SUBMIT-PARTIAL-ASK M-SUBMIT-RECEIVED M-SUBMIT-PARTIAL-RECEIVED M-GRADED M-DEADLINE-24H
      M-SUBMIT-REJECTED-LATER M-SUBMIT-REJECTED-LATER-DISAGREE M-NEXT-SUBMIT M-NEXT-WAIT-GRADE M-LATE-NOTICE
    ].freeze

    SLICE_NAMES = { "backend" => "logic" }.freeze

    CUTOUT_ID = /\A([a-z][a-z0-9_]*)\.a(\d+)(?:s(\d+))?\z/.freeze

    class << self
      def text(id, locale: DEFAULT_LOCALE, **fields)
        template = catalogue(locale).fetch("messages", {})[id.to_s]
        raise Reach::Error, "reach: unknown message id #{id.inspect}" unless template

        fields = learner_part_fields(fields) if PART_MESSAGES.include?(id.to_s)
        rendered = interpolate(template, fields)
        begin
          Reach::SetupLog.note_message(id, fields)
        rescue StandardError
          nil
        end
        rendered
      end

      def learner_part_fields(fields)
        fields = fields.dup
        fields[:slice] = SLICE_NAMES.fetch(fields[:slice].to_s, fields[:slice]) if fields.key?(:slice)
        fields[:cutout] = learner_cutout(fields[:cutout]) if fields.key?(:cutout)
        fields
      end

      def learner_cutout(cutout_id)
        match = CUTOUT_ID.match(cutout_id.to_s)
        return cutout_id unless match

        module_id, assignment, step = match.captures
        title = learner_module_title(module_id)
        label = "#{title} A#{assignment}"
        step ? "#{label} step #{step}" : label
      end

      def learner_module_title(module_id)
        options = Reach::Policy.module_selection
        options = options.is_a?(Hash) ? Array(options["options"]) : []
        match = options.find { |option| option.is_a?(Hash) && option["id"] == module_id && !option["title"].to_s.empty? }
        match ? match["title"].to_s : module_id.tr("_", " ").capitalize
      rescue StandardError
        module_id.tr("_", " ").capitalize
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

      def preload
        catalogue(DEFAULT_LOCALE)
        true
      rescue StandardError
        false
      end

      def locale_file(name)
        dirs = [LOCALES_DIR]
        begin
          dirs << File.join(Reach::Paths.managed_install_dir, "locales")
        rescue StandardError
          nil
        end
        dirs.map { |dir| File.join(dir, name) }.find { |path| File.file?(path) }
      end

      private

      def load_locale(locale)
        path = locale_file("#{locale}.yml") || locale_file("#{DEFAULT_LOCALE}.yml")
        YAML.safe_load(File.read(path || File.join(LOCALES_DIR, "#{DEFAULT_LOCALE}.yml")))
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
