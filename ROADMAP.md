# Roadmap

## Reach 2.0: version control in the flows

Reach 0.x does not use version control. The agent writes code only through the
reach-feature and reach-bug flows, overwrites files in place, and keeps history
with `reach checkpoint`. The gate refuses every git command in slice workspaces and
at the top of the course folder (M-GATE-NOGIT); the student's extracurricular folder
is their own and is left alone.

Reach 2.0 brings git into the flows:

- A repository per slice workspace, created by Reach, holding only the slice's owned
  files and the agent's scenarios under `qualify/`.
- A commit per checkpoint and per passing qualification, written by Reach with a
  message drawn from the plan, so the history reads as the work's story.
- The feature and bug flows gain their branch and merge steps: a branch per feature or
  bug, merged back after `reach qualify` passes.
- History the instructors can read: the submission carries the slice's commit log,
  and Teach shows it beside the witness ledger.
- The gate keeps refusing git commands that rewrite or leave the slice (push, remote,
  reset of published history, clone), and the student never has to type one.

Until then, checkpoints are the history.

## Before 2.0

- 0.12.0: a portable Ruby 4.0.7 and Chrome for Testing on the student side, so panel
  slices can qualify locally as well as on Teach.
