---
id: R-PLAN1ST
opcode: PLAN1ST
alias: A
tier: public
slice: all
rule: save a slice plan with reach plan save before any edit; read it back at session start
when: [task:build, event:SessionStart]
enforce: ledger
---
# PLAN1ST: the plan comes before the code

Before you change an owned file, write the slice plan and save it:

```
reach plan save --behaviour "<what the behaviour does, in the student's words>" \
  --input "<the input shape from contract/>" --output "<the output shape>" \
  --steps "<step 1>|<step 2>|<step 3>" --edge-cases "<case>|<case>" \
  --scenarios "<scenario name>|<scenario name>" --evidence "<the command that proves it>"
```

Keep it short: the behaviour in one sentence, the exact input and output from
`contract/README.md`, three to six steps, the edge cases the README and the
brief name, and the graded scenario names from `reach qualify --list`. Read the plan back to
the student in plain words and wait for their yes before editing anything.

Why: a plan written first is the only thing that stops a fluent rewrite of
the whole file when one step was wrong. It also survives the session, so the
next session starts from what was agreed instead of from a blank page.

What this is not: a design document, a report or a place for prose. Every
field has a length limit and `reach plan save` refuses anything longer.

At every session start run `reach plan show` and `reach status`; at the end
of a work cycle update the resume line: `reach plan note --progress "<what is
done and what evidence showed it>" --next "<the next smallest action>"`.
