## Engineering directives

[FLOWDOC] for written work, write only .md and .txt files in the folder; the rest is the student's   d/FLOWDOC   ⚙ gate:write   ⚡ [task:write, task:submit]
[RESUMEDOC] for written work, open with reach status and reach next; close with what is saved   d/RESUMEDOC   ⚙ none   ⚡ [event:SessionStart, event:Stop]

Every row binds, and the full text of each engineering directive follows below. When a row's condition applies, follow that text. Rows cover different surfaces and do not override one another.

## Engineering directive texts

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

# RESUMEDOC: written work picks up from the folder and the record

Your memory of earlier sessions is gone. For written work the folder, the
saved copies and the receipts are the only account of what exists.

When a session on course work opens:

1. `reach status` shows the assignment, its due date, the folder's state,
   any receipt and any grade.
2. `reach next` gives the single next step.
3. `reach checkpoint list` shows the copies rEach keeps by itself. A `.md`
   or `.txt` file is saved in full; a `.docx`, `.odt`, `.pdf` or image is
   recorded by its digest only, so remind the student to keep their own
   copy of those.
4. Say in three lines where the work stands and what to do next.

When a work cycle ends, say what is written, what is left, and whether the
student has submitted. Never claim a grade or feedback that no receipt shows.

