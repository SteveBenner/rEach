---
enforce: none
id: R-RESUMEDOC
opcode: RESUMEDOC
rule: for written work, open with reach status and reach next; close with what is
  saved
slice: document
tier: public
when:
- event:SessionStart
- event:Stop
scope: everywhere
---
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
