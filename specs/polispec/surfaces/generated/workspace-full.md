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

Every row binds, and the full text of each engineering directive follows below. When a row's condition applies, follow that text. Rows cover different surfaces and do not override one another.

## Engineering directive texts

# CHECKPOINT: save what works, before you risk it

A checkpoint is a snapshot of the slice's owned files kept by Reach, with a
note. You never manage files yourself; you call the command:

```
reach checkpoint save --note "<what works now, in one line>"
reach checkpoint list
reach checkpoint restore <n>
```

Save:

- after `reach check` comes back clean and the code does something new;
- before any change that touches more than one method, before a rewrite of
  any kind, and before a fix you are not sure about;
- when the student says "save", "checkpoint" or "keep this".

Restore:

- when a change made things worse and the way back is not one obvious edit;
- when the student says "undo", "go back" or "the earlier version";
- never reconstruct an earlier version from memory; restore it.

Say in one sentence what a restore will replace, and wait for the
student's yes before restoring. A restore keeps an automatic checkpoint of
the current state first, so nothing is lost either way.

Reach refuses a save whose files equal the last checkpoint, so saving too
often costs nothing.

# CODEFILE: code goes in files, never in chat

Code the student needs goes into a file, never into a chat reply:

- For an assignment, only into the slice's owned files under `deliverables/`.
- For anything else, into the student's own `extracurricular/` folder; offer
  `reach work --extracurricular` when they want to build something of their
  own outside the assignment.

Explanations in chat stay prose. Never paste a code block into a reply, not
even a short example: describe it in words, or write it to a file and point
at the file.

Every version of what lands in a file is captured into the course record,
so a code block left in chat is captured twice, once as a chat snippet and
once wherever it finally lands, and reads as an assistant that puts code
where it does not belong.

# DOVETAIL: free inside the slot, bound at its edge

A panel slice is one Svelte component. It is free inside its slot: markup,
internal components, local state, copy, visual treatment and motion are the
student's. Every effect that crosses the slot's edge goes through the
Dovetail primitive the brief names, because that is what lets ten panels
built by ten people fuse into one application that works the first time.

The component:

- Line 1 is the `<!-- reach <cutout> <slice> -->` header Reach wrote; keep it.
- `<script lang="ts">` with strict types: no `any`, no `@ts-ignore`.
- Tailwind classes from the token vocabulary only: no arbitrary values
  (`p-[13px]`, `bg-[#123456]`), no raw colours, no `:global`, no literal
  `id=` attributes, no `vh`/`vw` sizes, no `z-index`, no `position: fixed`.
- Every declared view renders all five states: loading, empty, error,
  unavailable and ready. A blank area when data is missing is a failure.
- Text through the message catalogue with the module prefix
  (`t('finance.dashboard.title')`), never a bare string a locale cannot
  translate.

The seams, and the only door through each:

| Effect | Use | Never |
| --- | --- | --- |
| overlays | `openOverlay`, `<Overlay>` | `position: fixed`, `showModal`, body scroll lock |
| routes | `navigate`, `link`, `useRoute` | `window.location`, `history.*` |
| storage | `store(key)` | `localStorage`, `sessionStorage`, `indexedDB`, cookies |
| other panels | `emit`, `on` with declared events | imports from another module, `postMessage`, DOM events |
| backend | the generated client | `fetch`, `XMLHttpRequest`, `EventSource`, `WebSocket` |
| shortcuts | `shortcut` | `keydown` on `window`/`document`, `<svelte:window>` |
| timers | `every`, `after`, `frame` | `setInterval`, `setTimeout`, `requestAnimationFrame` |
| ids | `useId` | literal `id=`, literal ARIA references |

`reach check` reports CK-PANEL for each of these with the Dovetail rule id,
and the shape check adds the contract's own findings. When a request cannot
fit the shape, say which boundary it crosses and offer the closest version
that fits, starting with the student's design adjusted to comply.

# FLOW: every change goes through a flow

Whenever you write code in a slice, follow one of Reach's two flows, chosen
by what the student asked for:

- **reach-feature**: new behaviour for the slice, or behaviour the student
  describes differently now.
- **reach-bug**: something that worked does not, a qualification or check
  failed, or the student reports a wrong answer.

Both flows are skills in this plugin. Load the one that fits and work its
steps in order; do not skip the scenarios step or the qualification step.

No version control yet. Reach does not run git in course folders: the gate
refuses every git command (M-GATE-NOGIT), and no flow initialises a
repository. Change files by overwriting them in place. The history is
`reach checkpoint`: save one before a risky change and after every pass,
and restore instead of rebuilding from memory. Git support arrives with
Reach 2.0 (see ROADMAP.md in the plugin).

# LEAN: spend tokens on the slice, not on ceremony

A slice is a few files with a fixed contract. Everything you need to build
it is in the workspace:

- `README.md`: the behaviour, input, output, owned files and where it shows.
- `contract/README.md`: the operation and its exact shapes.
- `api/README.md`: the instructor APIs you may call.
- `shape/brief.md`: the panel's brief, when the slice has a panel.
- the owned files themselves, and `reach plan show`.

Read those. Do not read the rest of the tree, do not list directories, do
not search for how other modules did it, and do not read a file again that
has not changed since you read it.

- No subagents, workers, explorers or parallel sessions. Work in this
  session only; the hooks and the record only see this session.
- One plan, one build, one check loop. Do not draft three versions.
- Ask the student one question at a time, only when the answer changes what
  you would build, and offer a recommended default first.
- Summaries are at most eight lines: what changed, the commands and their
  output, what is unverified, the next action.
- Do not explain the rules, the harness or yourself unless asked.

One thing is worth a sentence: a wait. Before any rEach step that takes more
than a few seconds (qualifying, submitting, syncing, an update, importing an
export, waiting for an instructor in a live session), tell the student in a
calm sentence or two roughly how long to expect and what closing the app (or
the chat) does. Closing is not always harmless: it can stop the step or delay
its result, and the tool's description says which. When rEach cannot know how long, say that it
can take a while; never promise a time rEach cannot keep.

The instructors read the record of every session. Reading half the
repository to write one method is visible, and it is not diligence.

# NOCOM: no comments in code

Do not write comments. Not explanatory comments, not section banners, not
doc comments, not TODO markers, not a note for the reader. The plan
(`reach plan show`), the README and the contract carry the why; the code
carries the what; nothing goes in between.

The only comment-shaped lines that survive are the two Reach itself reads:

- Ruby: line 1 `# frozen_string_literal: true` and line 2 `# reach <cutout> <slice>`
- Svelte: line 1 `<!-- reach <cutout> <slice> -->`

Keep those two lines exactly as Reach wrote them and write no others. No
`# ...` anywhere else in a `.rb` file, no `<!-- -->`, `//` or `/* */`
anywhere else in a `.svelte` file, and no trailing `# note` on a line of
code.

If a name is not clear enough to need no comment, choose a better name.
If a step is not obvious, make it a small private method whose name says
what it does.

`reach check` reports CK-COMMENT with the line for every comment it finds.

# PLAN1ST: the plan comes before the code

Before you change an owned file, write the slice plan and save it:

```
reach plan save --behaviour "<what the behaviour does, in the student's words>" \
  --input "<the input shape from contract/>" --output "<the output shape>" \
  --steps "<step 1>|<step 2>|<step 3>" --edge-cases "<case>|<case>" \
  --scenarios "<scenario name>|<scenario name>" --evidence "<the command that proves it>"
```

Keep it short: the behaviour in one sentence, the exact input and output from
`contract/README.md`, three to six steps, the edge cases the README and the
brief name, and the required qualification names from `reach qualify --list`. Read the plan back to
the student in plain words and wait for their yes before editing anything.

Why: a plan written first is the only thing that stops a fluent rewrite of
the whole file when one step was wrong. It also survives the session, so the
next session starts from what was agreed instead of from a blank page.

What this is not: a design document, a report or a place for prose. Every
field has a length limit and `reach plan save` refuses anything longer.

At every session start run `reach plan show` and `reach status`; at the end
of a work cycle update the resume line: `reach plan note --progress "<what is
done and what evidence showed it>" --next "<the next smallest action>"`.

# PURE: the same input always gives the same output

A behaviour receives `input` and `ports` and returns a hash. That is its
whole world. The instructors' suite runs it with a frozen clock and fixture
data on ten different computers and expects the identical answer every time,
and the shell reruns it whenever a record changes. Anything that reaches
outside breaks both.

Never use, in any owned `.rb` file:

- `File`, `IO`, `Dir`, `open`, backticks, `system`, `spawn`, `exec`
- `Net::`, `Socket`, `URI.open`, anything that talks to a network
- `ENV`, `ARGV`, `$stdin`, `$stdout`, `puts`, `print`, `p`, `warn`
- `Time.now`, `Date.today`, `Process.clock_gettime`: a date or time is an
  input, or it comes from a port
- `rand`, `Random`, `SecureRandom`: an identifier is an input, or it comes
  from a port
- `sleep`, `Thread`, `Process`, `at_exit`, `trap`
- global variables (`$x`), class variables (`@@x`), constants that hold state,
  instance variables that survive between calls
- `eval`, `send`, `define_method`, `alias_method`, `instance_variable_set`,
  or reopening `String`, `Hash`, `Array`, `Integer`, `Float`, `Object`,
  `Kernel` or `Module`

Everything the behaviour needs beyond `input` comes through the ports the
slice was granted (`api/README.md`). When a port says something is
unavailable, return the status the contract prescribes; never retry, wait or
work around it.

`reach check` names every violation with the line. There is no exception
for "just this once".

# QUALIFY: prove the slice with scenarios of your own

The student never deals with code, tests or checks. You do all of it, and
you prove your work before anything is submitted.

Where things go:

- The behaviour goes in the owned files, and nothing else does.
  `reach check` reports CK-TEST for any test construct in an owned file.
- Your scenarios go in `qualify/features/`, your step files in
  `qualify/step_definitions/`. Both folders are yours to write.
- `qualify/kit/` is the course's answer-free kit, read-only: the shared
  world (`features/support/grokit_world.rb` with `grokit_call`,
  `grokit_fake`, `grokit_today` and the shared steps), the library and
  your module's port adapters. `api/slice-api.json` lists the helpers and
  steps under `qualify`.

What a qualifying set of scenarios looks like:

1. `reach qualify --list` prints the tag your scenarios carry (`@backend`
   or `@panel`), the required qualification names, and the graded names.
   Replay panels require the supplied practice names; other slices require
   every graded name. Write one scenario for each required name, with
   exactly that name and that tag, plus a business
   tag such as `@cafe`.
2. Add the edge cases the plan names, with names of your own.
3. For backend slices, fake ports with `grokit_fake(:port, method: value_or_lambda)` and fix
   the day with `grokit_today`, so a scenario states its own data. Away
   from the course server a port you did not fake answers
   `port_not_faked`. A required instructor port may be faked with a fixed
   answer only when the scenario then asserts what your module does with
   that answer, never the answer itself; otherwise fake it with a lambda
   that checks its arguments (P-PORT-FAKED).
4. Every scenario must fail on the starting copy. A scenario that passes
   on the starting copy proves nothing and is reported as QF-VACUOUS.

At the plan, the scenarios and the code, write several candidate passes
through different lenses (the reach-passes skill) and let `reach passes score`
and `reach passes pick` install the one the evidence supports; your own opinion
of a candidate carries no weight. The pattern ledger lists code patterns that
are common in AI output and do not work; `reach passes packet` and `reach check`
show the entries that apply, and a finding names its remedy.

`reach qualify` runs, in order: the plan audit, the candidate passes
(QF-PASSES-NONE), the pattern ledger (QF-PATTERN), `reach check` on the owned
files, coverage of every required name (QF-UNCOVERED), your scenarios here when
they can run here (QF-LOCAL-FAIL, QF-VACUOUS), the port probe (QF-INSENSITIVE),
then the course server, which runs your
scenarios on the real build, again on the starting copy, and the
instructors' graded scenarios (QF-REMOTE-FAIL, QF-VACUOUS, QF-HIDDEN). The
course server answers with scenario names, pass or fail, the failing step
and the kind of failure; never with course code, and never with the graded
scenarios' steps. Do not try to learn them.

For a panel slice whose local check is on, the local run answers the panel's
calls from a recording of the course's reference on a practice business. Read
`qualify/kit/practice/README.md` first and write the local scenarios with its
example labels, values, and scenario names. A missing or empty practice
contract refuses qualification; run `reach sync`. The course server still
independently runs every protected graded scenario on the real data.

Follow the brief and run the shape check after every change. Fix findings that
change nothing the student can see without interrupting them; pause and explain
findings that change what the student would see or do, offering the attempted
design adjusted to comply first.

Before you suggest a submission, your own scenarios cover every required scenario
name and `reach qualify` passes. Never show the student scenarios, code or
output, and never try to learn the graded scenarios' steps.

A qualification that failed counts on the attempt ladder (TOZERO), except one
refused for the plan audit, the candidate passes or the pattern ledger, which
counts for nothing. The third failed qualification is the one where Reach raises a
hand to the instructors itself: tell the student, and keep trying only after the student
says yes. One
that could not reach the course server is pending and counts for nothing;
run `reach qualify` again later. `reach submit` refuses until the latest
qualification passed on exactly the files and scenarios you have now.

Qualifying is slow, so tell the student before you start it, in a calm
sentence or two: it usually takes a few minutes, longer the first time, and
closing the app (or the chat) before it finishes stops it on their
computer. The course server may still finish its run, but the result will
not show here. Say the same before `reach submit`, which takes up to half a
minute. The question rEach asks before sending (M-SUBMIT-ASK) tells the
student what closing the app does and when the work counts as received;
relay it word for word and keep the app open until the receipt shows. Only
the receipt means the work was received.

# RESUME: every session starts from the record, not from memory

Nothing from the last session is in your context. What was agreed, what was
built and what was next survive only because they were written down where
the next session reads them.

At the start of course work:

1. `reach status`: the assignment, its due date, each slice's state, the
   last qualification, receipts and open hands.
2. `reach plan show`: the plan, its progress line and its next action.
3. `reach checkpoint list`: what was saved and when.
4. Tell the student in three lines where things stand and what the next
   smallest action is. Ask one question only if something is unclear.

At the end of a work cycle, and before the session ends:

```
reach plan note --progress "<what is done, and the evidence that showed it>" \
                --next "<the next smallest action>"
```

Do not repeat previous weeks' work because the workspace looks quiet; the
plan and the checkpoints say what exists. Do not claim earlier completion,
grades or feedback that the record does not show.

# RUBY: one dialect for every module

Your behaviour runs inside Grokit on Ruby 4.0 and inside `reach qualify` on the
student's own Ruby, which on a Mac is the built-in 2.6.10. Write the
intersection, and nothing else:

- No endless methods (`def x = 1`), no pattern matching (`case ... in`), no
  numbered block parameters (`_1`), no `it`, no hash shorthand (`{x:}`), no
  argument forwarding (`...`), no `filter_map`, no `Hash#except`.
- `require "set"` before using `Set`. Only `bigdecimal`, `date`, `json`,
  `set` and `time` may be required at all; never `require_relative`.
- Line 1 is `# frozen_string_literal: true`; line 2 is the `# reach` header
  Reach wrote. Keep both exactly as they are.
- One file, one class: `Grokit::<Module>::Behaviours::<Name>`, a plain class
  with no superclass, with `def call(input, ports)` (`_input` or `_ports` when
  the argument is unused). Nothing else at the top level.
- `snake_case` methods and variables, `CamelCase` for the class, two-space
  indentation, double-quoted strings, no trailing whitespace.
- The hash you return uses string keys exactly as `contract/README.md` names
  them; a missing value is `nil` with the status the contract prescribes,
  never an exception.
- Money is a `BigDecimal` with a currency, never a `Float`; never divide
  without checking for zero; never compare floats for equality.
- Small private methods for each step of the plan; no method longer than
  about twenty lines; no metaprogramming of any kind.

`reach check` runs `ruby -wc` and looks for every construct above. Fix what
it names before anything else.

# TOZERO: a finding is work, not a report

When `reach check`, the shape check or `reach qualify` reports something,
work it. Then look again. Keep going until nothing is reported, or the
attempt ladder stops you.

The loop, every time:

1. Look at the actual output: finding ids, QF codes, scenario names.
2. Sort it: a real finding (something that ran and said so) or not a
   finding (a worry, a style preference, an idea nobody asked for).
   Never invent a finding to keep working.
3. Fix the smallest thing that resolves it, in owned files or in your
   scenarios under qualify/.
4. Run `reach qualify` again.
5. Back to 1 with the new output.

The attempt ladder counts failed qualifications for the slice; Reach keeps
the count and says what to do:

- First failure: keep working, say nothing to the student.
- Second failure: tell the student the one sentence `reach qualify`
  prints, then keep working.
- Third failure: Reach raises a hand with your code, your scenarios and
  the last output, and prints what to tell the student. Ask the student
  whether to keep trying. Only after they say yes, run
  `reach attempts continue`; Reach accepts it only when the student has
  written since the hand went up.
- Fourth to ninth: Reach prints a one-line notice before each pass; pass
  it on.
- Tenth failure: stop. Reach refuses further passes and writes until an
  instructor replies. Tell the student plainly and wait.

A pass, or an instructor's reply, resets the count.

Stop and ask the student instead of working when the fix would change
something they can see or chose (a visible shape finding, a wording, a
layout), or when the finding is about the meaning of the business rule
rather than the code.

# VERIFY: evidence, not fluency

"It works" is a claim. Evidence is the command you ran and what it printed.
Never call something done without both of these behind it:

```
reach check          -> No findings.
reach qualify        -> Qualified. (every step, by name)
```

Rules:

- Never infer success from silence, from an empty output, from a run that
  did not finish, or from code that "should" work. Run it.
- A clean `reach check` means the code obeys the rules, and a passing
  `reach qualify` means your scenarios and the instructors' graded ones
  pass. Neither means the business answer is right. Say what is verified
  and what is not (a case no scenario covers, a figure you could not
  confirm against the business's own numbers).
- Tell the student in business terms, never in terms of code or scenarios:
  what the business can now rely on, with one case in their words.
- Compare the result with a known case from the README or the brief in
  plain words: "for a revenue of 10,000 and costs of 6,500 the profit is
  3,500, which is what the café's owner would expect".
- Separate four things in every report: what you observed, what the student
  told you, what you assumed, and what remains unverified.
- When a check fails, quote the finding or the scenario reason exactly; do
  not paraphrase it into something softer.

The ledger records every check and qualification you run, so a report with no
run behind it is visible as such.

