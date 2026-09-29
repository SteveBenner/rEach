---
name: reach-course
description: Use in every course workspace. How to work on a student's slice under the instructors' rules.
---
Read AGENTS.md (the same rules are in CLAUDE.md and GEMINI.md), README.md, contract/README.md, api/README.md and shape/brief.md first, and nothing else in the tree.
AGENTS.md ends with a table of directives: one row per rule with its opcode, its condition and `reach directive <OPCODE>`. When a row's condition applies, run that command (or the reach_directive tool) and follow the full text.
Work only in the owned files listed in AGENTS.md, and in qualify/features and qualify/step_definitions for your own scenarios.
Whenever you write code, follow a flow (the FLOW directive): new or changed behaviour, the reach-feature skill; something failing or wrong, the reach-bug skill. Saving or going back: the reach-checkpoint skill. Never run git.
After each change, run `reach check --format agent` (it includes the shape check) and handle each finding by its class:
- invisible: fix it now without interrupting the student;
- visible: stop, explain in plain words, and offer alternatives, starting with the student's idea adjusted to comply.
Reach counts failed qualifications for you (the TOZERO directive): pass on the notices it prints, and after the third it has already asked the instructors for help; ask the student before trying again.
For a panel slice, load the design-taste-frontend skill and read shape/brief.md before writing any markup.
Before suggesting a submission, `reach qualify` must pass on the files as they are (the QUALIFY directive). Waiting for the course server is not a pass. The student never sees scenarios, code or command output: tell them in business terms what their part of the system can now be relied on to do.
Ask the student for meaningful business choices: the user, decision, information flow, expected behavior and their contribution account. Then implement all permitted code yourself, read each owned source file before changing it, and prepare the editable README from what the student actually says. Never invent personal reflection or contributions.
Never spawn subagents; work in this session only.
When the student asks about the syllabus, glossary or assignment prompts, ground the explanation with `reach reference` (or the reach_reference tool): `reach reference list` shows the files, `reach reference show <path>` prints one, `reach reference search <words>` finds the files that contain all the words, and `reach reference links` lists the textbook and other links. The material is decrypted in memory and never written to disk; do not copy it into files. If it reports locked, tell the student to run `reach sync`. Do not reveal reference answers or material outside the student's released contract; the released contract wins over the reference.
