---
name: reach-sidecar
description: Use when the student says they worked in the rEach Sidecar, the offline packet or the reach-sidecar folder before rEach was set up, has a bundle ZIP from it, or asks to bring that work into rEach.
---
The rEach Sidecar is an offline folder the instructor hands out so a student can work on their assignments before rEach is installed. Its work is brought into rEach once, by rEach itself; you never copy its files by hand.

- Ask the student where the unzipped folder is (the one that holds `packet.rb`, usually in Downloads), then call the reach_packet tool with action import and that folder, or run `reach packet import <folder>` in a terminal. Do not read the folder yourself: the shell and read gates refuse a folder outside the course workspace, and the tool does the reading.
- rEach checks the folder's signature and that it belongs to this student and course, copies every started slice into its workspace with the sidecar's checkpoints and the student's own answers, keeps the offline bundle's receipt for the submission, and runs `reach check` and `reach qualify`. Tell the student in plain words what came in, what was left out and why.
- If rEach refuses (the folder is not a sidecar, was changed, belongs to someone else or to another course, or a slice is not assigned here), read the message to the student and do what it says; never work around it.
- When qualify passed, follow the reach-submit skill: `reach submit` asks the student itself. When it did not, follow the reach-bug skill on the findings and run `reach qualify` again first.
- The current state before the import is saved as a checkpoint, so `reach checkpoint restore` returns to it if the student prefers what they had here.
