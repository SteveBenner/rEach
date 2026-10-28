# Uninstalling rEach

These steps are for the AI agent a student asked to remove rEach from their computer. Follow them in order and tell the student in one sentence what you are about to do before each step that changes their computer.

## What it removes and what it keeps

It removes rEach: its two folders (`~/reach-work/.reach-home` and the older `~/.reach`, whichever exist), its background course check, its entry in Claude Code, Codex, Antigravity and Hermes, the settings files rEach added inside the student's work folders, and the read-only lock it put on delivered files. It also tells the student's course server that this copy of rEach is gone, when rEach itself runs the uninstall and the student answered yes in a chat.

It never touches the student's work. Everything else in `~/reach-work` stays exactly as it is: `deliverables`, `extracurricular`, older course folders and any file the student wrote. A copy of the student's receipts and grade records is saved first in `~/Downloads/rEach-receipts-<date>`. The extra copies rEach keeps of work in progress (rEach's checkpoint mirror, outside `reach-work`) stay unless the student asks for them to go. So does rEach's memory of the student: the `~/reach-work/.reach-brain` folder and the copy of what the student typed under `~/.local/state/rplugin/reach` (the rplugin state folder), so a later install finds it again; `reach reclaim` brings older memory back.

Never delete any of this yourself with `rm`, never edit Codex's or Claude's settings by hand, and never remove `reach-work`.

## Which section is yours

Use "Claude Code, Codex, Antigravity and Hermes" below whenever you can run shell commands for the student: Claude Code in a terminal, the Claude desktop app's Code tab, VS Code, Codex, Antigravity or Hermes Agent. Use "Claude Cowork" only when you are the Claude desktop app's Cowork mode.

## Claude Code, Codex, Antigravity and Hermes

1. Run rEach's own command. If your app runs commands in a sandbox (Codex does), ask to run this one command outside the sandbox from the start: it removes things outside the `reach-work` folder, so inside the sandbox it can only fail. If you cannot run it outside the sandbox, tell the student, in one short message, to open the permissions menu under the message box, choose "Full access", and send their request again.
   - macOS and Linux:
     ```sh
     ruby ~/reach-work/.reach-home/bin/reach uninstall
     ```
   - Windows PowerShell:
     ```powershell
     ruby "$env:USERPROFILE\reach-work\.reach-home\bin\reach" uninstall
     ```
   When `reach` is on the student's PATH, `reach uninstall` is the same command. Run it from a chat inside the `reach-work` folder, where rEach's hooks can hear the student's answer.
2. rEach prints a question that lists what it will remove and what stays. Give it to the student word for word and stop. Only the student's own typed yes counts: never answer it yourself, and never add `--yes` to this command while rEach is enrolled and working (it refuses).
3. After the student's yes in their next message, run the same command again. rEach tells the course server, removes itself and prints a closing text. Give that text to the student word for word. If it lists anything under "left for you", walk the student through each item.
4. Tell the student to start a new chat in their AI app so it stops looking for rEach. If they installed rEach with rplugin, also run `rplugin uninstall reach`.

Choices the student can ask for, added to the same command: `--purge-checkpoint-mirror` also deletes the extra copies of their work files, `--purge-microbrain` also deletes rEach's memory of them (`.reach-brain` and the saved copy of what they typed), `--no-receipts-copy` skips the receipts copy, `--delete-hermes-profile` also deletes the Hermes profile named reach, `--keep-workspace-files` leaves the settings files in the work folders, and `--no-teach` does not tell the course server. Add one only when the student asks for it.

### When rEach cannot run, or cannot take a yes

If `reach uninstall` fails to start, says it cannot take the student's yes here, or the student never finished enrolling, use the uninstall script instead. Ask the student the question yourself with your question tool: "This removes rEach from this computer, including its folders, its background check, its entries in your AI apps, and the rEach settings files inside your work folders. Your work in reach-work is not touched. Remove rEach?" Run the commands below from a folder that is not inside `reach-work`. Only after the student's yes, add `--yes`. The script does not tell the course server and cannot edit Codex's own settings file, so it prints those as "left for you".

- macOS and Linux:
  ```sh
  d="$(mktemp -d)" && curl -fL --retry 3 --connect-timeout 10 https://raw.githubusercontent.com/SteveBenner/rEach/stable/scripts/reach-uninstall -o "$d/reach-uninstall" && ruby "$d/reach-uninstall" apply --yes
  ```
- Windows PowerShell:
  ```powershell
  $d = Join-Path $env:TEMP ("reach-uninstall-" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force $d | Out-Null; curl.exe -fL --retry 3 --connect-timeout 10 https://raw.githubusercontent.com/SteveBenner/rEach/stable/scripts/reach-uninstall -o "$d\reach-uninstall"; if ($LASTEXITCODE -eq 0) { $r = (Get-Command ruby -ErrorAction SilentlyContinue).Source; if (-not $r) { $r = (Get-ChildItem (Join-Path $env:USERPROFILE 'reach-work\.reach-home\runtime'), (Join-Path $env:USERPROFILE '.reach\runtime') -Recurse -Filter ruby.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }; if ($r) { & $r "$d\reach-uninstall" apply --yes } else { Write-Output 'Ruby was not found on this computer, so the uninstall script cannot run. Tell your instructor.' } }
  ```

Without `--yes`, `apply` prints what it would remove and exits without changing anything; `plan` does the same and never changes anything. The script accepts the same choices as the command above, except `--no-teach`.

Set `REACH_UNINSTALL_KILL_SWITCH=1` to stop both the command and the script from removing anything.

## Claude Cowork

Your shell runs in a sandbox, not on the student's computer, so do not remove anything yourself. Tell the student: open Customize › Plugins, find rEach and remove it. Stop here.

## After it is done

The student can install rEach again later by following `INSTALL.md`. They enroll in their course again; their instructor keeps their enrollment, submissions and grades, and no instructor step is needed to enroll again.
