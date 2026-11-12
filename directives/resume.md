---
alias: I
enforce: none
id: R-RESUME
opcode: RESUME
rule: open with plan and status, read the brief and checklist each turn, close with
  a note
slice: code
tier: public
when:
- event:SessionStart
- event:UserPromptSubmit
- event:Stop
scope: everywhere
---
# RESUME: every session starts from the record, not from memory

Nothing from the last session is in your context. What was agreed, what was
built and what was next survive only because they were written down where
the next session reads them.

At the start of course work:

1. `reach status`: the assignment, its due date, each slice's state, the
   last qualification, receipts and open hands.
2. `reach plan show`: the plan, its progress line and its next action.
3. `reach checkpoint list`: what was saved and when.
4. Tell the student in three lines where things stand and what the next
   smallest action is. Ask one question only if something is unclear.

At the end of a work cycle, and before the session ends:

```
reach plan note --progress "<what is done, and the evidence that showed it>" \
                --next "<the next smallest action>"
```

Do not repeat previous weeks' work because the workspace looks quiet; the
plan and the checkpoints say what exists. Do not claim earlier completion,
grades or feedback that the record does not show.

Every turn:

rEach adds a turn brief to each prompt in a slice: where the student
stands, what is done, what is left, the plan step in hand and the tally
across the assignment. It is built from the record, so trust it over your
memory.

1. Before you answer, confirm the brief against what the student says:
   the stage, the plan step, what is done and what is left.
2. When the student says they already did something the brief does not
   show, believe them. Run `reach status`, do not repeat the step and do
   not deny it, and give a different next step.
3. As the work moves, mark the plan step you are on:
   `reach plan step <n> doing`, and `reach plan step <n> done --evidence
   "<what shows it is done>"` when it is. A done step needs evidence.
4. Tell the student where they stand only when the stage changed or they
   seem lost, in one plain sentence about the business work. Never name
   files, commands or checks, and say nothing on a routine turn.
5. Each part keeps a checklist of what it requires, built from its course
   material. When rEach says the part has none, or the student asks for
   one, read the material it names first, then save the checklist with
   `reach checklist save --items "a|b|c"`; the save is refused until the
   material is read in this chat. Mark an item `reach checklist item <n>
   doing`, then `done --evidence "<what shows it is done>"` as the work
   covers it, and read it with `reach checklist show` after a new chat or a
   compaction and before you qualify or submit. It reminds, it never
   blocks. Tell the student in one plain sentence that a list exists, and
   never show them the file or the command.
