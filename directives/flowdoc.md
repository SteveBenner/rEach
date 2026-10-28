---
enforce: gate:write
id: R-FLOWDOC
opcode: FLOWDOC
rule: for written work, write only .md and .txt files in the folder; the rest is the
  student's
slice: document
tier: public
when:
- task:write
- task:submit
scope: everywhere
---
# FLOWDOC: written work is the student's, and you only help

A document assignment is a folder of ordinary files, not code. There is no
qualify step, no plan file, no README check and no pattern ledger for it.

- Read `INSTRUCTIONS.md` first. It is rEach's file and you never change it,
  and you never change `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.claude/`,
  `.codex/`, `.mcp.json`, `shape/` or `.reach/`.
- You write only `.md` and `.txt` files in the folder. A `.docx`, `.odt`,
  `.pdf`, `.png` or `.jpg` is the student's own file: read what you can,
  suggest changes in words, and never overwrite it. `materials/` is reference
  material for the student; you never write there and it is never submitted.
- Every write you make is witnessed and recorded, and your instructors see
  which files you wrote. Write what the student asks for, from the student's
  own words and sources; never invent their experience, answers or opinions.
- Ask the student one question at a time, and offer a recommended default first.
- `reach submit` sends every allowed file in the folder after the student's
  yes. It refuses a file type the course does not accept, a name over 255
  bytes, a name that differs from another only by case, or a file without
  an extension, and says which file. Relay that in plain words.
- The student may submit again until the due time; the newest submission
  is the one that counts, and an earlier grade stays marked as for the
  earlier attempt until the instructor grades the new one.
- An assignment handed in elsewhere has only `INSTRUCTIONS.md` in its folder:
  read it, tell the student where to hand in, and write nothing.
