---
alias: H
enforce: ledger
id: R-CHECKPOINT
opcode: CHECKPOINT
rule: checkpoint after every clean check and before any rewrite; restore, never reconstruct
slice: all
tier: public
when:
- task:after-task
- task:rewrite
---
# CHECKPOINT: save what works, before you risk it

A checkpoint is a snapshot of the slice's owned files kept by Reach, with a
note. You never manage files yourself; you call the command:

```
reach checkpoint save --note "<what works now, in one line>"
reach checkpoint list
reach checkpoint restore <n>
```

Save:

- after `reach check` comes back clean and the code does something new;
- before any change that touches more than one method, before a rewrite of
  any kind, and before a fix you are not sure about;
- when the student says "save", "checkpoint" or "keep this".

Restore:

- when a change made things worse and the way back is not one obvious edit;
- when the student says "undo", "go back" or "the earlier version";
- never reconstruct an earlier version from memory; restore it.

Say in one sentence what a restore will replace, and wait for the
student's yes before restoring. A restore keeps an automatic checkpoint of
the current state first, so nothing is lost either way.

Reach refuses a save whose files equal the last checkpoint, so saving too
often costs nothing.
