require "open3"
require "rbconfig"
require "timeout"
require "shellwords"
require "base64"

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

    LINUX_TERMINALS = [
      ["x-terminal-emulator", ["-e"]],
      ["gnome-terminal", ["--"]],
      ["konsole", ["-e"]],
      ["xterm", ["-e"]]
    ].freeze
    LINUX_KEEP_OPEN = 'status=0; "$@" || status=$?; printf "\\nPress Enter to close this window. "; read -r _; exit $status'.freeze
    LAUNCH_WAIT_S = 2

    def terminal(argv)
      argv = argv.map(&:to_s)
      case RbConfig::CONFIG["host_os"]
      when /darwin/
        macos_terminal(argv)
      when /mswin|mingw|cygwin/
        windows_terminal(argv)
      else
        linux_terminal(argv)
      end
    rescue StandardError => e
      [false, "the terminal window could not be started (#{e.message.to_s.lines.first.to_s.strip})"]
    end

    def macos_terminal(argv)
      line = argv.map { |part| Shellwords.escape(part) }.join(" ")
      quoted = line.gsub(/[\\"]/) { |char| "\\#{char}" }
      _out, err, status = Open3.capture3(
        "osascript", "-e", 'tell application "Terminal" to activate', "-e", "tell application \"Terminal\" to do script \"#{quoted}\""
      )
      status.success? ? [true, nil] : [false, "Terminal did not open (#{err.to_s.lines.first.to_s.strip})"]
    end

    def windows_terminal(argv)
      inner = "& #{argv.map { |part| "'#{part.gsub("'", "''")}'" }.join(" ")}"
      encoded = Base64.strict_encode64(inner.encode("UTF-16LE"))
      script = "Start-Process -FilePath powershell -ArgumentList '-NoExit','-NoProfile','-EncodedCommand','#{encoded}'"
      _out, err, status = Open3.capture3("powershell", "-NoProfile", "-Command", script)
      status.success? ? [true, nil] : [false, "PowerShell did not open (#{err.to_s.lines.first.to_s.strip})"]
    end

    def linux_terminal(argv)
      if ENV["DISPLAY"].to_s.empty? && ENV["WAYLAND_DISPLAY"].to_s.empty?
        return [false, "this computer has no desktop session to open a terminal window in"]
      end

      name, flags = LINUX_TERMINALS.find { |candidate, _| on_path?(candidate) }
      return [false, "no terminal program was found (tried #{LINUX_TERMINALS.map(&:first).join(', ')})"] unless name

      pid = Process.spawn(name, *flags, "sh", "-c", LINUX_KEEP_OPEN, "sh", *argv, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LAUNCH_WAIT_S
      loop do
        done, status = Process.wait2(pid, Process::WNOHANG)
        return (status.success? ? [true, nil] : [false, "#{name} exited with status #{status.exitstatus}"]) if done
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.1
      end
      Process.detach(pid)
      [true, nil]
    end

    def on_path?(executable)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, executable)
        File.executable?(path) && !File.directory?(path)
      end
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
