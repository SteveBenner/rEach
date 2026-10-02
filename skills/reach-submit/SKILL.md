---
name: reach-submit
description: Use when the student wants to submit their slice, submit it again before the due time, or asks whether a submission was received.
---
Offer to submit once `reach qualify` has passed: tell the student they can ask you to submit this part whenever they are ready, that it sends the work to their instructors and saves a copy of all their work for the assignment in their Downloads folder, and that they can submit again until the due time (the last one counts).
Before submitting, run `reach part`: every question must be answered in the student's own words. If one is missing, ask it first.
`reach submit` works only after `reach qualify` passed on exactly the files you have now; if it refuses, run `reach qualify` first. Run `reach submit` (or the reach_submit tool). Reach asks the student itself: when it answers with Reach's question, relay it word for word and wait. Reach captures the student's answer itself. Never answer the question for the student, and never submit after a no.
When Reach then says the student said yes, run `reach submit` again once, as it says. Most of the time the receipt comes back straight away; tell the student in plain words what was received, the receipt number and the time, where the copy of their work was saved, and whether and until when they can submit again.
If submit says the due time has passed and the part is already submitted, tell the student it can't be submitted again and that their instructor can help; never try to submit a slice Reach says is closed.
On Antigravity, Reach cannot ask for you: ask the same question in plain words, and run the command only after the student's yes.
If submit says the work is queued, run `reach receipts wait --submission <id>` when you have an id, or `reach sync` when you are back online, and tell the student it has not been received yet.
If submit says the work wasn't accepted, read the reason and the fix to the student in plain words.
When a grade receipt arrives, show the signed scenario results in plain words. A queued or received submission is not passed. If a result fails, use the reach-bug skill, pass `reach qualify` again, and submit the correction with the student's yes.
