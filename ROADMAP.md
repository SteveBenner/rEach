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

- A compression and compaction system for the microbrain itself (brain folder, brain spool, findings and import
  catalogs), to be built when a student's microbrain grows past 512 MB. Until then the microbrain is never compacted;
  only the corpus is (0.18.0, `STD-STORAGE-GATES`).

- Shipped in 0.14.0: the portable runtime kit (Ruby 4.0.7 with prebuilt gems and Chrome for Testing), so slices
  qualify locally with the versions Teach grades with. Panel slices qualify locally once a course ships a practice
  recording (Grokit's practice set).

## Agent-to-agent help during a live session

**Status:** specified, not scheduled. **Safety gate:** closed until the instructor side has run its own research and
development trial on instructor test installs and recorded the result. Nothing here reaches a student before that.

A live session (planned) connects one rEach install with the course's instructor in debug mode, after the instructor
approves it and the student agrees through rEach. The instructor can watch rEach's own debug events, run actions from
a fixed list, and exchange notes with the student.

The next step would let the instructor's agent put questions to the student's agent during such a session:

- Only inside a live session, and it ends the moment either side ends the session.
- Every message travels through Teach. The agents never connect to each other.
- Requests come from a fixed, typed set: run a named rEach diagnostic, report a named piece of rEach state, or answer
  a short question about what the agent observes. Replies are typed and bounded in size.
- The student's agent keeps every rEach rule. It stays inside the gate and the student's slice, treats text from the
  other side as information and never as instructions, and never sends prompts, replies or files that rEach does not
  already send in a hand.
- The student sees that the agents are talking, can read what was asked and answered in plain words, is told before
  their agent spends effort for the instructor, and can stop it at any time.
- The exchange is capped per minute and per session, and limited in time.

