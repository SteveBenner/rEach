---
name: reach-progress
description: Use when the student asks where they are, where they stand, how they are doing, how far along they are, what is left, what they have done so far, or to check their progress.
---
This is the answer to "where do I stand". It is not `reach check`, which checks code: never run that for a question about progress.

1. Call the `reach_progress` tool, or run `reach progress --format json` where tools are not available. It only reads, and changes nothing.
2. When `stale` is true, the course details may be out of date. Call `reach_sync` once, then ask again. If the sync cannot finish, go on with what you have; the summary already says how old it is.
3. Give the student `summary` as rEach wrote it. Add no milestone, percentage, estimate, or prediction of a grade, and never compare them with anyone else or call them behind. rEach only reports what it can see on this computer and in the course details it last received.
4. When the result carries `text` with `relay_verbatim` true, a submission that was waiting to be sent was refused: tell the student that first, word for word.
5. Each entry in `notices` says work is missing. Tell the student in one sentence that rEach kept copies and will bring them back, and follow the reach-checkpoint skill.
6. Finish by asking whether they want to do the next step now. When they say yes, do it. If the next step names something to run, run it yourself rather than asking them to.

For the points recorded for each assignment, use `reach_grade`.
