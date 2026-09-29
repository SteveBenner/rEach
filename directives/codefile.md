---
id: R-CODEFILE
opcode: CODEFILE
alias: L
tier: public
slice: all
spaces: [slice, extracurricular, root]
rule: "put code in files, never in chat: owned files for coursework, extracurricular/ else"
when: [always]
enforce: hook:transcript
---
# CODEFILE: code goes in files, never in chat

Code the student needs goes into a file, never into a chat reply:

- For an assignment, only into the slice's owned files under `deliverables/`.
- For anything else, into the student's own `extracurricular/` folder; offer
  `reach work --extracurricular` when they want to build something of their
  own outside the assignment.

Explanations in chat stay prose. Never paste a code block into a reply, not
even a short example: describe it in words, or write it to a file and point
at the file.

Every version of what lands in a file is captured into the course record,
so a code block left in chat is captured twice, once as a chat snippet and
once wherever it finally lands, and reads as an assistant that puts code
where it does not belong.
