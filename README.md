# reach

> **AI agents:** read [`AGENTS.md`](AGENTS.md) first. Asked to install rEach from
> this repository's link? Follow [`INSTALL.md`](INSTALL.md).

The student's side of the course software: a harness plugin that installs into
Claude Code, Claude Cowork, Codex or Antigravity and turns the student's own AI
agent into **rEach**, a bounded course partner for a
[Teach](https://bitbucket.org/paterasai/teach)-run course.

rEach introduces itself as soon as it is installed and runs a short intake
interview, saved on the student's computer only. It enrols with Teach, receives
the student's protected course materials, refuses to let the agent work until
the instructors' guardrails are installed, keeps the agent inside the student's
slice, checks every change against the
[Dovetail](https://bitbucket.org/paterasai/dovetail) shape, runs the
instructors' tips suite, submits work and waits for Teach's receipt, and raises
a hand to the instructors when the agent is stuck.

The full design is in [`reach.spec.yml`](reach.spec.yml); every byte between
Reach and Teach follows [`specs/wire.yml`](specs/wire.yml) (protocol 1).
Students: see [`docs/student-guide.md`](docs/student-guide.md).

## Runtime

Ruby 2.6.10 to 4.0.x, standard library only, no native gems. macOS's built-in
`/usr/bin/ruby` is enough. [rplugin](https://bitbucket.org/paterasai/rplugin) is
optional: Reach uses its ports when it is installed and runs standalone otherwise.

## Install

Paste this repository's link into your AI agent and ask it to install rEach; it
follows [`INSTALL.md`](INSTALL.md). Or install it yourself:

| Harness | Command |
| --- | --- |
| Claude Code | `claude plugin marketplace add <link>` then `claude plugin install reach@reach --scope user` |
| Claude app (Cowork, Code tab) | Customize › Plugins › Add › Add marketplace, paste the link, add rEach |
| Codex | `codex plugin marketplace add <link>` then `codex plugin add reach@reach`, and trust rEach's start-up hook |
| Antigravity | clone the repository, then `ruby exe/reach setup --harness antigravity` |
| Any of the above | clone to `~/.reach/plugin`, then `ruby ~/.reach/plugin/exe/reach setup` |
| rplugin | `rplugin install ~/.rplugins/reach` |

Installing from a link needs the repository to be public.

## Directives, check, plan and checkpoints

Every course workspace's `AGENTS.md` ends with a directive table: one row per
rule with its opcode, condition and enforcement, in the same form as the fleet's
own agent directives. The engineering rows ship here in
[`directives/`](directives/); the course rows arrive inside Teach's encrypted
guardrails package as rows only: `reach directive <OPCODE>` asks Teach for the
one body, which is never stored on the student's computer, and shows the
one-line rule when offline.

```
reach check [--changed <path>] [--format text|agent|json]   the one checker the hooks run
reach plan save|note|show                                    the slice plan, read back each session
reach checkpoint save|list|show|restore <n>                  snapshots of the slice, no git needed
reach directive <OPCODE> | --list                            the directive bodies
```

Every owned file carries an invisible seal and every session leaves a witness
ledger; Teach reads both when it assesses a submission's provenance. A
submission with `reach check` findings is sent back once with the findings and
refused the second time, raising a hand to the instructors.

## Doctor

```
reach doctor
```

## Smoke test

Before tagging a release that changes anything a student sees, run the sandboxed
smoke test: real Claude sessions with rEach loaded, in Docker, with scripted and
model-played students. See [`tools/smoke/README.md`](tools/smoke/README.md).

```
ruby tools/smoke/run.rb
```
