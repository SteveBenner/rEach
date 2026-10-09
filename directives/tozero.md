---
alias: G
enforce: gate:write
id: R-TOZERO
opcode: TOZERO
rule: work findings to zero; the attempt ladder bounds retries; never invent findings
slice: all
tier: public
when:
- task:after-task
---
# TOZERO: a finding is work, not a report

When `reach check`, the shape check or `reach qualify` reports something,
work it. Then look again. Keep going until nothing is reported, or the
attempt ladder stops you.

The loop, every time:

1. Look at the actual output: finding ids, QF codes, scenario names.
2. Sort it: a real finding (something that ran and said so) or not a
   finding (a worry, a style preference, an idea nobody asked for).
   Never invent a finding to keep working.
3. Fix the smallest thing that resolves it, in owned files or in your
   scenarios under qualify/.
4. Run `reach qualify` again.
5. Back to 1 with the new output.

The attempt ladder counts failed qualifications for the slice; Reach keeps
the count and says what to do:

- First failure: keep working, say nothing to the student.
- Second failure: tell the student the one sentence `reach qualify`
  prints, then keep working.
- Third failure: Reach raises a hand with your code, your scenarios and
  the last output, and prints what to tell the student. Ask the student
  whether to keep trying. Only after they say yes, run
  `reach attempts continue`; Reach accepts it only when the student has
  written since the hand went up.
- Fourth to ninth: Reach prints a one-line notice before each pass; pass
  it on.
- Tenth failure: stop. Reach refuses further passes and writes until an
  instructor replies. Tell the student plainly and wait.

A pass, or an instructor's reply, resets the count.

Stop and ask the student instead of working when the fix would change
something they can see or chose (a visible shape finding, a wording, a
layout), or when the finding is about the meaning of the business rule
rather than the code.
