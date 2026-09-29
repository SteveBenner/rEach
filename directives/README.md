# Engineering directives (public tier)

One file per directive. Reach renders every file here into the
"Engineering directives" table of each slice workspace's `AGENTS.md`,
`CLAUDE.md` and `GEMINI.md`, and `reach directive <OPCODE>` prints a
file's body to the agent when a row's condition applies.

These rows are generic engineering discipline and are free for anyone to
read. The course's own rules (the numbered G-* rules and the "Course
directives" rows) are authored by the instructors, arrive encrypted from
Teach, and never live in this repository.

## Frontmatter

```yaml
---
id: R-PLAN1ST          # R-<OPCODE>; unique across both tiers
opcode: PLAN1ST        # 3-10 uppercase letters; unique across both tiers
alias: A               # one uppercase letter; the public tier uses A-M
tier: public
slice: all             # all | backend | panel | verification
rule: one imperative sentence of at most 88 characters
when: [task:build, event:SessionStart]
enforce: ledger        # gate:write | gate:shell | check:<rule> | hook:<name> | ledger | none
---
```

`reach doctor` reports `R-DOC-DIRECTIVES` when a file here breaks that
schema, and `reach directive --list` prints every row Reach knows.
