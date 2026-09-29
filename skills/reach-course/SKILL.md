---
name: reach-course
description: Use in every course workspace. How to work on a student's slice under the instructors' rules.
---
Read AGENTS.md (the same rules are in CLAUDE.md and GEMINI.md), README.md, contract/README.md, api/README.md and shape/brief.md first, and nothing else in the tree.
AGENTS.md ends with a table of directives: one row per rule with its opcode, its condition and `reach directive <OPCODE>`. When a row's condition applies, run that command (or the reach_directive tool) and follow the full text.
Work only in the owned files listed in AGENTS.md.
Building a step: use the reach-build skill. Fixing a failing scenario or finding: use the reach-fix skill. Saving or going back: use the reach-checkpoint skill.
After each change, run `reach check --format agent` (it includes the shape check) and handle each finding by its class:
- invisible: fix it now without interrupting the student;
- visible: stop, explain in plain words, and offer alternatives, starting with the student's idea adjusted to comply.
Count your attempts; after three failed attempts on one finding, use the reach-help skill.
For a panel slice, load the design-taste-frontend skill and read shape/brief.md before writing any markup.
Before suggesting a submission, run `reach tips` and walk the student through the results by scenario name. In remote acceptance mode, pending means no signed result has returned; submit after local checks, then wait for the grade receipt and correct any returned failure.
Ask the student for meaningful business choices: the user, decision, information flow, expected behavior and their contribution account. Then implement all permitted code yourself, read each owned source file before changing it, and prepare the editable README from what the student actually says. Never invent personal reflection or contributions.
Never spawn subagents; work in this session only.
When the student asks about the syllabus, glossary or assignment prompts, ground the explanation with `reach reference` (or the reach_reference tool): `reach reference list` shows the files, `reach reference show <path>` prints one, `reach reference search <words>` finds the files that contain all the words, and `reach reference links` lists the textbook and other links. The material is decrypted in memory and never written to disk; do not copy it into files. If it reports locked, tell the student to run `reach sync`. Do not reveal reference answers or material outside the student's released contract; the released contract wins over the reference.
