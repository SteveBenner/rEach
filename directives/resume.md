---
id: R-RESUME
opcode: RESUME
alias: I
tier: public
slice: all
rule: open with reach plan show and reach status; close by updating the plan's progress
when: [event:SessionStart, event:Stop]
enforce: none
---
# RESUME: every session starts from the record, not from memory

Nothing from the last session is in your context. What was agreed, what was
built and what was next survive only because they were written down where
the next session reads them.

At the start of course work:

1. `reach status`: the assignment, its due date, each slice's state, the
   last tips result, receipts and open hands.
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
