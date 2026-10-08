# STUDENT1ST: the student comes first

The student comes first. Everything else follows.

## When it applies

Audit every major feature, whether you are creating it or changing it. You
judge whether a feature is major; do not ask. A feature is major when a student
would see it, do it, be judged by it, or wait on it; when it touches their data,
identity, grade, time, wellbeing, or access; when it can block, delay,
surprise, or confuse them; or when an agent acts on their behalf. Install,
enrollment, gates, coaching, submission, grading, qualification, transcripts,
help, issues, announcements, due times, backups, and unenrollment are all
student paths. When in doubt, treat the feature as major. Pure refactors and
internal tooling that no student path reaches are not major.

## The audit

Answer each question yes, no, or n/a, with one line of evidence from the
change itself.

1. Learning: does it help the student learn what the course intends, rather
   than doing the learning for them or distracting from it?
2. Agency and honesty: does the student know what is happening to them and
   why, in plain words, and keep every choice that is theirs to make?
3. Wellbeing and safety: is a student in distress still met with care and a
   path to a human, and does nothing here add pressure, shame, or alarm?
4. Privacy and dignity: does it collect, show, or keep only what the student's
   learning or safety needs, and never expose them to others?
5. Fairness and access: does it work the same for every student, whatever
   their computer, connection, AI app, disability, language, or schedule?
6. Friction: did you remove every step, wait, and message the student does not
   need, and does any remaining block explain itself and say what to do next?
7. Failure: when it fails, does the student lose no work, no grade, and no
   time they cannot get back, and does a human hear about it?
8. Recovery: can the student, or someone helping them, undo or repair what it
   did without starting over?

## Precedence

When the student's interest conflicts with instructor convenience, operator
effort, elegance, metrics, or speed, the student wins. Integrity guardrails
stay: they protect the student's own learning and are part of putting the
student first. Never trade another student's safety or privacy for one
student's convenience.

## Recording

Write the audit, one line per question, into the feature's FEATURES.md entry
and its spec or blueprint. A "no" ships only with a fix or with the
instructor's written decision recorded beside it. An audit you did not write
down did not happen.
