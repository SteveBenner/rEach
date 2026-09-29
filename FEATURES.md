# FEATURES — rEach

**The registry of the software features rEach carries, with build and deployment status.**

rEach is the student's course partner: it enrols a student with Teach, syncs signed course packages, guards the
student's workspace, checks and plans their slice, submits it and follows the receipts, inside the student's own
agent harness.

| | |
|---|---|
| **Registry version** | 0.9.0 |
| **Last audited** | 2026-09-29 |
| **Coverage** | Complete: every surface in `README.md` and `reach.spec.yml` (enrol, sync, check, checkpoint, plan, submit, receipts, hands, tips, setup, installer, reference, the intake interview and profile, the 17 MCP bridge tools, doctor's 18 checks, the shape checker's 19 rules, the public directive table, and each supported harness catalogued on its own). |
| **Running instance** | None: rEach is a cli and plugin. Deploy is judged against the released artifact. 0.9.0 is published on GitHub `main`; no student runs it against a hosted Teach yet, so most features stay 🔵 until one does. A live Codex session against a real Teach was run by the operator on 2026-09-29 (10.3), which is the one exception. |
| **Feature count** | 29 catalogued |

## How to read this registry

Build: ✅ Shipped · 🟡 Partial · 🟠 Scaffolded · ⚪ Planned.
Deploy: 🟢 Live · 🟣 Live on fixtures · 🔵 Built, not enabled · 🔴 Kill-switch OFF · ⚫ No runtime path.
For a cli, 🟢 means the version students actually run carries the feature. Blockers: Access · Intelligence ·
Temporal · Inference · Financial · Human · Engineering; a dash means nothing is outstanding.

| Build | Count | Share |
|---|---|---|
| ✅ Shipped | 29 | 100% |

| Deploy | Count | Share |
|---|---|---|
| 🟢 Live | 2 | 7% |
| 🔵 Built, not enabled | 26 | 90% |
| ⚫ No runtime path | 1 | 3% |

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

Build ✅ · Deploy 🔵 · Blocker: Human (Antigravity remains untested; the live Codex session ran 2026-09-29, see 10.3).

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

### 2.11 · Slice API reference

A workspace from Teach 0.9.0 carries `api/README.md` and `api/slice-api.json` generated by Grokit 0.3.0's
`bin/slice-api` (wire revision 2026-09-29b): the operation and its types, the granted ports and their methods for a
backend slice, and the root, hooks, props, client call and runtime primitives for a panel slice. CK-PORTS reads the
granted ports from the JSON and falls back to the README. Verified for every A1 cutout, both slices, on Ruby 3.3 and
2.6.10; with no Grokit root Teach writes the old list and a build warning.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.12 · Hookless-harness provenance

The submission seal carries `hooked` and a harness that falls back to `REACH_HARNESS`; Antigravity's rules file sets
it. Teach notes a hookless submission as unwitnessed instead of flagging it for review, behind
`<Teach setting>` (default `note`). `hooked` is self-reported from the student's ledger, so it is a
signal, not a guarantee.

Build ✅ · Deploy 🔵 · Blocker: -

## 3 · Course reference

### 3.1 · Encrypted reference

`reach reference list|show|search|links` and the `reach_reference` MCP tool read RREF version 1 blobs, decrypted in
memory only, with the key from the guardrails package's `reference-keys.json` (wire protocol 1 revision 2026-09-28f).
Before enrolment, or with a Teach that sends no key, a blob is locked; a blob that fails authentication is refused.
The smoke covers pack, locked before enrolment, readable after sync and tamper refused. A blob whose key id is
corrupted or forged, while we hold a different key for the same course, is refused rather than reported locked
(fixed 2026-09-29).

Build ✅ · Deploy 🔵 · Blocker: -.

### 3.2 · BUS 101 reference blob

`corpus/course-reference/bus-101.rref` carries 21 files: the Assignment 1 handout, the student quizzes, the
syllabus, the glossary and infographics, the Grokit module guide, the A1 course path, ten contracts and the A1
cutout extract, with the OpenStax textbook as a link. The plaintext copies were removed from the tree but remain in
the public GitHub history (the Initial commit) unless history is rewritten.

Build ✅ · Deploy 🔵 · Blocker: Human (the history rewrite decision).

### 3.3 · bus-201 reference

`corpus/course-reference/bus-201.rref` carries the syllabus draft, the online lecture map and the final dossier
rubric, packed 2026-09-29 from the same hand-vetted copy `TODO.md` already described, at parity with 3.2's format.
The plaintext it was packed from is kept only as a pre-deletion safety copy under `corpus/course-reference/.backup/`
(AGENTS.md Part E) pending a human's go-ahead to remove it.

Build ✅ · Deploy 🔵 · Blocker: -.

## 4 · Behaviour

### 4.1 · Agent writes the code, student decides

The persona and course skills have the agent implement all permitted code while the student makes the business
decisions; the agent never invents the student's reflection or contributions.

Build ✅ · Deploy 🔵 · Blocker: - (the manual Codex dialogue pass ran 2026-09-29).

### 4.2 · Assignment one smoke

`tools/smoke/assignment_one.rb` is a deterministic, model-free run against a real Teach and Docker grader. The last
automated run, `~/.cache/reach-smoke/a1/20260928-203803`, recorded 31 pass, 2 skip (codex-conversation,
lan-second-device) and 0 fail; both skipped scenarios (the manual Codex dialogue and the same-WiFi second device)
were separately exercised live by the operator on 2026-09-29, outside this deterministic harness.

Build ✅ · Deploy ⚫ (never runs on a student's computer) · Blocker: -

## 5 · Interview and profile

### 5.1 · Intake interview and student profile

`reach hello`'s first-run interview asks twelve single-thing questions (studies/year, coding and AI experience, the
course's own interview question, goal, explanation style, creative lead, work times, deadline reminders) and stores
the answers in `~/.reach/profile.yml` only — never synced to Teach, never in a workspace. `reach profile
show|save|forget` and the matching MCP tools manage it directly.

Build ✅ · Deploy 🔵 · Blocker: -.

## 6 · MCP bridge

### 6.1 · MCP tools beyond reference

The MCP bridge (`.mcp.json`, Claude Code and Cowork) exposes 17 tools beyond `reach_reference` (3.1): `reach_hello`,
`reach_enrol`, `reach_sync`, `reach_status`, `reach_check`, `reach_shape_check`, `reach_checkpoint`, `reach_plan`,
`reach_submit`, `reach_receipts`, `reach_tips`, `reach_raise_hand`, `reach_hand_status`, `reach_directive`,
`reach_profile_show`, `reach_profile_save`, `reach_profile_forget` — each a thin wrapper the agent calls instead of
shelling out to the `reach` CLI.

Build ✅ · Deploy 🔵 · Blocker: -.

## 7 · Doctor

### 7.1 · Doctor's individual checks

`reach doctor` runs 18 checks — Ruby version/floor, the shim, harness detection, enrolment, keys, guard state,
workspaces, Chrome (for the taste skill's pre-flight), gems, network reachability, the outbox, outdated packages,
the wire contract digest, version agreement across manifests, the persona files, the public directive table
(R-DOC-DIRECTIVES), the vendored taste skill's provenance (R-DOC-TASTE), and the sidecar — printing one line per
finding and exiting 1 if any fired.

Build ✅ · Deploy 🔵 · Blocker: -.

## 8 · Shape check

### 8.1 · Shape check internals

`Reach::Shape` runs 19 rules against a slice's panel once a shape has been published for it: 9 invisible-hazard
rules (S-LIF/S-ID/S-STO/S-DAT/S-EVT/S-KEY/S-DYN/S-I18N/S-CSS, one code each) and 10 visible-defect rules
(S-OVL/S-LAY/S-CSS/S-HTML/S-STATE/S-NAV). Findings without a published shape are reported as "nothing to check," not
an error. A real signed Dovetail shape has verified the parser end to end (0.4.2, 0.6.0). Since 0.9.0, when the
checker ran on a signed shape, `reach check` drops CK-PANEL's S-* findings, which CK-SHAPE already reports, and keeps
CK-PANEL-TS, CK-FUSE, CK-TEST and CK-COMMENT; with no shape or an unrunnable checker every CK-PANEL rule runs.

Build ✅ · Deploy 🔵 · Blocker: -.

## 9 · Directives

### 9.1 · Public directive table

`directives/` holds the public engineering directives (one Markdown file per opcode, frontmatter plus body,
88-character rule cap) rendered into `AGENTS.md`'s directive table; course-specific directives instead reach a
student only inside the encrypted guardrails package. `reach doctor`'s R-DOC-DIRECTIVES check keeps the two in
sync.

Build ✅ · Deploy 🔵 · Blocker: -.

## 10 · Harness integrations

### 10.1 · Claude Code

Terminal, desktop Code tab and VS Code, installed via `.claude-plugin/plugin.json` +
`.claude-plugin/marketplace.json`; connects the MCP bridge and the `SessionStart` hook. Verified with a scratch-home
`claude -p --plugin-dir` session (v0.2.0) that connected the bridge and opened with the greeting; no fresh session
was run this pass.

Build ✅ · Deploy 🔵 · Blocker: -.

### 10.2 · Claude Cowork

Claude desktop, plugin added from Customize > Plugins; the reason the executable lives at `exe/reach` rather than a
top-level `bin/` (Cowork refuses a plugin that carries one).

Build ✅ · Deploy 🔵 · Blocker: Human (no session has been run).

### 10.3 · Codex

CLI, IDE and desktop app, installed via `.codex-plugin/plugin.json` + `.agents/plugins/marketplace.json` (Codex
reads `hooks/hooks.json` through its manifest and sets `CLAUDE_PLUGIN_ROOT` for compatibility; it carries no MCP
server of its own, so Reach falls back to its CLI outside course workspaces). The operator ran a live Codex session
with the plugin installed on 2026-09-29 — hook-trust prompt, `SessionStart` context and greeting all confirmed — and
separately ran the manual Codex dialogue pass and the same-WiFi second-device test from `docs/smoke-assignment-1.md`
the same day.

Build ✅ · Deploy 🟢 · Blocker: -.

### 10.4 · Antigravity

Google's agent app and CLI (replaced Gemini CLI in 2026); reads `plugin.json` (Agent Plugins 1.0) and
`rules/reach.md` as its always-on pointer to `reach hello`. Antigravity has no documented hook format, so it ships
none; since 0.9.0 it runs `REACH_HARNESS=antigravity reach submit`, so Teach notes its submissions as unwitnessed
(2.12). `agy` is not installed on the development machine, so `reach setup --harness antigravity` and the
plugin-directory link are untested.

Build ✅ · Deploy 🔵 · Blocker: Human (no session has been run; `agy` not installed here).

## Appendix · Blocked by

- **Access**: 1.2.
- **Human**: 1.3, 3.2, 10.2, 10.4.
- **Engineering**: 1.1 (the Windows installer path is unverified).
