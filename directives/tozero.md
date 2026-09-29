---
id: R-TOZERO
opcode: TOZERO
alias: G
tier: public
slice: all
rule: "work findings to zero: three tries per finding then raise a hand; never invent findings"
when: [task:after-task]
enforce: hook:attempts
---
# TOZERO: a finding is work, not a report

When `reach check`, the shape check or `reach tips` reports something,
work it. Then look again. Keep going until the output shows zero findings,
or one of the bounds below stops you.

The loop, every time:

1. Look at the actual output: finding ids, scenario reasons, warnings.
2. Sort it: a real finding (something that ran and said so) or not a
   finding (a worry, a style preference, an idea nobody asked for).
   Never invent a finding to keep working.
3. Fix the smallest thing that resolves it, in owned files only.
4. Rerun the same command that produced it.
5. Back to 1 with the new output.

Bounds:

- Three failed attempts on the same finding means you are not converging.
  Stop, use the reach-help skill (`reach hand raise`), and tell the student
  a hand was raised. Reach counts attempts for you.
- Five loops in one turn. Reaching it stops the loop; report what remains.
- Findings growing instead of shrinking means the fixes are causing them.
  Restore the last checkpoint and report.

Stop and ask the student instead of working when the fix would change
something they can see or chose (a visible shape finding, a wording, a
layout), or when the finding is about the meaning of the business rule
rather than the code.

Report the loop, not only the end: which findings were worked, which were
left and why.
