---
name: reach-help
description: Use when the student asks for instructor help. After three failed qualifications Reach raises the hand itself.
---
Run `reach hand raise --type <type> --summary "<what is blocked, what you tried>"` (or the reach_raise_hand tool with type). Pick the closest type: grade_question (grades), access_issue (accounts, Blackboard and other course systems), extension_request (the student asks for more time), concept_question, assignment_question, deadline_question, submission_question, technical_issue, setup_issue, feedback, integrity_question or other; use student_request when none fits better (it is also the default). Reach refuses a type it does not know. Do not raise one for failed qualifications: Reach raises that hand itself on the third failure, with your code and scenarios in it.
Tell the student that you asked the instructors for help and what was sent.
Check `reach hand status` when the student returns; present any reply, and ask before applying a suggested change.
Include the student's saved profile only if they say yes: `reach hand raise --include-profile ...`.
When the student says they have an extra-credit code, do not raise a hand: ask for the code and for their own answer, run `reach extra-credit CODE ANSWER` (or the reach_extra_credit tool) with exactly what they typed, and relay Reach's message. Never write, improve or invent the answer for them.
