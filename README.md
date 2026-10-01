# reach

> **AI agents:** read [`AGENTS.md`](AGENTS.md) first. Asked to install rEach from
> this repository's link? Follow [`INSTALL.md`](INSTALL.md).

The student's side of the course software: a harness plugin that installs into
Claude Code, Claude Cowork, Codex, Antigravity or Hermes and turns the student's own AI
agent into **rEach**, a bounded course partner for a
[Teach](https://bitbucket.org/paterasai/teach)-run course.

Until the student enrolls, rEach refuses everything else: it blocks every
prompt and asks the student itself, one at a time, for the class-wide course
code their instructor shared (like `MGMT327-K7QX-94TD`), their institutional
username (`FLLLNNN@lasierra.edu`) and their seven-digit student ID, so the agent
never sees them. Teach checks them against its roster and returns a signed
enrollment stamp tied to a scrambled fingerprint of the computer and account;
a copied install locks until it is enrolled again (`specs/wire.yml`, W-ENR-1..7).
Teach 0.16.0 implements its half; `tools/fake_teach` remains a local stand-in for wire revision 2026-10-01b only.

rEach then introduces itself and runs a short intake
interview, saved on the student's computer only. It enrolls with Teach, receives
the student's protected course materials, refuses to let the agent work until
the instructors' guardrails are installed, keeps the agent inside the student's
slice, checks every change against the
[Dovetail](https://bitbucket.org/paterasai/dovetail) shape, has the agent prove
the slice with scenarios of its own before anything is submitted (`reach qualify`:
those scenarios here where they can run, then an ungraded run on Teach that also
runs the instructors' hidden checks), submits work and waits for Teach's receipt,
and raises a hand to the instructors on its own after three failed tries. The
student deals only with the business behaviour; the agent does all the coding,
following Reach's feature and bug flows, without git (see ROADMAP.md).

Everything the student and their AI partner write in a course folder is saved
in the student's course record on Teach, which their instructors can read: the
student's prompts, the AI's replies, its reasoning where the harness stores it
readably, its actions, and every version of every code file. The course folder
is `~/reach-work`: assignment code lives only in
`deliverables/<course>/<assignment>/<cutout>-<slice>/`, and anything else the
student wants to build goes in `extracurricular/` (`reach work
--extracurricular`), which is never graded. The agent puts code in files, never
in chat; a code block it pastes anyway is filed as a snippet. The hooks write
everything to `~/.reach/transcripts/` with no network call; the Stop and
SessionEnd hooks and `reach sync` send the queue, and `reach transcript status`
shows what is sent and what is waiting. The student is told at enrollment and
in every greeting inside a course folder. Conversations outside course folders
and Antigravity sessions (no hooks) are not captured. Hermes has no transcript
file, so its hooks hand Reach the prompt, the reply and each tool call directly;
it records no reasoning.

The full design is in [`reach.spec.yml`](reach.spec.yml); every byte between
Reach and Teach follows [`specs/wire.yml`](specs/wire.yml) (protocol 1).
Students: see [`docs/student-guide.md`](docs/student-guide.md).

## Runtime

Ruby 2.6.10 to 4.0.x, standard library only, no native gems. macOS's built-in
`/usr/bin/ruby` is enough.

Local qualification runs the course's Cucumber suite, which needs Ruby 4 gems and Chrome. The session-start hook
installs Reach's runtime kit in the background when it is missing (`config.yml` `runtime.auto_install`), and `reach
runtime install` does the same by hand. It fetches Reach's runtime kit for this computer: Ruby 4.0.7 with the gems prebuilt and Chrome for Testing
154.0.8037.92, the same versions Teach grades with, verified against a manifest pinned in Reach and kept in
`~/.reach/runtime/`. Reach itself keeps running on the student's own Ruby; the runtime only runs the checks. [rplugin](https://bitbucket.org/paterasai/rplugin) is
optional: Reach uses its ports when it is installed and runs standalone otherwise.

## Install

Paste this repository's link into your AI agent and ask it to install rEach; it
follows [`INSTALL.md`](INSTALL.md). Or install it yourself:

| Harness | Command |
| --- | --- |
| Claude Code | `claude plugin marketplace add <link>` then `claude plugin install reach@reach --scope user` |
| Claude app (Cowork, Code tab) | Customize › Plugins › Add › Add marketplace, paste the link, add rEach |
| Codex | `codex plugin marketplace add <link>` then `codex plugin add reach@reach`, and trust rEach's start-up hook |
| Antigravity | run the one install command in `INSTALL.md` with `--harness antigravity` |
| Hermes | run the one install command in `INSTALL.md` with `--harness hermes`; open course folders with `~/.reach/bin/reach work --harness hermes` (setup prints the exact command) |
| Any of the above | install the public GitHub archive to `~/.reach/plugin`, then `ruby ~/.reach/plugin/exe/reach setup` |
| rplugin | `rplugin install ~/.rplugins/reach` |

Installing from a link needs the repository and its pinned Dovetail archive to be public.

### Updates

An install at `~/.reach/plugin` updates itself. rEach looks for a newer GitHub release (or, when there are none, a
newer tag) when a session starts and once an hour while you work, downloads it in the background, and installs it
when your next session starts, through the release's own `update/apply.rb`. Progress is kept in
`~/.reach/state/update.json`, so an interrupted update picks up where it stopped. `reach update status` shows where
things stand; `reach update run --apply` installs now; `REACH_UPDATE_DISABLE=1` turns updates off. A git checkout
is never updated.

Hermes keeps hooks and MCP servers in a profile's `config.yaml`, never per
folder, so setup creates a Hermes profile named `reach` (`hermes profile create
reach --clone --no-alias`, which copies the student's model settings and adds
no `reach` wrapper command) and Reach keeps its hooks, its MCP bridge and a
disabled `code_execution` toolset in that profile only. `reach work --harness
hermes` starts `hermes -p reach --accept-hooks chat` in the course folder; the
student's own Hermes profiles are never changed. Hermes started any other way
is not gated, and a prompt the gate refuses still reaches the model, marked as
refused, because Hermes cannot block a prompt.

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
reach reference list | show <path> | search <words> | links  the course reference material
```

Every owned file carries an invisible seal and every session leaves a witness
ledger; Teach reads both when it assesses a submission's provenance. A
submission with `reach check` findings is sent back once with the findings and
refused the second time, raising a hand to the instructors.

## Course reference

Reference material never ships in this repository. Teach sends each enrolled
install its course's encrypted `.rref` blobs and their keys in the signed
guardrails package at `reach sync`; `reach reference` decrypts in memory on every call and never writes plaintext
to disk. Before enrollment, or before the key arrives, it reports the material
as locked.

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
