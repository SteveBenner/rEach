# Installing rEach

These steps are for the AI agent a student asked to install rEach from this repository's link. Follow them in order and tell the student in one sentence what you are about to do before each step that changes their computer.

## What rEach needs

- Ruby 2.6.10 to 4.0.x and `curl` (built into macOS, Windows 10+ and most Linux); Git and `unzip` are not required.
  - macOS: the built-in /usr/bin/ruby (2.6.10) is fine.
  - Windows: if `ruby -v` fails, do not install RubyInstaller. Use the Windows PowerShell command for a computer without Ruby below: it downloads rEach's own Ruby 4.0.7 into `%USERPROFILE%\reach-work\.reach-home\runtime` and adds it to the user's PATH (no administrator rights).
  - Linux: the distribution's Ruby, when it is 2.6.10 to 4.0.x.
- Never install anything system-wide or with sudo.
- Do not offer or ask about `reach runtime install`. Reach's checking tools (about 250 MB, into `~/reach-work/.reach-home/runtime`, no
  administrator rights) install themselves in the background when a session starts.

## Which section is yours

Use "Claude Code, Codex, Antigravity and Hermes" below whenever you can run shell commands for the student: Claude Code in a terminal, the Claude desktop app's Code tab, VS Code, Codex, Antigravity or Hermes Agent. If the student says they are using Claude Code, that section is yours, even when your shell is a container or sandbox. Use "Claude Cowork" only when you are the Claude desktop app's Cowork mode.

## Claude Code, Codex, Antigravity and Hermes

1. Install and set up rEach with ONE command, run as one shell call, so the student is asked for permission at most once. Put the app you are running in where the command says `<claude-code | codex | antigravity | hermes>`. If your app runs commands in a sandbox (Codex does), ask to run this one command outside the sandbox from the start: it needs the network and writes to the `reach-work` folder in the student's home folder (`~/reach-work`), so inside the sandbox it can only fail. If you cannot run it outside the sandbox, or it fails with "access denied" on `reach-work` (Codex on Windows keeps its sandbox even after the student approves), do not try another folder or a workaround: tell the student, in one short message, to open the permissions menu under the message box (it may read "Ask for approval" or "Default permissions"), choose "Full access", and send their install request again. The command downloads the public GitHub archive over HTTPS without GitHub credentials or Git, then the exact public Dovetail revision rEach needs, unpacks both with Ruby alone (no `unzip`), installs to `~/reach-work/.reach-home/plugin` (a student who installed rEach before has rEach's own files moved from `~/.reach` into `~/reach-work/.reach-home` automatically, and nothing is deleted), and runs setup for your app. The installer prints where it installed rEach and records that path in `last-install.txt` next to itself, which the setup call reads.
   - macOS and Linux:
     ```sh
     mkdir -p ~/reach-work/.reach-home/bootstrap && curl -fL --retry 3 --connect-timeout 10 https://raw.githubusercontent.com/SteveBenner/rEach/stable/scripts/reach-install -o ~/reach-work/.reach-home/bootstrap/reach-install && ruby ~/reach-work/.reach-home/bootstrap/reach-install && ruby "$(cat ~/reach-work/.reach-home/bootstrap/last-install.txt)/exe/reach" setup --harness <claude-code | codex | antigravity | hermes>
     ```
   - Windows PowerShell:
     ```powershell
     $b = "$env:USERPROFILE\reach-work\.reach-home\bootstrap"; New-Item -ItemType Directory -Force $b | Out-Null; curl.exe -fL --retry 3 --connect-timeout 10 https://raw.githubusercontent.com/SteveBenner/rEach/stable/scripts/reach-install -o "$b\reach-install"; if ($LASTEXITCODE -eq 0) { ruby "$b\reach-install" }; if ($LASTEXITCODE -eq 0) { $p = (Get-Content -Raw "$b\last-install.txt").Trim(); ruby (Join-Path $p "exe\reach") setup --harness <claude-code | codex | antigravity | hermes> }
     ```
   - Windows PowerShell, when `ruby -v` fails (no Ruby on the computer):
     ```powershell
     $b = "$env:USERPROFILE\reach-work\.reach-home\bootstrap"; New-Item -ItemType Directory -Force $b | Out-Null; curl.exe -fL --retry 3 --connect-timeout 10 https://raw.githubusercontent.com/SteveBenner/rEach/stable/scripts/reach-install.ps1 -o "$b\reach-install.ps1"; if ($LASTEXITCODE -eq 0) { powershell -NoProfile -ExecutionPolicy Bypass -File "$b\reach-install.ps1" -Harness <claude-code | codex | antigravity | hermes> }
     ```
     The script installs Ruby only when none is found, then runs the same install and setup as above.
   The archive itself is https://github.com/SteveBenner/rEach/archive/refs/heads/stable.zip. An existing install at the same place is moved to a `.backup` folder beside it (`plugin-<timestamp>`) before the new copy goes in; nothing is deleted. Set `REACH_INSTALL_KILL_SWITCH=1` to stop the installer downloading.
2. Read setup's output. Tell the student about any step it says they must do themselves (for example trusting rEach's hooks in Codex). In Codex, rEach also asks to change two Codex settings so its commands can use the internet and the reach-work folder: run `reach codex configure` in a terminal the student can type in, or call the `reach_setup` tool with action configure and relay rEach's question word for word; never answer it yourself. After a yes the student starts a new chat in Codex.
3. Setup prints a NEXT block only after a harness installed successfully. Your next message to the student must begin with the lines after "NEXT", copied exactly as printed, starting with "rEach is installed and ready." Do not summarise them, reword them or put anything before them. After them you may add setup's host steps (a new session, trusting hooks in Codex, or, in Hermes, the command setup prints for opening a course folder, such as `~/reach-work/.reach-home/bin/reach work --harness hermes`; give it exactly as printed, since `reach` alone may not be on the student's PATH). In Codex the student opens the reach-work folder in their home folder as the chat's folder. Take those host steps from rEach's Installation and Setup Guide: run `ruby "$(cat ~/reach-work/.reach-home/bootstrap/last-install.txt)/exe/reach" guide` (Windows PowerShell: `ruby (Join-Path (Get-Content -Raw "$env:USERPROFILE\reach-work\.reach-home\bootstrap\last-install.txt").Trim() "exe\reach") guide`), read what it prints, and walk the student through the steps in its "Approvals and other extra steps" section for their app and computer that are not done yet, one at a time. The guide is also at `docs/INSTALLATION-AND-SETUP-GUIDE.docx`. Then read and follow the reach-assistant skill immediately.

rEach checks the course server for updates every few minutes while a session is open and about every 15 minutes from a small background job it sets up for the student's own user (a systemd user timer on Linux, a LaunchAgent on macOS, a Task Scheduler task on Windows; never needs administrator rights). The check sends only rEach's signed check: no files, no conversation. Tell the student if they ask. To turn the background check off, set `subscribe.background` to `false` in `config.yml` or run `reach subscribe uninstall`. Before uninstalling rEach, run `reach subscribe uninstall` so the background job does not stay behind.

Already installed? rEach updates itself. To update now, run `reach update run --apply`, or `ruby ~/reach-work/.reach-home/bin/reach update run --apply` when `reach` is not on the PATH (Windows PowerShell: `ruby "$env:USERPROFILE\reach-work\.reach-home\bin\reach" update run --apply`). Do not search GitHub's releases or tags for an archive: the releases named "Reach runtime" are Ruby kits, not rEach.

## Claude Cowork

Your shell runs in a sandbox, not on the student's computer, so do not clone anything. Tell the student: open Customize › Plugins › Add › Add marketplace, paste this repository's link, add rEach, then start a new task. Stop here.

## Using Gemini?

Use the Antigravity app, Google's agent app, and pick Antigravity above. The Gemini app itself cannot run plugins.

## DeepSeek

rEach does not support DeepSeek Harness yet.
