---
name: reach-storage
description: Use when rEach says its memory on this computer is getting large or at its limit, or when the student asks how much space rEach uses or wants to free space.
---
Run `reach storage status` (or the reach_storage tool) to see how much space rEach's memory uses: the saved course memory and what rEach has learned about the student, together. Tell the student the size in plain words.
When rEach's notice says the memory has grown, offer to compact the saved course memory to free space, and say that what rEach has learned about them is never compacted or changed.
To compact, run `reach storage compact` (or the reach_storage tool with action compact). Reach asks the student itself: when it answers with Reach's question, relay it word for word and wait. Reach captures the student's answer itself. Never answer the question for the student, and never compact after a no.
When Reach then says the student said yes, run `reach storage compact` again once, as it says. It starts compacting in the background and answers at once; tell the student it is running and they can keep working. When Reach later reports the result, tell the student the before and after sizes in plain words.
If Reach says it is already compacting, tell the student it is still running. If it says there is no saved course memory to compact, tell the student there is nothing to free that way.
At the limit, also suggest a true backup: copying their course memory folder and their rEach folder to another drive. Tell them nothing new can be imported until compacting is done.
On Antigravity, Reach cannot ask for you: ask the same question in plain words, and run the command only after the student's yes.
