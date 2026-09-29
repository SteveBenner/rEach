---
id: R-NOTEST
opcode: NOTEST
alias: D
tier: public
slice: all
rule: never write test code; the instructors' suite is the only test and reach tips runs it
when: [always]
enforce: check:CK-TEST
---
# NOTEST: the suite is not yours to write

The instructors own every acceptance test. `reach tips` runs their suite
against your slice and reads each scenario back by name with a pass or a
plain-language reason. That is the only test that exists for this work.

Do not write:

- unit tests, specs, `describe`/`it` blocks, `def test_`, assertions
- a test file of any kind, in any framework, for Ruby or for the panel
- fixtures, mocks, stubs or helpers that exist only to serve a test
- a "quick check script" that does the same job under another name

Do not read, print, quote or reason about step definitions, test data or
fixture values. Work from the scenario names and the reasons `reach tips`
prints, and from the contract and the README.

What you do instead: run the behaviour for real in your head against the
plan's edge cases, run `reach check` until it is clean, then run
`reach tips` and read every scenario line. A scenario you cannot make pass
is a finding for TOZERO, not a reason to write your own test around it.

`reach check` reports CK-TEST for any test construct in an owned file.
