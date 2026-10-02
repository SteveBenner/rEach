require "time"
require "date"

module Reach
  module CourseTime
    DEFAULT_ZONE = "America/Los_Angeles"

    class << self
      def zone
        install = Reach::Enroll.current
        tz = install && install["course"] && install["course"]["timezone"]
        return tz if tz && !tz.to_s.empty?

        config = Reach::Runtime.load_config
        config_tz = config.is_a?(Hash) && config["course"].is_a?(Hash) ? config["course"]["timezone"] : nil
        return config_tz if config_tz && !config_tz.to_s.empty?

        DEFAULT_ZONE
      rescue StandardError
        DEFAULT_ZONE
      end

      def format(value, zone: nil)
        return "" if value.nil?

        text = value.is_a?(Time) ? nil : value.to_s
        return "" if text && text.strip.empty?

        if text && text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          return Date.strptime(text, "%Y-%m-%d").strftime("%a %-d %b")
        end

        instant = value.is_a?(Time) ? value : Time.parse(text)
        format_instant(instant, zone || self.zone)
      rescue ArgumentError, TypeError
        ""
      end

      def stamp(instant, zone: nil)
        moment = instant.is_a?(Time) ? instant : Time.parse(instant.to_s)
        zone_name = zone || self.zone
        return stamp_pacific(moment) if zone_name == DEFAULT_ZONE

        stamp_other(moment, zone_name)
      end

      private

      def stamp_pacific(instant)
        utc = instant.getutc
        dst = pacific_dst?(utc)
        shifted = (utc + ((dst ? -7 : -8) * 3600)).utc
        "#{shifted.strftime("%Y-%m-%d-%H%M")}-#{dst ? "PDT" : "PST"}"
      end

      def stamp_other(instant, zone_name)
        zoneinfo = "/usr/share/zoneinfo/#{zone_name}"
        return instant.getlocal.strftime("%Y-%m-%d-%H%M-%Z") unless File.file?(zoneinfo)

        had_tz = ENV.key?("TZ")
        previous_tz = ENV["TZ"]
        begin
          ENV["TZ"] = zone_name
          Time.at(instant.to_r).localtime.strftime("%Y-%m-%d-%H%M-%Z")
        ensure
          if had_tz
            ENV["TZ"] = previous_tz
          else
            ENV.delete("TZ")
          end
        end
      end

      def format_instant(instant, zone_name)
        if zone_name == DEFAULT_ZONE
          format_pacific(instant)
        else
          format_other(instant, zone_name)
        end
      end

      def format_pacific(instant)
        utc = instant.utc
        dst = pacific_dst?(utc)
        offset_h = dst ? -7 : -8
        label = dst ? "PDT" : "PST"
        shifted = (utc + (offset_h * 3600)).utc
        "#{shifted.strftime("%a %-d %b %-l:%M %P")} #{label}"
      end

      def pacific_dst?(utc)
        year = utc.year
        utc >= pdt_start(year) && utc < pdt_end(year)
      end

      def pdt_start(year)
        march_first = Time.utc(year, 3, 1)
        offset = (7 - march_first.wday) % 7
        second_sunday = 1 + offset + 7
        Time.utc(year, 3, second_sunday, 10, 0, 0)
      end

      def pdt_end(year)
        november_first = Time.utc(year, 11, 1)
        offset = (7 - november_first.wday) % 7
        first_sunday = 1 + offset
        Time.utc(year, 11, first_sunday, 9, 0, 0)
      end

      def format_other(instant, zone_name)
        zoneinfo = "/usr/share/zoneinfo/#{zone_name}"
        return instant.localtime.strftime("%a %-d %b %-l:%M %P %Z") unless File.file?(zoneinfo)

        had_tz = ENV.key?("TZ")
        previous_tz = ENV["TZ"]
        begin
          ENV["TZ"] = zone_name
          Time.at(instant.to_r).localtime.strftime("%a %-d %b %-l:%M %P %Z")
        ensure
          if had_tz
            ENV["TZ"] = previous_tz
          else
            ENV.delete("TZ")
          end
        end
      end
    end
  end
end
