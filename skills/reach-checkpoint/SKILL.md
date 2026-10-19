---
name: reach-checkpoint
description: Use when the student says save, checkpoint, keep this, undo, go back, the earlier version, or that their work is missing or gone, and before any change that touches more than one method.
---
A checkpoint is a snapshot of the slice's files kept by rEach. You never copy files yourself; you run the command.

rEach also saves the files by itself every time you write one, before every write it allows and after every check, so the history is never more than one edit old. Those automatic saves are hidden from the list unless asked for, and any of them can be restored by its number.

- Save: `reach checkpoint save --note "<what works now, in one line>"`. rEach refuses a save that equals the last one, so save freely: after every clean `reach check`, before any rewrite, whenever the student asks. A named save is the one the student will recognise in the list.
- List: `reach checkpoint list` and read it back as "1: <note>, <time>". When the student wants an earlier version that no named save holds, run `reach checkpoint list --all` and find the automatic save by its time.
- Restore: say in one sentence what the restore will replace, wait for the student's yes, then `reach checkpoint restore <n>`. The current state is saved automatically first, so nothing is lost.
- Missing work: when rEach says a file or a work folder is missing, or the student says their work is gone, tell them in one sentence that rEach kept copies and will bring them back, wait for their yes, then run `reach checkpoint recover` (or `reach checkpoint recover --slice <folder>`). It puts the folder back if needed and restores the latest save; what is there now is saved first.
- Never reconstruct an earlier version from memory; restore it.
