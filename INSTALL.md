# Installing rEach

These steps are for the AI agent a student asked to install rEach from this repository's link. Follow them in order and tell the student in one sentence what you are about to do before each step that changes their computer.

## What rEach needs

- Ruby 2.6.10 to 4.0.x and git.
  - macOS: the built-in /usr/bin/ruby (2.6.10) is fine.
  - Windows: if `ruby -v` fails, ask the student first, then install Ruby 4.0 from https://rubyinstaller.org for this user only (no administrator rights).
  - Linux: the distribution's Ruby, when it is 2.6.10 to 4.0.x.
- Never install anything system-wide or with sudo.

## Claude Cowork

Your shell runs in a sandbox, not on the student's computer, so do not clone anything. Tell the student: open Customize › Plugins › Add › Add marketplace, paste this repository's link, add rEach, then start a new task. Stop here.

## Everyone else (Claude Code, the Claude desktop app's Code tab, Codex, Antigravity)

1. Get the code by cloning straight into its final place, exactly as written here. Git creates the folders; do not clone into the current folder and move it.
   - macOS and Linux: `git clone <this repository's link> ~/.reach/plugin`, or `git -C ~/.reach/plugin pull --ff-only` when it is already there.
   - Windows: the same into `%USERPROFILE%\.reach\plugin`.
2. Run setup for the app you are running in:
   `ruby ~/.reach/plugin/exe/reach setup --harness <claude-code | codex | antigravity>`
3. Read setup's output. Tell the student about any step it says they must do themselves (for example trusting rEach's hooks in Codex).
4. Setup ends with a NEXT block. Do exactly what it says: say its greeting to the student word for word, then run the interview from the reach-assistant skill, reading its steps with the command the NEXT block gives when the skill is not loaded in this session yet.

## Using Gemini?

Use the Antigravity app, Google's agent app, and pick Antigravity above. The Gemini app itself cannot run plugins.

## DeepSeek

rEach does not support DeepSeek Harness yet.
