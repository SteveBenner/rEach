## Engineering directives

[CHECKPOINT] checkpoint after every clean check and before any rewrite; restore, never reconstruct   d/CHECKPOINT   ⚙ ledger   ⚡ [task:after-task, task:rewrite]
[CODEFILE] put code in files, never in chat: owned files for coursework, extracurricular/ else   d/CODEFILE   ⚙ none   ⚡ [always]
[DOVETAIL] a panel is a Svelte component in TypeScript and token classes; seams go through Dovetail   d/DOVETAIL   ⚙ check:CK-PANEL   ⚡ [path:**/*.svelte]
[FLOW] when writing code, follow the reach-feature or reach-bug flow; never run git   d/FLOW   ⚙ gate:shell   ⚡ [task:build, task:fix]
[LEAN] read only README, contract/, api/, the brief and owned files; no subagents; one question   d/LEAN   ⚙ none   ⚡ [always]
[NOCOM] write no comments; the plan and README carry the why, the code carries the what   d/NOCOM   ⚙ check:CK-COMMENT   ⚡ [path:**/*.rb, path:**/*.svelte]
[PLAN1ST] save a slice plan with reach plan save before any edit; read it back at session start   d/PLAN1ST   ⚙ ledger   ⚡ [task:build, event:SessionStart]
[PURE] a behaviour is a pure function of input and ports: no I/O, clock, randomness or globals   d/PURE   ⚙ check:CK-PURE   ⚡ [path:**/*.rb]
[QUALIFY] write your own scenarios in qualify/, cover every required name, pass reach qualify   d/QUALIFY   ⚙ check:CK-TEST   ⚡ [task:build, task:fix, task:after-task]
[RESUME] open with reach plan show and reach status; close by updating the plan's progress   d/RESUME   ⚙ none   ⚡ [event:SessionStart, event:Stop]
[RUBY] plain Ruby that runs on 2.6.10 and 4.0: one class per file, frozen literal, no gems   d/RUBY   ⚙ check:CK-RUBY   ⚡ [path:**/*.rb]
[TOZERO] work findings to zero; the attempt ladder bounds retries; never invent findings   d/TOZERO   ⚙ gate:write   ⚡ [task:after-task]
[VERIFY] done carries the command and its output; a green check is not yet business meaning   d/VERIFY   ⚙ ledger   ⚡ [task:after-task]

Every row binds. When a row's condition applies, run `reach directive <OPCODE>` (or the reach_directive tool) and follow the full text; the `d/<OPCODE>` in a row names that directive. Rows cover different surfaces and do not override one another.
