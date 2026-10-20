---
alias: D
enforce: check:CK-TEST
id: R-QUALIFY
opcode: QUALIFY
rule: write your own scenarios in qualify/, cover every required name, pass reach
  qualify
slice: all
tier: public
when:
- task:build
- task:fix
- task:after-task
---
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
   `port_not_faked`.
4. Every scenario must fail on the starting copy. A scenario that passes
   on the starting copy proves nothing and is reported as QF-VACUOUS.

`reach qualify` runs, in order: `reach check` on the owned files, coverage
of every required name (QF-UNCOVERED), your scenarios here when they can run
here (QF-LOCAL-FAIL, QF-VACUOUS), then the course server, which runs your
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

A qualification that failed counts on the attempt ladder (TOZERO). One
that could not reach the course server is pending and counts for nothing;
run `reach qualify` again later. `reach submit` refuses until the latest
qualification passed on exactly the files and scenarios you have now.

Qualifying is slow, so tell the student before you start it, in a calm
sentence or two: it usually takes a few minutes, longer the first time, and
closing the app (or the chat) before it finishes stops it on their
computer. The course server may still finish its run, but the result will
not show here. Say the same before `reach submit`, which takes up to half a
minute. Nothing is saved for sending until the student says yes, so closing
the app while the question is open sends nothing. After the yes, the work
counts as received when it reaches the course server, and work that arrives
after the due time is marked late, so keep the app open until the receipt
shows. If the app closes first, the work stays saved on this computer and
rEach sends it at the next sync, but the course server can still refuse or
hold it, so only the receipt means it was received.
