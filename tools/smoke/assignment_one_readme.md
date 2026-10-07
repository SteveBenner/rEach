# context.a1 - backend slice

Synthetic smoke student. Every answer below is scripted by the smoke runner, not written by a person.

## Business user and decision

A cafe manager checks one setting of the business profile, target_margin, before deciding whether this week's menu discount keeps the margin above the target the owner set for the season.

## Information flow

The manager types a key. The behaviour normalises it, asks the profile port for the value, and answers the key, the value and a status of ok or not_found.

## People and control

The manager decides; the profile owner controls what the profile holds. An unknown key never invents a value: it answers not_found with the normalised key.

## Expected, actual, case and status

| Case | Expected | Actual | Status |
| --- | --- | --- | --- |
| Requesting target_margin | value with status ok | awaiting remote acceptance | queued |
| Requesting an unknown key | not_found | awaiting remote acceptance | queued |
| A key with capitals and spaces | same value as the plain key | awaiting remote acceptance | queued |

Queued is not passed; results arrive from the course server after submission.

## Contributions and tools

Synthetic run. The smoke runner directed the behaviour choices and wrote every answer in this file; the implementation an AI agent would write was scripted from the released contract, and no person wrote any part of it.
