require "open3"
require "rbconfig"
require "timeout"

module Reach
  module Desktop
    LIMIT_S = 8

    module_function

    def notify(text)
      Timeout.timeout(LIMIT_S) do
        case RbConfig::CONFIG["host_os"]
        when /darwin/
          macos(text)
        when /mswin|mingw|cygwin/
          windows(text)
        else
          linux(text)
        end
      end
      true
    rescue StandardError, Timeout::Error
      false
    end

    def macos(text)
      escaped = text.gsub("\\", "\\\\\\\\").gsub('"', '\\"')
      Open3.capture3("osascript", "-e", "display notification \"#{escaped}\" with title \"rEach\"")
    end

    def windows(text)
      escaped = text.gsub("'", "''")
      script = <<~POWERSHELL
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $template.GetElementsByTagName("text")
        $texts.Item(0).AppendChild($template.CreateTextNode("rEach")) > $null
        $texts.Item(1).AppendChild($template.CreateTextNode('#{escaped}')) > $null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("rEach").Show($toast)
      POWERSHELL
      Open3.capture3("powershell", "-NoProfile", "-Command", script)
    end

    def linux(text)
      _out, _err, status = Open3.capture3("which", "notify-send")
      return unless status.success?

      Open3.capture3("notify-send", "rEach", text)
    end
  end
end
