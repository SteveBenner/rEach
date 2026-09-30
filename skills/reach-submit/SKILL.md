---
name: reach-submit
description: Use when the student wants to submit their slice or asks whether a submission was received.
---
Before submitting, run `reach part`: every question must be answered in the student's own words. If one is missing, ask it first.
`reach submit` works only after `reach qualify` passed on exactly the files you have now; if it refuses, run `reach qualify` first. Run `reach submit`. Most of the time the receipt comes back straight away; tell the student immediately what was received, the receipt number and the time.
If submit says the work is queued, run `reach receipts wait --submission <id>` when you have an id, or `reach sync` when you are back online, and tell the student it has not been received yet.
If submit says the work wasn't accepted, read the reason and the fix to the student in plain words.
When a grade receipt arrives, show the signed scenario results in plain words. A queued or received submission is not passed. If a result fails, use the reach-bug skill, pass `reach qualify` again, and submit the correction with the student's yes.
