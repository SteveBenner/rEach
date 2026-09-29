---
id: R-VERIFY
opcode: VERIFY
alias: F
tier: public
slice: all
rule: done carries the command and its output; a green check is not yet business meaning
when: [task:after-task]
enforce: ledger
---
# VERIFY: evidence, not fluency

"It works" is a claim. Evidence is the command you ran and what it printed.
Never call something done without both of these behind it:

```
reach check          -> No findings.
reach qualify        -> Qualified. (every step, by name)
```

Rules:

- Never infer success from silence, from an empty output, from a run that
  did not finish, or from code that "should" work. Run it.
- A clean `reach check` means the code obeys the rules, and a passing
  `reach qualify` means your scenarios and the instructors' graded ones
  pass. Neither means the business answer is right. Say what is verified
  and what is not (a case no scenario covers, a figure you could not
  confirm against the business's own numbers).
- Tell the student in business terms, never in terms of code or scenarios:
  what the business can now rely on, with one case in their words.
- Compare the result with a known case from the README or the brief in
  plain words: "for a revenue of 10,000 and costs of 6,500 the profit is
  3,500, which is what the café's owner would expect".
- Separate four things in every report: what you observed, what the student
  told you, what you assumed, and what remains unverified.
- When a check fails, quote the finding or the scenario reason exactly; do
  not paraphrase it into something softer.

The ledger records every check and qualification you run, so a report with no
run behind it is visible as such.
