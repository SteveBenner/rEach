require "open3"
require_relative "picker"
require_relative "messages"

module Reach
  module EnrollWindow
    TITLE = "rEach".freeze
    SEPARATOR = "\u001f".freeze
    FIELDS = %w[code username student_id password password_again].freeze
    LABELS = %w[M-ENR-WIN-CODE M-ENR-WIN-USERNAME M-ENR-WIN-ID M-ENR-WIN-PASSWORD M-ENR-WIN-PASSWORD-AGAIN].freeze

    POWERSHELL_FORM = <<~'POWERSHELL'.freeze
      Add-Type -AssemblyName System.Windows.Forms
      Add-Type -AssemblyName System.Drawing
      [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
      $f = New-Object System.Windows.Forms.Form
      $f.Text = 'rEach'
      $f.StartPosition = 'CenterScreen'
      $f.TopMost = $true
      $f.FormBorderStyle = 'FixedDialog'
      $f.MaximizeBox = $false
      $f.MinimizeBox = $false
      $y = 14
      foreach ($name in 'INTRO', 'NOTICE') {
        $t = [Environment]::GetEnvironmentVariable("REACH_WIN_$name")
        if ($t) {
          $l = New-Object System.Windows.Forms.Label
          $l.Text = $t
          $l.Location = New-Object System.Drawing.Point(16, $y)
          $l.Size = New-Object System.Drawing.Size(428, 64)
          if ($name -eq 'NOTICE') { $l.ForeColor = [System.Drawing.Color]::Firebrick }
          $f.Controls.Add($l)
          $y += 70
        }
      }
      $boxes = @()
      for ($i = 1; $i -le 5; $i++) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = [Environment]::GetEnvironmentVariable("REACH_WIN_L$i")
        $l.Location = New-Object System.Drawing.Point(16, $y)
        $l.Size = New-Object System.Drawing.Size(428, 18)
        $f.Controls.Add($l)
        $b = New-Object System.Windows.Forms.TextBox
        $b.Location = New-Object System.Drawing.Point(16, ($y + 20))
        $b.Size = New-Object System.Drawing.Size(428, 24)
        if ($i -ge 4) { $b.UseSystemPasswordChar = $true } else { $b.Text = [Environment]::GetEnvironmentVariable("REACH_WIN_V$i") }
        $f.Controls.Add($b)
        $boxes += $b
        $y += 54
      }
      $ok = New-Object System.Windows.Forms.Button
      $ok.Text = [Environment]::GetEnvironmentVariable('REACH_WIN_OK')
      $ok.Location = New-Object System.Drawing.Point(244, ($y + 6))
      $ok.Size = New-Object System.Drawing.Size(96, 28)
      $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
      $cancel = New-Object System.Windows.Forms.Button
      $cancel.Text = [Environment]::GetEnvironmentVariable('REACH_WIN_CANCEL')
      $cancel.Location = New-Object System.Drawing.Point(348, ($y + 6))
      $cancel.Size = New-Object System.Drawing.Size(96, 28)
      $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
      $f.Controls.Add($ok)
      $f.Controls.Add($cancel)
      $f.AcceptButton = $ok
      $f.CancelButton = $cancel
      $f.ClientSize = New-Object System.Drawing.Size(460, ($y + 48))
      if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        [Console]::Out.Write((($boxes | ForEach-Object { $_.Text }) -join [char]31))
        exit 0
      }
      exit 1
    POWERSHELL

    POWERSHELL_MESSAGE = <<~'POWERSHELL'.freeze
      Add-Type -AssemblyName System.Windows.Forms
      [System.Windows.Forms.MessageBox]::Show([Environment]::GetEnvironmentVariable('REACH_WIN_TEXT'), 'rEach') | Out-Null
    POWERSHELL

    APPLESCRIPT_FORM = <<~'APPLESCRIPT'.freeze
      on run argv
        set answers to {}
        repeat with i from 1 to 5
          set question to item i of argv
          if i > 3 then
            set reply to display dialog question default answer "" with title "rEach" with hidden answer
          else
            set reply to display dialog question default answer (item (5 + i) of argv) with title "rEach"
          end if
          set end of answers to text returned of reply
        end repeat
        set AppleScript's text item delimiters to (ASCII character 31)
        return answers as text
      end run
    APPLESCRIPT

    APPLESCRIPT_MESSAGE = <<~'APPLESCRIPT'.freeze
      on run argv
        display dialog (item 1 of argv) with title "rEach" buttons {"OK"} default button 1
      end run
    APPLESCRIPT

    module_function

    def backend
      case Reach::Picker.platform
      when :windows
        shell ? :windows : nil
      when :mac
        Reach::Picker.which("osascript") ? :mac : nil
      else
        return nil if ENV["DISPLAY"].to_s.empty? && ENV["WAYLAND_DISPLAY"].to_s.empty?
        return :zenity if Reach::Picker.which("zenity")

        Reach::Picker.which("kdialog") ? :kdialog : nil
      end
    rescue StandardError
      nil
    end

    def available?
      !backend.nil?
    end

    def shell
      Reach::Picker.which("powershell") || Reach::Picker.which("pwsh")
    end

    def labels
      LABELS.map { |id| Reach::Messages.text(id) }
    end

    def heading(notice)
      [Reach::Messages.text("M-ENR-WIN-INTRO"), notice].compact.join("\n\n")
    end

    def collect(notice: nil, defaults: {})
      prefill = FIELDS.first(3).map { |name| defaults[name].to_s }
      raw = case backend
            when :windows then collect_windows(notice, prefill)
            when :mac then collect_mac(notice, prefill)
            when :zenity then collect_zenity(notice)
            when :kdialog then collect_kdialog(notice, prefill)
            end
      return nil if raw.nil?

      parts = raw.split(SEPARATOR, -1)
      return nil unless parts.size == FIELDS.size

      FIELDS.zip(parts.map(&:strip)).to_h
    rescue StandardError
      nil
    end

    def capture(env, argv)
      out, _err, status = Open3.capture3(env, *argv)
      status.success? ? out.to_s.sub(/\r?\n\z/, "") : nil
    end

    def collect_windows(notice, prefill)
      env = { "REACH_WIN_INTRO" => Reach::Messages.text("M-ENR-WIN-INTRO"), "REACH_WIN_NOTICE" => notice.to_s,
              "REACH_WIN_OK" => Reach::Messages.text("M-ENR-WIN-OK"), "REACH_WIN_CANCEL" => Reach::Messages.text("M-ENR-WIN-CANCEL") }
      labels.each_with_index { |text, index| env["REACH_WIN_L#{index + 1}"] = text }
      prefill.each_with_index { |text, index| env["REACH_WIN_V#{index + 1}"] = text }
      capture(env, [shell, "-NoProfile", "-STA", "-Command", POWERSHELL_FORM])
    end

    def collect_mac(notice, prefill)
      questions = labels
      questions[0] = "#{heading(notice)}\n\n#{questions[0]}"
      capture({}, ["osascript", "-e", APPLESCRIPT_FORM, *questions, *prefill])
    end

    def collect_zenity(notice)
      argv = ["zenity", "--forms", "--title", TITLE, "--text", heading(notice), "--separator", SEPARATOR]
      labels.each_with_index { |text, index| argv.concat([index >= 3 ? "--add-password" : "--add-entry", text]) }
      capture({}, argv)
    end

    def collect_kdialog(notice, prefill)
      answers = labels.each_with_index.map do |text, index|
        question = index.zero? ? "#{heading(notice)}\n\n#{text}" : text
        argv = index >= 3 ? ["kdialog", "--title", TITLE, "--password", question] : ["kdialog", "--title", TITLE, "--inputbox", question, prefill[index]]
        answer = capture({}, argv)
        return nil if answer.nil?

        answer
      end
      answers.join(SEPARATOR)
    end

    def inform(text)
      case backend
      when :windows then capture({ "REACH_WIN_TEXT" => text.to_s }, [shell, "-NoProfile", "-STA", "-Command", POWERSHELL_MESSAGE])
      when :mac then capture({}, ["osascript", "-e", APPLESCRIPT_MESSAGE, text.to_s])
      when :zenity then capture({}, ["zenity", "--info", "--title", TITLE, "--no-markup", "--text", text.to_s])
      when :kdialog then capture({}, ["kdialog", "--title", TITLE, "--msgbox", text.to_s])
      end
      nil
    rescue StandardError
      nil
    end
  end
end
