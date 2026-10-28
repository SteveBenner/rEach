## Engineering directives

[FLOWDOC] for written work, write only .md and .txt files in the folder; the rest is the student's   d/FLOWDOC   ⚙ gate:write   ⚡ [task:write, task:submit]
[RESUMEDOC] for written work, open with reach status and reach next; close with what is saved   d/RESUMEDOC   ⚙ none   ⚡ [event:SessionStart, event:Stop]

Every row binds. When a row's condition applies, run `reach directive <OPCODE>` (or the reach_directive tool) and follow the full text; the `d/<OPCODE>` in a row names that directive. Rows cover different surfaces and do not override one another.
