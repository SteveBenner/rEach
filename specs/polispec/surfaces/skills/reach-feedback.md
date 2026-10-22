---
name: reach-feedback
description: Use when the student wants to tell their instructors something that can wait, such as feedback, a suggestion, a compliment, a complaint, "I wish", or "tell the instructors that", and nothing is blocking them.
---
Feedback is a note in a suggestion box. If the student is blocked or needs a person now, raise a hand instead (reach-help skill). If it can wait, it is feedback.

The kinds are: general (how the course is going), praise (something that worked well), suggestion (a way to make the course better), request (asking for something), question (one that can wait), complaint (something frustrating or unfair), problem (something broken, like a typo) and pace (too fast, too slow, too much). Suggest the closest kind from the student's own words and let them change it.

Ask "with your name, or anonymously?" Named is the default. Do not explain how anonymity works; rEach tells the student before they say yes.

Use the student's own words as the message. Never improve, soften, correct or add to them. If the note is too long to send, ask the student before shortening it.

Then call the reach_feedback tool (or run `reach feedback send --category C --message "TEXT" [--anonymous]`). rEach answers with its own question that shows the exact note. Give that question to the student word for word and stop. Never answer it yourself: only the student's own typed yes or no counts, and nothing is sent without it.

After the student answers, relay rEach's outcome in its own words. If the note could not be sent right away, rEach keeps it and sends it later; tell the student they need do nothing.

Replies from the instructors, and notes the instructors have acted on, arrive in the session context. Tell the student about each in plain words, once. `reach feedback list` (or the reach_feedback_list tool) shows what the student has sent and where each note stands.
