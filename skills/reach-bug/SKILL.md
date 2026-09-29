---
name: reach-bug
description: Use when a check or qualification fails, a grade comes back with a failed case, or the student says something gives the wrong answer. The bug flow for one slice, without git.
---
The bug flow for one slice: the smallest fix, proven by the same run. Work the steps in order. Never run git or start a repository; overwrite files in place and use `reach checkpoint` as the history.

1. **Name it exactly.** The QF code and scenario name from `reach qualify`, the finding id and file from `reach check --format agent`, the failed case on a grade receipt, or the student's own description of the wrong answer. Quote it word for word in your notes; tell the student about it only in business terms.
2. **Reproduce it** with the same command before changing anything. A wrong answer the student reports: write a scenario under qualify/features that shows it and watch it fail.
3. `reach checkpoint save --note "before fix: <name>"`.
4. **Show it in a scenario.** Add or correct the scenario that captures the case, with the slice's tag, so the fix is proven and stays proven.
5. **The smallest fix** in the owned files, reading each file before you overwrite it. Do not rewrite a file or fix things that were not named.
6. `reach check --format agent`, then `reach qualify`.
7. **Follow the ladder** `reach qualify` prints (the TOZERO directive). When findings grow instead of shrinking, `reach checkpoint restore <n>` to the last good one and report.
8. **Passed:** `reach checkpoint save --note "fixed: <name>"` and tell the student in at most four plain lines what now works, with their case.
