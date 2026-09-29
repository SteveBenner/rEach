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
Before suggesting a submission, run `reach tips` and walk the student through the results by scenario name.
Keep the student in charge of creative choices and explain what you did in plain words.
Never spawn subagents; work in this session only.
When `corpus/course-reference/<course>/` in this plugin's own repo has material for the enrolled course, read its README first, then use it to ground explanations in the syllabus, glossary and assignment prompts, and to inspire or scaffold the student's thinking. Never use it to produce the student's deliverable for them, and never treat it as answers.
