# FEATURES — rEach

**The registry of the software features rEach carries, with build and deployment status.**

rEach is the student's course partner: it enrols a student with Teach, syncs signed course packages, guards the
student's workspace, checks and plans their slice, submits it and follows the receipts, inside the student's own
agent harness.

| | |
|---|---|
| **Registry version** | 0.8.0 |
| **Last audited** | 2026-09-29 |
| **Coverage** | Partial: the 0.7.0 surfaces plus the core flows verifiable from `README.md` and `reach.spec.yml` (enrol, sync, check, checkpoint, plan, submit, receipts, hands, tips, setup, installer, reference, transcript). Not catalogued: the interview and profile, the MCP bridge tools other than reference, doctor's individual checks, shape check internals, directives, the harness integrations one by one. `TODO.md` carries the item to complete it. |
| **Running instance** | None: rEach is a cli and plugin. Deploy is judged against the released artifact. 0.8.0 is published on GitHub `main`; no student runs it against a hosted Teach yet, so course features stay 🔵 until one does. |
| **Feature count** | 18 catalogued |

## How to read this registry

Build: ✅ Shipped · 🟡 Partial · 🟠 Scaffolded · ⚪ Planned.
Deploy: 🟢 Live · 🟣 Live on fixtures · 🔵 Built, not enabled · 🔴 Kill-switch OFF · ⚫ No runtime path.
For a cli, 🟢 means the version students actually run carries the feature. Blockers: Access · Intelligence ·
Temporal · Inference · Financial · Human · Engineering; a dash means nothing is outstanding.

| Build | Count | Share |
|---|---|---|
| ✅ Shipped | 17 | 94% |
| 🟡 Partial | 1 | 6% |

| Deploy | Count | Share |
|---|---|---|
| 🟢 Live | 1 | 6% |
| 🔵 Built, not enabled | 16 | 89% |
| ⚫ No runtime path | 1 | 6% |

## 1 · Install

### 1.1 · Public-ZIP installer

`bin/reach-install` installs from the repository's public ZIP without Git or a GitHub login, using a pure-Ruby ZIP
reader. It materialises symlinks safely, because the smoke found that the repository's `CLAUDE.md` symlink blocked
installs from the public archive. It backs up an existing install, downloads the Dovetail archive pinned in
`dovetail-revision.txt`, enforces size and count limits and bounded retries, and stops when
`REACH_INSTALL_KILL_SWITCH` is set. GitHub's archive carries the `dovetail` submodule as an empty directory, which the installer replaces (0.7.1, found by
the first public run). `tools/smoke/assignment_one.rb --public` installed from the real public GitHub ZIP on 2026-09-28.

Build ✅ · Deploy 🟢 · Blocker: Engineering (the Windows path is unverified).

### 1.2 · Dovetail submodule

Dovetail is a git submodule at `dovetail`, pinned by `dovetail-revision.txt`, which the smoke checks against the
gitlink.

Build ✅ · Deploy 🔵 · Blocker: Access (not pushed).

### 1.3 · Harness setup

`reach setup` installs rEach into the detected harnesses through their own install commands and ends with the NEXT
block the installing agent reads to the student. It exits 1 and prints no installed text or greeting when nothing was
installed, including the manual branches taken when a harness CLI is missing.

Build ✅ · Deploy 🔵 · Blocker: Human (the live Codex session and Antigravity remain untested; see `TODO.md`).

## 2 · Course flow

### 2.1 · Enrol

`reach enrol <code> --teach-url URL` generates keys and enrols with Teach. Before it writes any key it verifies the
response fields, the wire digest equality and `minimum_reach_version`. The smoke showed a second use of the same code
refused.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.2 · Sync

`reach sync` fetches new packages, verifies them, refreshes workspaces and fetches grade receipts. A workspace's
`README.md` is student-owned and preserved.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.3 · Workspace gate

`reach gate` runs from harness hooks: owned files are writable, anything else is refused, and coursework before
enrolment is blocked.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.4 · Check

`reach check` runs the one checker over the owned files: Ruby syntax, the Ruby 2.6 floor, shape, comments, test code,
purity, granted ports and Dovetail panel rules, each finding with a rule id, file, line and fix.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.5 · Checkpoint

`reach checkpoint save|list|show|restore` snapshots the owned files under `~/.reach/checkpoints`, with no git in the
workspace.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.6 · Plan

`reach plan save|note|show` keeps the slice plan at `<workspace>/.reach/plan.yml`, read back at every session start.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.7 · Submit and receipts

`reach submit` runs the check, submits the owned files and waits for a signed ingest receipt; `reach receipts` shows
them. The smoke matched the receipt ids Teach issued to the ones Reach stored.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.8 · Tips and remote acceptance

`reach tips` runs the tips suite locally. In a workspace whose `acceptance_mode` is remote it runs nothing locally
and shows the pending or returned signed results; `reach doctor` skips the gems check when every workspace is remote.
Grading at Teach needs its grader process and both Docker images.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.9 · Hands

`reach hand raise|status|list` sends a signed, encrypted context bundle to the instructors and polls for replies.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.10 · Course transcript

`reach gate prompt` captures every prompt a student submits in a course workspace on Claude Code or Codex, blocked
prompts included, into `~/.reach/transcripts/` before any gate check; the Stop and SessionEnd hooks and `reach sync`
send the queue to Teach (`POST /api/v1/transcripts`), which keeps one transcript per session for the instructors.
`reach transcript status` and `reach status` show what is sent and waiting. The student is told at enrolment and in
every greeting inside a course folder. Verified against Teach 0.8.0 on Ruby 3.3 and 2.6.10 (concurrent capture,
replay, offline and kill-switch queueing, a 200000-byte prompt). Antigravity sessions and the AI partner's replies
are not captured.

Build ✅ · Deploy 🔵 · Blocker: -

## 3 · Course reference

### 3.1 · Encrypted reference

`reach reference list|show|search|links` and the `reach_reference` MCP tool read RREF version 1 blobs, decrypted in
memory only, with the key from the guardrails package's `reference-keys.json` (wire protocol 1 revision 2026-09-28f).
Before enrolment, or with a Teach that sends no key, a blob is locked; a blob that fails authentication is refused.
The smoke covers pack, locked before enrolment, readable after sync and tamper refused.

Build 🟡 (a tampered key id reports locked rather than refused) · Deploy 🔵 · Blocker: Engineering.

### 3.2 · BUS 101 reference blob

`corpus/course-reference/bus-101.rref` carries 21 files: the Assignment 1 handout, the student quizzes, the
syllabus, the glossary and infographics, the Grokit module guide, the A1 course path, ten contracts and the A1
cutout extract, with the OpenStax textbook as a link. The plaintext copies were removed from the tree but remain in
the public GitHub history (the Initial commit) unless history is rewritten.

Build ✅ · Deploy 🔵 · Blocker: Human (the history rewrite decision).

### 3.3 · bus-201 reference

`corpus/course-reference/bus-201/` still ships unencrypted.

Build ✅ · Deploy 🔵 · Blocker: Engineering.

## 4 · Behaviour

### 4.1 · Agent writes the code, student decides

The persona and course skills have the agent implement all permitted code while the student makes the business
decisions; the agent never invents the student's reflection or contributions.

Build ✅ · Deploy 🔵 · Blocker: Human (the manual Codex dialogue pass has not run).

### 4.2 · Assignment one smoke

`tools/smoke/assignment_one.rb` is a deterministic, model-free run against a real Teach and Docker grader. The last
run, `~/.cache/reach-smoke/a1/20260928-203803`, recorded 31 pass, 2 skip (codex-conversation, lan-second-device) and
0 fail.

Build ✅ · Deploy ⚫ (never runs on a student's computer) · Blocker: -

## Appendix · Blocked by

- **Access**: 1.1, 1.2.
- **Human**: 1.3, 3.2, 4.1.
- **Engineering**: 3.1, 3.3.
