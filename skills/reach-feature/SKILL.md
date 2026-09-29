---
name: reach-feature
description: Use when the student wants new or changed behaviour in their slice, or to build or continue this week's step. The feature flow for one slice, end to end, without git.
---
The feature flow for one slice. Work the steps in order; do not skip or reorder them. Reach does not do version control yet: never run git or start a repository, change files by overwriting them in place, and use `reach checkpoint` as the history.

1. **Read the slice.** README.md, contract/README.md, api/README.md, the `qualify` part of api/slice-api.json, shape/brief.md, then `reach plan show`, `reach status` and `reach qualify --list`. Read nothing else.
2. **Settle the behaviour with the student, in their terms.** Ask about the business user, the decision, the information and the expected result for a case they know. Never ask them about code. Save the plan: `reach plan save --behaviour "..." --input "..." --output "..." --steps "a|b|c" --edge-cases "a|b" --scenarios "<every graded name>|<your edge cases>" --evidence "reach qualify"`. Read the plan back in plain words and wait for their yes.
3. **Audit the plan.** Check it against the contract's input and output and against every graded name from `reach qualify --list`. Anything that does not fit is a question for the student or a correction to the plan, now, before any code.
4. **Choose the approach.** Decide how to build it, on your own; the student does not see this step. Panel slice: load the design-taste-frontend skill and infer the direction from shape/brief.md first.
5. **Write the scenarios first**, under qualify/features with steps under qualify/step_definitions (the QUALIFY directive): one scenario per graded name with exactly that name and the slice's tag, your edge cases after them, ports faked with `grokit_fake`. They must fail on the starting copy.
6. **Implement** in the owned files, reading each before you overwrite it. Keep the first two lines of every file exactly as rEach wrote them. Update the editable README only with what the student actually said.
7. `reach check --format agent` until it prints nothing.
8. `reach qualify`, and follow what it prints (the TOZERO directive): pass on any notice to the student, and stop when it says to.
9. `reach checkpoint save --note "<what works now>"`.
10. **Report to the student** in at most six plain lines: what the business can now rely on, one case in their words, and what is not yet covered. No code, no scenario names, no command output. Then `reach plan note --progress "..." --next "..."`.
11. **Offer to submit** with the reach-submit skill once `reach qualify` passed. Never submit without the student's yes.
