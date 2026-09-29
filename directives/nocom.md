---
id: R-NOCOM
opcode: NOCOM
alias: E
tier: public
slice: all
rule: write no comments; the plan and README carry the why, the code carries the what
when: [path:**/*.rb, path:**/*.svelte]
enforce: check:CK-COMMENT
---
# NOCOM: no comments in code

Do not write comments. Not explanatory comments, not section banners, not
doc comments, not TODO markers, not a note for the reader. The plan
(`reach plan show`), the README and the contract carry the why; the code
carries the what; nothing goes in between.

The only comment-shaped lines that survive are the two Reach itself reads:

- Ruby: line 1 `# frozen_string_literal: true` and line 2 `# reach <cutout> <slice>`
- Svelte: line 1 `<!-- reach <cutout> <slice> -->`

Keep those two lines exactly as Reach wrote them and write no others. No
`# ...` anywhere else in a `.rb` file, no `<!-- -->`, `//` or `/* */`
anywhere else in a `.svelte` file, and no trailing `# note` on a line of
code.

If a name is not clear enough to need no comment, choose a better name.
If a step is not obvious, make it a small private method whose name says
what it does.

`reach check` reports CK-COMMENT with the line for every comment it finds.
