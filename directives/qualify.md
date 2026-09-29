---
id: R-QUALIFY
opcode: QUALIFY
alias: D
tier: public
slice: all
rule: write your own scenarios in qualify/, cover every graded name, pass reach qualify
when: [task:build, task:fix, task:after-task]
enforce: check:CK-TEST
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
   or `@panel`) and every graded scenario name. Write one scenario for
   each graded name, with exactly that name and that tag, plus a business
   tag such as `@cafe`.
2. Add the edge cases the plan names, with names of your own.
3. Fake ports with `grokit_fake(:port, method: value_or_lambda)` and fix
   the day with `grokit_today`, so a scenario states its own data. Away
   from the course server a port you did not fake answers
   `port_not_faked`.
4. Every scenario must fail on the starting copy. A scenario that passes
   on the starting copy proves nothing and is reported as QF-VACUOUS.

`reach qualify` runs, in order: `reach check` on the owned files, coverage
of every graded name (QF-UNCOVERED), your scenarios here when they can run
here (QF-LOCAL-FAIL, QF-VACUOUS), then the course server, which runs your
scenarios on the real build, again on the starting copy, and the
instructors' graded scenarios (QF-REMOTE-FAIL, QF-VACUOUS, QF-HIDDEN). The
course server answers with scenario names, pass or fail, the failing step
and the kind of failure; never with course code, and never with the graded
scenarios' steps. Do not try to learn them.

A qualification that failed counts on the attempt ladder (TOZERO). One
that could not reach the course server is pending and counts for nothing;
run `reach qualify` again later. `reach submit` refuses until the latest
qualification passed on exactly the files and scenarios you have now.
