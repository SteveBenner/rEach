---
name: reach-checkpoint
description: Use when the student says save, checkpoint, keep this, undo, go back or the earlier version, and before any change that touches more than one method.
---
A checkpoint is a snapshot of the slice's files kept by rEach. You never copy files yourself; you run the command.

- Save: `reach checkpoint save --note "<what works now, in one line>"`. rEach refuses a save that equals the last one, so save freely: after every clean `reach check`, before any rewrite, whenever the student asks.
- List: `reach checkpoint list` and read it back as "1: <note>, <time>".
- Restore: say in one sentence what the restore will replace, wait for the student's yes, then `reach checkpoint restore <n>`. The current state is saved automatically first, so nothing is lost.
- Never reconstruct an earlier version from memory; restore it.
