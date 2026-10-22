---
name: reach-uninstall
description: Use when the student asks to uninstall, remove or delete rEach, to clean up or start over without it, or says rEach is broken and they want it gone.
---
Removing rEach is one command, and the student decides. You never delete rEach's folders, edit Codex's or Claude's settings, or touch the student's work yourself.
Run `reach uninstall` (Codex: ask to run it outside the sandbox from the start, because it removes things outside the reach-work folder). rEach prints a question that lists what it will remove and what stays. Give it to the student word for word and stop. Never answer it yourself: only the student's own typed yes counts, and `--yes` is refused while rEach is enrolled and working.
After the student's yes, in their next message, run the same command again. rEach tells the course server, removes itself and prints a closing text: give it to the student word for word. If it lists anything under "left for you", walk the student through each item. Then tell them to start a new chat in their AI app.
Run it from a chat inside the reach-work folder, where rEach's hooks can hear the answer. If rEach says it cannot take a yes here, open that folder in the app and ask again, or have the student type `reach uninstall` in a terminal.
Add a choice only when the student asks for it: `--purge-checkpoint-mirror` (also delete the extra copies of their work files, which stay otherwise), `--no-receipts-copy`, `--delete-hermes-profile`, `--keep-workspace-files`, `--no-teach`.
When `reach` will not start, or the student never finished enrolling, follow UNINSTALL.md in the rEach repository: ask the student with your own question tool, then run the uninstall script with `--yes` from a folder outside reach-work.
Their work in reach-work (deliverables, extracurricular and everything else the student wrote) is never removed, and a copy of their receipts is saved to Downloads first. If they installed rEach with rplugin, also run `rplugin uninstall reach` afterwards.
