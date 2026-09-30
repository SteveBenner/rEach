# Installing rEach

These steps are for the AI agent a student asked to install rEach from this repository's link. Follow them in order and tell the student in one sentence what you are about to do before each step that changes their computer.

## What rEach needs

- Ruby 2.6.10 to 4.0.x and `curl` (built into macOS, Windows 10+ and most Linux); Git and `unzip` are not required.
  - macOS: the built-in /usr/bin/ruby (2.6.10) is fine.
  - Windows: if `ruby -v` fails, ask the student first, then install Ruby 4.0 from https://rubyinstaller.org for this user only (no administrator rights).
  - Linux: the distribution's Ruby, when it is 2.6.10 to 4.0.x.
- Never install anything system-wide or with sudo.

## Which section is yours

Use "Claude Code, Codex, Antigravity and Hermes" below whenever you can run shell commands for the student: Claude Code in a terminal, the Claude desktop app's Code tab, VS Code, Codex, Antigravity or Hermes Agent. If the student says they are using Claude Code, that section is yours, even when your shell is a container or sandbox. Use "Claude Cowork" only when you are the Claude desktop app's Cowork mode.

## Claude Code, Codex, Antigravity and Hermes

1. Run the installer. It downloads the public GitHub archive over HTTPS without GitHub credentials or Git, then downloads the exact public Dovetail revision rEach needs, unpacks both with Ruby alone (no `unzip`), and installs to `~/.reach/plugin`.
   - macOS and Linux:
     ```sh
     mkdir -p ~/.reach/bootstrap
     curl -fL --retry 3 --connect-timeout 10 https://raw.githubusercontent.com/SteveBenner/rEach/main/bin/reach-install -o ~/.reach/bootstrap/reach-install
     ruby ~/.reach/bootstrap/reach-install
     ```
   - Windows PowerShell:
     ```powershell
     New-Item -ItemType Directory -Force "$env:USERPROFILE\.reach\bootstrap" | Out-Null
     curl.exe -fL --retry 3 --connect-timeout 10 https://raw.githubusercontent.com/SteveBenner/rEach/main/bin/reach-install -o "$env:USERPROFILE\.reach\bootstrap\reach-install"
     ruby "$env:USERPROFILE\.reach\bootstrap\reach-install" --destination "$env:USERPROFILE\.reach\plugin"
     ```
   The archive itself is https://github.com/SteveBenner/rEach/archive/refs/heads/main.zip. An existing `~/.reach/plugin` is moved to `~/.reach/.backup/plugin-<timestamp>` before the new copy goes in; nothing is deleted. Set `REACH_INSTALL_KILL_SWITCH=1` to stop the installer downloading.
2. Run setup for the app you are running in:
   `ruby ~/.reach/plugin/exe/reach setup --harness <claude-code | codex | antigravity | hermes>`
3. Read setup's output. Tell the student about any step it says they must do themselves (for example trusting rEach's hooks in Codex).
4. Setup prints a NEXT block only after a harness installed successfully. Your next message to the student must begin with the lines after "NEXT", copied exactly as printed, starting with "rEach is installed and ready." Do not summarise them, reword them or put anything before them. After them you may add setup's host steps (a new session, trusting hooks in Codex, or, in Hermes, the command setup prints for opening a course folder, such as `~/.reach/bin/reach work --harness hermes`; give it exactly as printed, since `reach` alone may not be on the student's PATH). Then read and follow the reach-assistant skill immediately.

## Claude Cowork

Your shell runs in a sandbox, not on the student's computer, so do not clone anything. Tell the student: open Customize › Plugins › Add › Add marketplace, paste this repository's link, add rEach, then start a new task. Stop here.

## Using Gemini?

Use the Antigravity app, Google's agent app, and pick Antigravity above. The Gemini app itself cannot run plugins.

## DeepSeek

rEach does not support DeepSeek Harness yet.
