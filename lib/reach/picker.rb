require "open3"
require "rbconfig"

module Reach
  module Picker
    TIMEOUT_S = 300
    KILL_GRACE_S = 5

    module_function

    def platform
      host = RbConfig::CONFIG["host_os"].to_s
      return :mac if host.match?(/darwin/i)
      return :windows if host.match?(/mswin|mingw|cygwin|windows/i)

      :linux
    end

    def which(name)
      suffixes = platform == :windows ? ["", ".exe", ".cmd", ".bat"] : [""]
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
        suffixes.each do |suffix|
          candidate = File.join(dir, "#{name}#{suffix}")
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
      end
      nil
    end

    def display?
      !ENV["DISPLAY"].to_s.empty? || !ENV["WAYLAND_DISPLAY"].to_s.empty?
    end

    def quote_applescript(text)
      text.to_s.gsub("\\", "\\\\\\\\").gsub('"', '\\"')
    end

    def quote_powershell(text)
      text.to_s.gsub("'", "''")
    end

    def command(folder:, prompt:)
      case platform
      when :mac
        osascript = which("osascript")
        return nil unless osascript

        verb = folder ? "choose folder with prompt \"#{quote_applescript(prompt)}\"" : "choose file with prompt \"#{quote_applescript(prompt)}\" of type {\"public.zip-archive\"}"
        [osascript, "-e", "POSIX path of (#{verb})"]
      when :windows
        shell = which("powershell") || which("pwsh")
        return nil unless shell

        dialog = if folder
                   "$d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = '#{quote_powershell(prompt)}'; $ok = $d.ShowDialog(); $path = $d.SelectedPath"
                 else
                   "$d = New-Object System.Windows.Forms.OpenFileDialog; $d.Title = '#{quote_powershell(prompt)}'; $d.Filter = 'ZIP files (*.zip)|*.zip'; $ok = $d.ShowDialog(); $path = $d.FileName"
                 end
        script = "Add-Type -AssemblyName System.Windows.Forms; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; #{dialog}; if ($ok -eq 'OK') { [Console]::Out.Write($path) } else { exit 1 }"
        [shell, "-NoProfile", "-STA", "-Command", script]
      else
        return nil unless display?

        zenity = which("zenity")
        if zenity
          args = [zenity, "--file-selection", "--title=#{prompt}"]
          args << (folder ? "--directory" : "--file-filter=ZIP files | *.zip")
          return args
        end
        kdialog = which("kdialog")
        return nil unless kdialog

        folder ? [kdialog, "--title", prompt, "--getexistingdirectory", Dir.home] : [kdialog, "--title", prompt, "--getopenfilename", Dir.home, "*.zip|ZIP files"]
      end
    end

    def run(argv)
      Open3.popen3(*argv) do |stdin, stdout, stderr, thread|
        stdin.close
        unless thread.join(TIMEOUT_S)
          terminate(thread)
          return { "status" => "timeout" }
        end
        text = stdout.read.to_s
        stderr.read
        return { "status" => "cancelled" } unless thread.value.success?

        { "status" => "ok", "output" => text }
      end
    rescue SystemCallError
      { "status" => "unavailable" }
    end

    def terminate(thread)
      Process.kill("TERM", thread.pid)
      return if thread.join(KILL_GRACE_S)

      Process.kill("KILL", thread.pid)
      thread.join(KILL_GRACE_S)
    rescue SystemCallError
      nil
    end

    def pick(folder: false)
      argv = command(folder: folder, prompt: Reach::Messages.text("M-IMPORT-PICK-PROMPT"))
      return { "status" => "unavailable" } unless argv

      result = run(argv)
      return result unless result["status"] == "ok"

      path = result["output"].to_s.strip
      path = path.sub(%r{(?<=.)/+\z}, "")
      return { "status" => "cancelled" } if path.empty?

      { "status" => "ok", "path" => path }
    end
  end
end
