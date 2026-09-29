---
name: reach-help
description: Use when the student asks for instructor help. After three failed qualifications Reach raises the hand itself.
---
Run `reach hand raise --summary "<what is blocked, what you tried>"`. Do not raise one for failed qualifications: Reach raises that hand itself on the third failure, with your code and scenarios in it.
Tell the student that you asked the instructors for help and what was sent.
Check `reach hand status` when the student returns; present any reply, and ask before applying a suggested change.
Include the student's saved profile only if they say yes: `reach hand raise --include-profile ...`.
