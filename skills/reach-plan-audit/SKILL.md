---
name: reach-plan-audit
description: Use right after every reach plan save, and whenever reach qualify stops at plan_audit. A second, independent pass that checks the saved plan against the assignment's released constraints before any code is written or qualified.
---
The plan audit is a second pass over the saved plan. Its only question: can this plan, built exactly as written, satisfy every constraint the course released for this slice? It judges the plan, not the student, and it never writes code.

**Run it as a separate pass.** If this app can start a subagent, start a fresh one and give it only these instructions and the packet, then record with `--auditor subagent`. If it cannot, set aside how you wrote the plan, work only from the packet, and record with `--auditor separate_pass`. Do not defend the plan you wrote; look for where it breaks.

1. **Get the packet.** `reach plan audit packet` (or the reach_plan tool with action audit_packet). It holds the plan and the released constraints: the behaviour, the operation's input and output, the contract, the instructor APIs, the required APIs, the slice's constraints, the graded scenario names and the owned files. Read nothing else. The course reference, other slices and anything outside the packet are not part of this audit, and you never look for or guess at expected answers.
2. **Check every constraint against the plan**, one by one:
   - **Required APIs.** For each required API, a plan step calls it and uses what it returns. A step that works out by itself what a required API returns (its own formula, weights, coefficients, lookup or rule) breaks the constraint, even when the student asked for it.
   - **Behaviour.** The plan does what the behaviour sentence says, in its words. "Using the supplied formula" means calling the formula API, not writing a formula.
   - **Operation.** The plan's input and output match the operation's fields, names and types.
   - **Contract and constraints.** No step contradicts a contract line or a listed constraint.
   - **Graded scenarios.** Every graded scenario name appears in the plan's scenarios exactly as written.
   - **Owned files.** Nothing in the plan needs a file outside the owned files or an API outside the instructor APIs.
   - **Edge cases.** Each edge case is possible under the contract. One that cannot happen, or that contradicts a constraint, is a finding.
3. **Decide.** Pass only when every check holds. One broken constraint fails the plan.
4. **Record it.**
   - Pass: `reach plan audit record --verdict pass --reason "<one line on why it holds>" --auditor <subagent|separate_pass>`
   - Fail: `reach plan audit record --verdict fail --finding "<constraint, quoted from the packet> | <the plan item that breaks it> | <what goes wrong, in plain words>" --auditor <subagent|separate_pass>`, with one `--finding` per broken constraint.
   The verdict is bound to this exact plan and these constraints. Any change to the plan's behaviour, input, output, steps, edge cases or scenarios, or a new course package, needs a new audit. Progress notes do not.
5. **After a fail, go back to the student before any code.** Tell them in plain words, without code, what the course requires and how the plan differs. For example: "The course gives this part a ready-made scoring formula, and the plan works out its own score instead, so the course's checks will not accept it." When the difference comes from something the student said, keep their reasoning: write it in their words in the README.md section where they explain their choices. Then correct the plan to the constraint with `reach plan save`, read it back, get their yes, and run this audit again. The released constraints win over the plan. They also win over a student's preference; raise a hand only if the student disagrees with the course's rule itself.
6. **After a pass**, continue the reach-feature flow at step 4.

`reach qualify` checks for a passing audit of the current plan before anything else. When the course enforces it, qualify will not start without one, and that refusal does not count as a try.
