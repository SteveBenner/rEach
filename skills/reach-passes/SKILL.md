---
name: reach-passes
description: Use at the three points where the student's input becomes a solution - the plan, the scenarios and the code - and whenever reach qualify stops at passes or patterns. Writes several candidate passes through different lenses and lets rEach, not you, choose the one the evidence supports.
---
A pass is one complete attempt at one point, written through one lens. You write the candidates; rEach scores each one from evidence only (the checks, the coverage of the graded names, the local runs, the starting copy, the pattern ledger, the port probe and the contract) and installs the best. What you think of a candidate carries no weight, and a candidate is never compared with another, only with the system.

The student cares about the answer, not the machinery. Keep this to a sentence or two for them, and never ask them to read a score.

**The points, in this order.** `plan`, then `scenarios`, then `code`. The winning plan feeds the scenario passes, and the winning scenarios feed the code passes. Run the plan audit (reach-plan-audit) after the plan point, as the reach-feature flow says.

For each point:

1. **Get the packet.** `reach passes packet <point>` (or the reach_passes_packet tool). It holds the released constraints, the lens list with a focus line for each, the ledger entries for this point (known patterns that do not work: read them first and write nothing they describe), the winning upstream candidate, and where each candidate is written.
2. **Write the candidates.** The packet names how many (qualify.passes.count, at most 8) and which lenses. If this app can start subagents, start one fresh subagent per lens and give it only the packet, its own lens and its own folder. Otherwise write the passes one after another as separate passes: set aside the earlier ones and work only from the packet and your lens. Each pass writes only under `.reach/passes/<point>/<n>/`, mirroring the paths it would change: `plan.yml` for the plan point (the same fields as reach plan save), the qualify features and step files for scenarios, the owned files and the qualify files for code. A pass never writes anywhere else, never reads another pass's folder, and never looks for or guesses at expected answers.
3. **Score.** `reach passes score <point>` (or reach_passes_score). It runs each candidate's scenarios, so it takes a few minutes: tell the student it is working and that closing the app stops it. Read the result: a candidate with a hard zero was ruled out and the reason says why.
4. **Pick.** `reach passes pick <point>` (or reach_passes_pick) installs the highest-confidence candidate and records why. If every candidate was ruled out, fix what the hard zeros name and write new candidates. If the pick says low confidence, tell the student in plain words that this is the best of the candidates but is not well supported yet and what you will check next, before you qualify.
5. **Tell the student** which approach was chosen and which known problem it avoided, in a sentence, using the ledger's wording rather than a pattern id.

`reach passes status` shows where each point stands. After a pick, edit the installed files normally; run the points again only when rEach says the constraints or the upstream pick changed.

`reach qualify` checks for a current pick at each point and for ledger findings. When the course enforces them, qualify will not start without them, and that refusal does not count as a try. After three refusals in a row rEach asks the instructor to look; tell the student help is on the way and keep working with them.
