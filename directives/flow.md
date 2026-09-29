---
id: R-FLOW
opcode: FLOW
alias: M
tier: public
slice: all
rule: when writing code, follow the reach-feature or reach-bug flow; never run git
when: [task:build, task:fix]
enforce: gate:shell
---
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
