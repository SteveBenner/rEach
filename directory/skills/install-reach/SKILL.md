---
name: install-reach
description: Use when the student asks to install, set up, reinstall or repair rEach, the academic assistant for a Teach-run course. Installs rEach from its public GitHub repository by following its INSTALL.md.
---

# Install rEach

The student wants rEach, their academic assistant for a course run on Teach. This skill does one thing: install the real rEach on the student's computer. rEach's own instructions are the authority; follow them, never improvise another way.

## Before anything else

1. Check that you can run shell commands on the student's computer.
   - In ChatGPT on the web or the ChatGPT app without a terminal, you cannot. Tell the student: "rEach installs from the Codex app. Open Codex, start a new chat, and send: Install rEach." Stop here.
2. Check whether rEach is already installed: `~/.reach/plugin/exe/reach` exists (Windows: `%USERPROFILE%\.reach\plugin\exe\reach`). If it does, do not reinstall. Run `ruby ~/.reach/plugin/exe/reach update run --apply` (Windows PowerShell: `ruby "$env:USERPROFILE\.reach\plugin\exe\reach" update run --apply`) and tell the student the result in plain words.
3. Codex runs commands in a sandbox that blocks the network and writes outside the chat's folder, so the install can only fail inside it. Before running anything, tell the student in one short message: open the permissions menu under the message box (it may read "Ask for approval" or "Default permissions"), choose "Full access", and send their request again. If the app shows the error "helper_unknown_error" or says the shell failed to start, give the same instruction: Codex's sandbox did not start, and Full access runs without it.

## Install

Read https://raw.githubusercontent.com/SteveBenner/rEach/main/INSTALL.md and follow its section "Claude Code, Codex, Antigravity and Hermes" exactly, with `codex` as the harness. It gives one command for macOS and Linux, one for Windows PowerShell, and one for Windows without Ruby. Run the one that fits as a single shell call.

- Do not download a release, tag or archive yourself, and do not search GitHub. The releases named "Reach runtime" are Ruby kits, not rEach.
- Never install anything system-wide or with sudo or administrator rights.
- If a step fails with "access denied" on `.reach`, the sandbox is still on: repeat the Full access instruction above and stop. Do not try another folder.

## After the install

Follow INSTALL.md's steps after the command: read setup's output, then begin your next message with the lines after "NEXT", copied exactly as printed. Tell the student to trust rEach's hooks when setup says so (Settings > Hooks in the Codex app), then to start a new chat. rEach greets them there and asks for the course passkey their instructor gave them. The student can switch permissions back from Full access once rEach is set up.
