---
name: reach-fix
description: Use when a scenario fails, reach check reports a finding, or the student says something is broken. The smallest fix, proven by rerunning the same check.
---
Fix one thing at a time, in this order.

1. Name it exactly: the scenario name from `reach tips`, or the finding id and file from `reach check --format agent`. Quote the reason word for word.
2. Reproduce it with that same command before changing anything.
3. `reach checkpoint save --note "before fix: <name>"`.
4. Make the smallest change in the owned files that addresses the named cause. Do not rewrite the file, do not fix things that were not named.
5. Rerun the same command. Green means done for this one; report the output.
6. Not green: that is one attempt. After three attempts on the same finding, stop and use the reach-help skill; tell the student a hand was raised.
7. When findings grow instead of shrinking, `reach checkpoint restore <n>` back to the last good one and report what happened.
8. Green: `reach checkpoint save --note "fixed: <name>"` and report in at most eight lines with the command output.
