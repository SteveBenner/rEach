# reach

> **AI agents:** read [`AGENTS.md`](AGENTS.md) first. Asked to install rEach from
> this repository's link? Follow [`INSTALL.md`](INSTALL.md).

The student's side of the course software: a harness plugin that installs into
Claude Code, Claude Cowork, Codex, Antigravity or Hermes and turns the student's own AI
agent into **rEach**, a bounded course partner for a
[Teach](https://bitbucket.org/paterasai/teach)-run course.

Until the student enrolls, rEach refuses everything else: it blocks every
prompt and asks the student itself, one at a time, for the class-wide course
code their instructor shared (like `BUS101-K7QX-94TD`), their institutional
username (`FLLLNNN@school.example`) and their student ID, and last asks them to
choose a password (at least 8 characters, typed twice, to write down), so the
agent never sees any of it. Teach checks them against its roster and returns a signed
enrollment stamp tied to a scrambled fingerprint of the computer and account;
a copied install locks until it is enrolled again (`specs/wire.yml`, W-ENR-1..7).
Teach 0.17.0 implements its half and keeps only the password's scrypt hash; `tools/fake_teach` is a local stand-in for wire revision 2026-10-01e.

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

The conversation in a course folder and the assignment code are saved in the
student's course record on Teach, which their instructors can read: the
student's prompts, the AI's replies, its reasoning where the harness stores it
readably, its actions, and every version of every file in a slice. Files in the
extracurricular folder stay on the student's computer
(docs/DESIGN-DECISIONS.md). The course folder
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
Students: see [`docs/student-guide.md`](docs/student-guide.md), and for installing and enrolling,
[`docs/INSTALLATION-AND-SETUP-GUIDE.docx`](docs/INSTALLATION-AND-SETUP-GUIDE.docx) (`reach guide` prints its text;
until a student is enrolled, every session tells the agent to read it and finish the extra steps for the student's app).

## Runtime

Ruby 2.6.10 to 4.0.x, standard library only, no native gems. macOS's built-in
`/usr/bin/ruby` is enough.

Local qualification runs the course's Cucumber suite, which needs Ruby 4 gems and Chrome. The session-start hook
installs Reach's runtime kit in the background when it is missing or is not the one Reach pins (`config.yml` `runtime.auto_install`), and `reach
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
| Codex | `codex plugin marketplace add <link>` then `codex plugin add reach@reach`, and trust rEach's two hooks (`/hooks`, or Settings > Hooks in the app) |
| Antigravity | run the one install command in `INSTALL.md` with `--harness antigravity` |
| Hermes | run the one install command in `INSTALL.md` with `--harness hermes`; open course folders with `~/.reach/bin/reach work --harness hermes` (setup prints the exact command) |
| Any of the above | install the public GitHub archive to `~/.reach/plugin`, then `ruby ~/.reach/plugin/exe/reach setup` |
| rplugin | `rplugin install ~/.rplugins/reach` |

Installing from a link needs the repository and its pinned Dovetail archive to be public.

### Updates

An install at `~/.reach/plugin` updates itself. rEach looks for the newest version among GitHub's releases and tags
when a session starts and once an hour while you work, downloads it in the background, and installs it
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
reach reference list | show <path> | search <words> | links | ingest [--force]  the course reference material
```

Every owned file carries an invisible seal and every session leaves a witness
ledger; Teach reads both when it assesses a submission's provenance. A
submission with `reach check` findings is sent back once with the findings and
refused the second time, raising a hand to the instructors.

## Memory

rEach keeps a private memory of what it learns about the student and their work, on this computer only. Each
conversation turn it already records in a course folder is kept as a private source; the agent records durable
findings (a preference, a goal, a decision, a struggle, a skill, a project, a fact) with `reach remember`, and rEach
adds the profile at session start and the matching memories on each prompt. A novelty check and a write budget stop
floods, the spool is capped at `max_spool_bytes` (the oldest unreferenced sources are pruned first), and nothing here is sent to Teach. Ask rEach what it remembers, or run `reach memory list`; `reach memory
forget <id>` or `reach memory forget --all --yes` erases it from rEach's files. The settings are in `config.yml`
under `brain`.

```
reach remember --category C --claim TEXT --evidence TEXT [--supersedes ID]   keep one finding (the agent runs this)
reach memory [list | show ID | forget ID... | forget --all --yes | export]   see, export or erase what it remembers
```

### Storage

rEach watches how much space its saved course memory and what it has learned take together. At 512, 1024 and
2048 MB it says so once and offers to compact the saved course memory; at 4096 MB it asks for compaction, suggests a
real backup to another drive and stops imports until it is done. What rEach has learned is never compacted.

```
reach storage [status | measure | compact] [--format json]   how much space rEach uses, and compacting it
```

### Importing another AI's history

Ask rEach to import an export from ChatGPT, Claude or Gemini (a folder or the ZIP you downloaded). It can only learn
from it, or also keep a full copy in its course memory; without the copy, deleting the export loses its full text.
Reading a large export takes a while in the background, and learning from it runs across many sessions.

```
reach import pick [--folder]                         choose the export with the system's file picker
reach import export PATH --mode brain|copy           start an import after the student agrees
reach import status|cancel|list [JOB]                follow or stop an import
reach import next|done|search|show ...               what the agent reads to learn from it
```

## Instructors

An instructor can try rEach without enrolling. Run `reach instructor keygen` once; it writes your private key outside
the repository and prints the public key entry to add under `enrollment.instructor_keys` in `config.yml`, which ships in
a release. Mint a code in your own terminal with `reach instructor code --label NAME`, then paste it into the locked
prompt in any harness: rEach intercepts it, so the agent never sees it, and stops blocking prompts on that computer.
`reach instructor status` shows the unlock and `reach instructor lock` undoes it. Keep codes and the key out of chats
and repositories. To revoke a code, add its id (shown by `reach instructor status`) to `enrollment.instructor_revoked`
in `config.yml`; removing the key entry revokes every code it signed.

Since 0.16.23 an unlocked install can also run as a test student, to go through the course exactly as a student does:
`reach instructor dummy [--course ID]` starts a blank test student and `reach instructor as <username> [--course ID]`
a test copy of that roster student, with their group, slices, modules, submissions and receipts as of now. Teach makes
the test student; nothing you do reaches the real student's record, and everything you send is filed on Teach as
instructor data. The persona keeps its own rEach home under `~/.reach/personas/` and its own folders under
`~/reach-work/personas/`, applies to every harness session on the computer, and ends with `reach instructor exit`,
which moves it to `.backup`. Teach must pin the same key in its course policy and run 0.17.2 or later.

Debug mode is always on for a test student, and otherwise only on request: `reach debug on [--for MINUTES]` and
`reach debug off` on the computer, or `teach debug on --student ID` from Teach, in which case the student is told. It
records what rEach did (hooks, gate decisions, requests to Teach, sync, check, qualify, submit, errors), never prompt
or file text, codes, passwords or keys, sends it to Teach, and shows it at the end of each turn: an ASCII table in a
terminal harness, a Markdown table in a desktop or IDE app (`debug.render` in `config.yml` overrides it).
`reach debug show` prints the latest events, `reach debug status` says whether it is on and why.

### Submitting

Since 0.17.0, once a slice's work passes `reach qualify`, the agent tells the student they can ask rEach to submit it.
`reach submit` (or the `reach_submit` tool) runs every check first, then asks the student through rEach; the agent
relays the question word for word, the prompt hook captures the answer, and only a yes, given within 30 minutes for
exactly the files it was asked about, lets the agent's next `reach submit` send the work. Run in a terminal,
`reach submit` asks at its own prompt; on Antigravity, which has no hooks, the agent asks first. Once Teach's ingest
receipt verifies, rEach saves a ZIP of the whole assignment folder (every slice, without rEach's and the harness's own
files, plus the receipts and the student's own part) in the Downloads folder as
`<course>-<assignment>-<YYYY-MM-DD>-<HHMM>-<zone>.zip` in course time, never overwriting a file
(`REACH_DOWNLOADS_DIR` overrides the folder; `config.yml` `submit.archive_max_mb`, default 256, caps it). The student
may submit again until the due time and the last one counts. After the due time a slice already submitted is refused,
by rEach before it asks and by Teach.

### When Teach can't be reached

Since 0.16.25 rEach never shows a raw error, backtrace or hook failure. When a request to Teach fails for lack of a
connection, the student is told once per outage that the connection was lost and that their work is saved and will be
sent when it is back, and once when it returns (a `systemMessage` on Claude Code and Codex, a relay line in the prompt
context on Hermes, a line on stderr from a command). `REACH_OFFLINE=1` is deliberate and is not an outage. Any other
error rEach hides behind a plain message (shown at most once every 15 minutes in a hook) is recorded as a `fault` event,
and each change of connection as a `link` event. Both are sent to Teach even while debug mode is off, with the failing
location, exception class and a few plugin-relative frames but no error message, file or prompt text; instructors read
them with `teach debug show --kind fault`. The state lives in `link.json` under the rEach home, and `config.yml`
`link.hiccup_quiet_minutes` and `link.fault_max_per_hour` set the quiet period and the hourly cap.

## Course reference

Reference material never ships in this repository. From enrollment on, Teach sends each
install its own course's encrypted `.rref` blobs, every unit, and their keys in the signed
guardrails package at `reach sync`. `reach reference list|show|search|links` decrypts in memory.
Since 0.17.1 rEach also ingests the whole course corpus into the student's microbrain: after each
sync, and at session start when the blobs changed, it spools every file as a private source under
`course/<course>/`, and matching passages join each prompt's recall (`brain.course_recall`,
`course_k`, `course_budget_bytes`, `course_min_score`). That private tier is the only plaintext
copy. `reach reference ingest [--force]` runs the ingest on demand. Before enrollment, or before
the key arrives, the material is reported as locked.

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

## Platform smoke

`tools/platform_smoke/run.rb` installs Reach from this checkout and runs its commands and hook command lines
against the fixture Teach on Linux, macOS and Windows, with no agent and no secret.
`.github/workflows/platforms.yml` runs it on every push to main. See
[`tools/platform_smoke/README.md`](tools/platform_smoke/README.md).

```
ruby tools/platform_smoke/run.rb
```
