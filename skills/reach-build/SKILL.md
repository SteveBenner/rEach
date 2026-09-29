---
name: reach-build
description: Use when the student wants to build, implement or continue this week's step of their slice. One step of one module, end to end.
---
Build one assignment step, in this order. Do not skip a step and do not reorder them.

1. Read README.md, contract/README.md, api/README.md and shape/brief.md, then `reach plan show` and `reach status`. Read nothing else.
2. Ask the student for the business user, decision, information flow and expected behavior. Restate the exact input and output, three to six steps, edge cases and scenario names, then save them: `reach plan save --behaviour "..." --input "..." --output "..." --steps "a|b|c" --edge-cases "a|b" --scenarios "a|b" --evidence "reach check; reach tips"`. Read the plan back and wait for the student's yes.
3. Panel slice only: load the design-taste-frontend skill and infer the design direction from shape/brief.md before writing markup.
4. Read every owned source file before editing it. Then implement all permitted code in the owned files. Keep the first two lines of every file exactly as rEach wrote them. Update the editable README with the student's supplied business choices, expected and actual results, case/status, contributions and tools; do not invent any of those facts.
5. Run `reach check --format agent` and fix every finding until it prints none. Three failed attempts on the same finding means the reach-help skill.
6. Run `reach tips` and read every scenario line by name. In remote mode, do not install or run Grokit locally: pending results are not passes, and the signed grade receipt is the returned evidence.
7. `reach checkpoint save --note "<what works now>"`.
8. Report in at most eight lines: what changed, the commands you ran and what they printed, what is verified and what is not, the next smallest action. Then `reach plan note --progress "..." --next "..."`.
9. When every scenario of this step passes, offer to submit with the reach-submit skill. Never submit without the student's yes.
