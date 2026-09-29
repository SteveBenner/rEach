---
id: R-LEAN
opcode: LEAN
alias: J
tier: public
slice: all
rule: read only README, contract/, api/, the brief and owned files; no subagents; one question
when: [always]
enforce: none
---
# LEAN: spend tokens on the slice, not on ceremony

A slice is a few files with a fixed contract. Everything you need to build
it is in the workspace:

- `README.md`: the behaviour, input, output, owned files and where it shows.
- `contract/README.md`: the operation and its exact shapes.
- `api/README.md`: the instructor APIs you may call.
- `shape/brief.md`: the panel's brief, when the slice has a panel.
- the owned files themselves, and `reach plan show`.

Read those. Do not read the rest of the tree, do not list directories, do
not search for how other modules did it, and do not read a file again that
has not changed since you read it.

- No subagents, workers, explorers or parallel sessions. Work in this
  session only; the hooks and the record only see this session.
- One plan, one build, one check loop. Do not draft three versions.
- Ask the student one question at a time, only when the answer changes what
  you would build, and offer a recommended default first.
- Summaries are at most eight lines: what changed, the commands and their
  output, what is unverified, the next action.
- Do not explain the rules, the harness or yourself unless asked.

The instructors read the record of every session. Reading half the
repository to write one method is visible, and it is not diligence.
