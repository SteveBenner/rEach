---
name: reach-reclaim
description: Use when the student asks to bring back, find or recover their older memory, notes or work from an earlier rEach install, a set-aside folder or another reach-work folder, or when rEach says it found older memory or folders it can bring back.
---
Bringing things back is one command, and the student decides. You never copy, move or delete rEach's folders or the student's work yourself.
Run `reach reclaim` (or the `reach_reclaim` tool). rEach lists what it found: memory that carries this student's ID, course folders whose rules files and settings need putting back, and anything left alone because it belongs to someone else or has no owner on record. It ends with a question. Give the whole text to the student word for word and stop. Never answer it yourself: only the student's own typed yes counts.
After the student's yes, in their next message, run the same command again. rEach acts once and prints what it did: give it to the student word for word.
- Memory is merged into what the student has now; nothing they have now is overwritten, and an old memory folder is emptied only after everything in it is safely merged.
- Memory saved before the student enrolled is never taken on its own. If the student says it is theirs, run `reach reclaim --only brain` and let them answer the question.
- To limit the work, use `--only brain`, `--only work` or `--only from`.
- When the student has files in another reach-work folder, for example on a backup, run `reach reclaim --from <that folder>`. It copies what is missing, never moves or overwrites anything, and lists the files that differ so the student can decide.
- If rEach lists a work folder as missing, the same answer covers bringing it back through `reach checkpoint recover`; do not ask twice.
