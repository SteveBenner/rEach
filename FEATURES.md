# FEATURES — rEach

**The registry of the software features rEach carries, with build and deployment status.**

rEach is the student's course partner: it enrolls a student with Teach, syncs signed course packages, guards the
student's workspace, checks and plans their slice, submits it and follows the receipts, inside the student's own
agent harness.

| | |
|---|---|
| **Registry version** | 0.35.1 |
| **Last audited** | 2026-10-05 |
| **Coverage** | Complete: every surface in `README.md` and `reach.spec.yml` (enroll, sync, check, checkpoint, plan, qualify, the attempt ladder, the feature and bug flows, submit, receipts, hands, setup, installer, reference, the intake interview and profile, the 26 MCP bridge tools, doctor's 18 checks, the shape checker's 19 rules, the public directive table, the course record, the course folders, each supported harness catalogued on its own, and the surfaces in `lib/reach/cli.rb`'s usage text, `hooks/reach.hooks.yml`, `skills/`, `update/`, `runtime/` and `CHANGELOG.md` through 0.16.21, with planned work in section 11). |
| **Running instance** | None: rEach is a cli and plugin. Deploy is judged against the released artifact. 0.11.0 is published on GitHub `main`; no student runs it against a hosted Teach yet, so most features stay 🔵 until one does. A live Codex session against a real Teach was run by the operator on 2026-09-29 (10.3), which is the one exception. |
| **Feature count** | 95 catalogued |

## How to read this registry

Build: ✅ Shipped · 🟡 Partial · 🟠 Scaffolded · ⚪ Planned · ⛔ Torn down.
Deploy: 🟢 Live · 🟣 Live on fixtures · 🔵 Built, not enabled · 🔴 Kill-switch OFF · ⚫ No runtime path.
For a cli, 🟢 means the version students actually run carries the feature. Blockers: Access · Intelligence ·
Temporal · Inference · Financial · Human · Engineering; a dash means nothing is outstanding.

| Build | Count | Share |
|---|---|---|
| ✅ Shipped | 87 | 92% |
| ⚪ Planned | 6 | 6% |
| ⛔ Torn down | 2 | 2% |

| Deploy | Count | Share |
|---|---|---|
| 🟢 Live | 6 | 6% |
| 🟡 Partly live | 1 | 1% |
| 🔵 Built, not enabled | 77 | 81% |
| ⚫ No runtime path | 11 | 12% |

## 1 · Install

### 1.1 · Public-ZIP installer

`scripts/reach-install` installs from the repository's public ZIP without Git or a GitHub login, using a pure-Ruby ZIP
reader. It materialises symlinks safely, because the smoke found that the repository's `CLAUDE.md` symlink blocked
installs from the public archive. It backs up an existing install, downloads the Dovetail archive pinned in
`dovetail-revision.txt`, enforces size and count limits and bounded retries, and stops when
`REACH_INSTALL_KILL_SWITCH` is set. GitHub's archive carries the `dovetail` submodule as an empty directory, which the installer replaces (0.7.1, found by
the first public run). `tools/smoke/assignment_one.rb --public` installed from the real public GitHub ZIP on 2026-09-28.
Since 0.34.1 (`STD-STUDENT-TREE`) `.gitattributes` keeps developer material (`tools/`,
`.githooks/`, `.github/`, the smoke and deploy notes, figure 08) out of the archive the installer and every update
download, after a student's agent asked to use the instructors' local server port it had read in those notes.
Since 0.34.3 (`STD-USER-HOME`) the installer, the hook launcher and `Reach::Paths` take the Windows profile folder
from Windows instead of `HOME`, which had created `C:\Users\anon` on a student's computer; they never create a
missing user folder, and an install that landed under a stray home moves to the profile by the relocation. Checked
on Linux and in a simulated Windows run; the known-folder, registry and PowerShell lookups have not run on a student's
Windows computer.

Build ✅ · Deploy 🟢 · Blocker: Engineering (the Windows path is unverified).

### 1.2 · Dovetail submodule

Dovetail is a git submodule at `dovetail`, pinned by `dovetail-revision.txt`, which the smoke checks against the
gitlink.

Build ✅ · Deploy 🔵 · Blocker: Access (not pushed).

### 1.3 · Harness setup

`reach setup` installs rEach into the detected harnesses through their own install commands and ends with the NEXT
block the installing agent reads to the student. It exits 1 and prints no installed text or greeting when nothing was
installed, including the manual branches taken when a harness CLI is missing. Since 0.16.5 `INSTALL.md` runs the
bootstrap download, the installer and setup as one command, so an app that sandboxes commands (Codex) asks the student
once; the macOS/Linux command ran end to end with `--harness codex` in a scratch home on 2026-10-01.

Build ✅ · Deploy 🔵 · Blocker: Human (Antigravity remains untested; the live Codex session ran 2026-09-29, see 10.3).

### 1.4 · Automatic updates

Since 0.13.0 Reach keeps a managed `~/.reach/plugin` install current by itself, from GitHub releases and tags together
(since 0.16.14 the newest version from either, so a tag newer than the last release is offered), checked at session start and hourly from detached processes, staged in the background and installed at the
next session start by the release's own `update/apply.rb`, with every phase in `~/.reach/state/update.json` so an
interrupted update resumes (`reach update status|check|run`). Verified 2026-09-30 against a GitHub-shaped local HTTPS
mirror (real releases API and real Dovetail archive): the login install, the mid-session stage and notices, a kill
mid-download, a crash after the swap and both crashes between the renames all completed, and a real Claude Code
plugin cache moved from 0.12.9 to 0.13.0 through the refresh. Students on 0.12.0 or earlier have no updater and need
one manual reinstall; only tagged versions are offered.

Build ✅ · Deploy 🔵 · Blocker: Human (no student install has received a real release through it yet; Codex refresh and Windows unverified).

### 1.4.1 · The agent updates only through Reach

Since 0.18.1 (`STD-AGENT-UPDATE`) the persona's "Updating rEach" section, `M-AGENT-UPDATE` in `reach hello`'s
context and `INSTALL.md` tell the agent to update with `reach update run --apply` and never to search GitHub's
releases or tags or download an archive itself, after a rEach agent called GitHub's web index "noisy" while looking
for a tagged ZIP. GitHub's releases page then listed only Ruby runtime kits, with `runtime-4.0.7-r3` marked Latest.
v0.18.1 is the first rEach version with its own GitHub release, marked Latest. Verified 2026-10-02 with Sonnet
given the persona and the signed-in context: a student "who doesn't really know computers" got a plain answer with no
command, and a self-described engineer who asked for the command got `reach update run --apply`.

Build ✅ · Deploy 🔵 · Blocker: Temporal (students receive it on their next auto-update).

### 1.4.2 · reach --version

Since 0.18.1 (`STD-CLI-VERSION`) `reach version`, `reach --version` and `reach -V` print `reach <VERSION>` and exit 0,
enrolled or not. Verified 2026-10-02 in scratch HOMEs, before and after enrolling against `tools/fake_teach`.

Build ✅ · Deploy 🔵 · Blocker: Temporal (students receive it on their next auto-update).

### 1.5 · Installation and setup guide

Since 0.16.13 `docs/INSTALLATION-AND-SETUP-GUIDE.docx` is the student setup handout with no institution, instructor,
course or term in it. It covers installing the AI app, the one install message, the approvals and extra steps each
app and computer needs (in Codex: running the install outside the sandbox, Full access on Windows, trusting rEach's
hooks and each course folder's hooks), enrollment and sign-in, with official vendor screenshots. `reach guide`
prints its text from the .docx with the standard library and works while Reach is locked. Until the student is
enrolled, every session's locked context tells the agent to read it, and to walk the student through the extra
steps first when the student's messages reach it while locked (Hermes gets the same note after its relay).
`INSTALL.md` has the installing agent use it for setup's host steps. Ran 2026-10-01 from the checkout in a scratch
home: `reach guide`, `--path`, `--format json`, the shim, locked `reach hello` (text and hook) and the Hermes
locked prompt hook.

Build ✅ · Deploy 🔵 · Blocker: Human (no student has been walked through it by an agent yet; its prose is not checked against the code, so a later change to enrollment or the install can leave it stale).

### 1.6 · Runtime kit build pipeline

`.github/workflows/runtime.yml` builds the per-platform runtime bundles when a tag `runtime-<ruby>-r<n>` is pushed:
`runtime/package.rb` stages the Ruby and the prebuilt gems from `runtime/locks/<profile>/`, `runtime/build_ruby_linux.sh`
builds the Linux Ruby from source in a manylinux_2_28 container, `runtime/relocate_check.rb` moves each bundle and
proves Ruby, the native gems, the glibc ceiling and a headless Chrome page, and `runtime/manifest.rb` writes
`runtime-manifest.json`, which is published as a GitHub release that is never marked latest
(`runtime/RELEASE_NOTES.md` is its body). Run 36838426832 (`runtime-4.0.7-r2`) failed the Windows relocation check on a
Chrome that still held `chrome.dll`; 0.16.3 fixed the cleanup and `runtime-4.0.7-r3` passed on all five platforms and was
published. Unverified: linux-arm64, macOS and Windows kits are built and relocation-checked in CI only, and Google
publishes no Chrome for Testing for Linux arm64, which uses the distribution's chromium.

Build ✅ · Deploy 🔵 · Blocker: Human (no student computer on those platforms has installed a kit).

### 1.7 · Student and agent documents

`README.md`, `INSTALL.md` (the installing agent's script), `docs/student-guide.md` (what a student reads, including
the model guidance for Hermes), `docs/smoke-assignment-1.md` (the manual passes), `docs/DESIGN-DECISIONS.md` (the
standing product decisions, latest form only), `docs/course-alignment-design.md`, `ROADMAP.md`
(Reach 2.0 version control), `docs/architecture.md` (ten figures of rEach and Teach together, light and dark, drawn
by `tools/figures/build.rb` into `docs/assets/figures/`; Teach appears only as a frosted block that names outcomes,
`STD-FIGURES`) and `docs/deploy-and-test.md` (the fixture walkthrough and the two smoke runs, every command run
first). The public docs name no Teach class, table, setting or command (`STD-TEACH-OPAQUE`). `docs/INSTALLATION-AND-SETUP-GUIDE.docx` is catalogued at 1.5. The student guide's
Privacy and Course folders wording was written before 0.16.12 and has not been re-audited against it.

Build ✅ · Deploy 🔵 · Blocker: Human (prose is not checked against the code).

### 1.8 · Ruby bootstrap

Since 0.20.7 (`STD-RUBY-BOOTSTRAP`) rEach starts on a computer with no Ruby. The plugin's hooks and MCP server run
`sh exe/reach-run`, which uses a Ruby on PATH, else the runtime kit's, else downloads and verifies the kit's Ruby against
`exe/runtime-pins` in the background while the agent tells the student to send their message again in a minute; on
Windows `scripts/reach-install.ps1` does the same for the install and adds the Ruby to the user PATH. Verified in Debian
containers with no Ruby under dash and busybox sh (first prompt in 0.06 s, kit in 8 to 43 s, then the normal enrollment
greeting), a tampered pin refused with back-off, five parallel hooks starting one download, and byte-identical output
with a Ruby on PATH on Ruby 2.6.10 and 3.3. Not run on macOS bash 3.2, Windows Git Bash, Cowork, or the PowerShell
script.
Build ✅ · Deploy 🔵 · Blocker: Human (run once on a Windows Cowork computer without Ruby).

## 2 · Course flow

### 2.1 · Enroll

`reach enroll <code> --teach-url URL` generates keys and enrolls with Teach. Before it writes any key it verifies the
response fields and `minimum_reach_version`. Since 0.29.1 a wire digest that differs from Teach's no longer refuses
the enrollment (`reach doctor` reports it as `R-DOC-WIRE`); verified against the fake Teach with a changed digest
(2026-10-04). The smoke showed a second use of the same code
refused. Since 0.10.0 it posts to `/api/v1/enroll` and retries once at `/api/v1/enrol` on a 404; `reach enrol` and the
`reach_enrol` tool still work, unlisted. A Teach 0.10.0 refuses a too-old Reach before spending the code
(`reach_outdated`), and Reach shows why; verified through a proxy that 404s the new route. Since 0.16.19
`config.yml` `teach.url` is `https://sven-f1l1.tail062fd2.ts.net`, so `--teach-url` is optional. Since 0.16.20 no
path asks for it: `reach_enroll` takes no `teach_url`, help hides `--teach-url`, and the identity rules accept
six- or seven-digit IDs and an optional trailing username letter, matching live Teach. Since 0.16.21 the last step
is a password the student chooses twice (at least 8 characters) and is told to write down; the hook hides it from
the agent, Hermes students finish in a terminal, and Teach keeps only its scrypt hash. Since 0.18.2 `reach setup`
and `update/apply.rb` write `teach.url` to `~/.reach/state/teach.json`, read after `REACH_TEACH_URL` and `config.yml`,
so an install whose `config.yml` is missing or broken still enrolls against Teach; verified in a scratch `REACH_HOME`. Since 0.21.11 `Reach::Runtime::TEACH_URL` builds the same URL in as the last resort, and a terminal enroll that cannot reach Teach names the URL and the network cause instead of saying the work is saved. Since 0.21.13 enrollment requests leave the Teach connection state alone, so that message is the only line; verified against live Teach from a scratch home (one line on failure, no `link.json` written, no reconnect line after a successful preview).

Build ✅ · Deploy 🔵 · Blocker: -

### 2.2 · Sync

`reach sync` fetches new packages, verifies them, refreshes workspaces and fetches grade receipts. A workspace's
`README.md` is student-owned and preserved.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.3 · Workspace gate

`reach gate` runs from harness hooks: owned files are writable, anything else is refused, and coursework before
enrollment is blocked.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.4 · Check

`reach check` runs the one checker over the owned files: Ruby syntax, the Ruby 2.6 floor, shape, comments, test code,
purity, granted ports and Dovetail panel rules, each finding with a rule id, file, line and fix. The rules are
CK-RUBY-SYNTAX, CK-RUBY-FLOOR, CK-RUBY-SHAPE, CK-COMMENT, CK-TEST, CK-PURE, CK-PORTS, CK-FUSE, CK-PANEL (with Dovetail's
S-* ids) and CK-SHAPE; `--format text|agent|json|hermes` and `--changed <path>` serve the post-write hooks.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.5 · Checkpoint

`reach checkpoint save|list|show|restore` snapshots the owned files under `~/.reach/checkpoints`, with no git in the
workspace.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.6 · Plan

`reach plan save|note|show` keeps the slice plan at `<workspace>/.reach/plan.yml`, read back at every session start.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.7 · Submit and receipts

`reach submit` runs the check, refuses unless the latest qualification passed on exactly the current owned files and
scenarios, submits the owned files with the scenarios and the passing record as evidence, and waits for a signed
ingest receipt; `reach receipts` shows them. Since 0.11.0 the check counts only findings in the slice's own files, so a
panel slice is no longer blocked by a shape finding in an instructors' file its workspace does not hold. The smoke matched the receipt ids Teach issued to the ones Reach stored.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.7b · Submit approval, Downloads copy and resubmission

Since 0.17.0 (wire 2026-10-02c) the agent offers to submit once a slice passes its checks; `reach submit` asks the
student through rEach and sends only on a hook-captured yes (a terminal prompt in a terminal, the agent's relayed yes on
Antigravity). After the ingest receipt it saves a ZIP of the whole assignment in the Downloads folder, named with the
course, assignment and course-time stamp, and says until when the student may submit again; after the due time a
submitted slice is refused before asking. The assignment-one smoke asked, captured the yes, submitted and checked the
ZIP against a scratch Teach 0.18.0; resubmission and the past-due refusal were exercised against the fake Teach.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.8 · Qualification

`reach qualify` proves a slice before submission: `reach check` on the owned files, coverage of every graded scenario
name by the agent's own scenarios in `qualify/features`, those scenarios run here against Grokit's answer-free kit when
the slice allows it (and again on the starting copy, where they must fail), then an ungraded qualification on Teach
(W-API-QUALIFY) that runs the agent's scenarios on the real build and on the starting copy and the instructors' hidden
scenarios. `--list` prints the tag and graded names; `--local-only` never counts. Verified end to end on 2026-09-29
against a scratch Teach 0.11.0 and Grokit 0.5.0, a backend slice (context.a1) and a panel slice (finance.a1). Replaces
`reach tips`, which is gone. Since 0.14.5 a panel slice's local run that asks the practice recording for an answer it
does not hold gives QF-PRACTICE instead of QF-LOCAL-FAIL, naming `qualify/kit/practice/README.md`, and the record
carries `practice_readme`; checked on 2026-10-01 with one such row and one ordinary failure, which gave QF-PRACTICE and
QF-LOCAL-FAIL. Since 0.21.2 the Teach half (upload and polls) runs under its own 20-second deadline after the local steps, so an MCP
qualify whose local steps outlast the 25-second tool budget still reaches Teach; verified on 2026-10-03 in the slice-build
smoke (run 20261002_215550, context.a4s2, on the same change over 0.20.5), where both qualifications reached the scratch
Teach and finished, against none in the run before. Since 0.33.5 (`STD-KIT-CLEAN-ENV`) every launch of the kit Ruby unsets
the computer's own Ruby and Bundler variables (`RUBYLIB`, `RUBYOPT`, `GEM_*`, `BUNDLE_*`): a student's Ruby 3.3.8
exported `RUBYLIB`, so the kit Ruby 4.0.7 died at start and qualify never ran; reported on 2026-10-05. Checked on
Linux with those variables set: `Reach::Suite.install_gems` and `cucumber` on a Grokit kit fail with the student's
error on 0.33.4 and run (exit 0) on 0.33.5; the student's own machine and macOS/Windows not yet run.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.9 · Hands

`reach hand raise|status|list` sends a signed, encrypted context bundle to the instructors and polls for replies.
Since 0.11.0 the bundle is `reach.hand/v2`: originator (agent or student), the task, the attempt history, every owned
file and scenario file in full and the last qualification's output. Since 0.14.4 a hand Teach refuses says why
(M-HAND-REFUSED with Teach's reason, from the CLI and the reach_raise_hand tool) and a hand that could not reach Teach
says it was saved for later (M-HAND-QUEUED); verified 2026-10-01 against a scratch Teach with hand-raises disabled,
enabled and stopped. Since 0.25.1 (`STD-UTF8-BUNDLE`) the bundle is built as UTF-8 in every locale: an app that starts
rEach with no locale (Claude Desktop on macOS) made `reach_raise_hand` fail on the first non-ASCII character in an
owned file; a student reported it on 2026-10-04. Exercised with a C locale on Linux only.

Build ✅ · Deploy 🔵 · Blocker: -.

### 2.10 · Attempt ladder

Reach counts failed qualifications per slice: the second prints a notice for the student, the third raises an agent
hand and holds further passes and writes until `reach attempts continue` records the student's yes (accepted only
after a student prompt typed since the hand; only the time of the last slice prompt is kept), and the tenth stops everything until an instructor replies. A pass or a reply
resets it. Verified end to end on 2026-09-29.

Build ✅ · Deploy 🔵 · Blocker: -.

### 2.11 · Feature and bug flows without git

The reach-feature and reach-bug skills are the only ways the agent writes code (directive R-FLOW); both overwrite
files in place and use checkpoints as history. The gate refuses git in slice workspaces and at the course folder's
top (M-GATE-NOGIT); the extracurricular folder is the student's own. Git support is planned for Reach 2.0 (ROADMAP.md).

Build ✅ · Deploy 🔵 · Blocker: -

### 2.12 · Course record (transcript capture)

Since 0.25.0 (wire revision 2026-10-03i, `STD-TRANSCRIPT`) rEach records the conversation while a student is signed in
and working on an assignment: the session is signed in, the course has a current assignment, and the session runs in a
slice or the course folder root. Inside those bounds it records every prompt, the AI's replies, reasoning and actions,
and the assignment code (code blocks in replies, each AI write, and a turn-end scan of the slice's owned files), spools
them in `~/.reach/transcripts/` and sends them to `POST /api/v1/transcripts` at turn end, on `reach sync` and before a
submission. Outside the bounds (before sign-in, in the extracurricular folder, outside the course folder, in instructor
mode) nothing is written or sent, and a session's recording never reads what the harness transcript held before its
first recorded prompt. The feature existed from 0.8.0 to 0.20.x, was torn down in 0.21.1 and restored in 0.25.0 with
these bounds; rEach no longer deletes `~/.reach/transcripts`. Verified 2026-10-03 on a scratch course: 15 entries of
every kind arrived, and an unsigned session and an extracurricular session recorded nothing. Not verified: a real
Claude Code, Codex or Hermes session on a student computer. Since 0.26.0 (`STD-TRANSCRIPT-DEIDENTIFY`, wire revision
2026-10-04a) a transcript leaves the computer de-identified: a random pseudonym per install, placeholders for the
identifiers rEach knows, and an identity index encrypted to the course's re-identification key, which only its holder
can open. Verified 2026-10-04 on a scratch course: a signed-in session whose prompt, reply, reasoning, action and code
held the student's name, ID, username and home folder arrived with none of them in any stored file, the own-part
lookup still matched, and an older client was told to update and kept its queue. Since 0.26.1 (wire revision
2026-10-04b) re-identification is exact: each entry carries an encrypted record of the strings its placeholders
replaced and of any text that no longer fit, so the key holder gets back the text as recorded, capitals included.
Build ✅ Shipped · Deploy 🟢 Live (released 2026-10-04 as v0.26.0, exact restore in v0.26.1, GitHub Latest; Teach 0.40.1 hands out the key and accepts the entries). No real student session has been recorded yet.

### 2.46 · Transcript stream
Since 0.32.0 (`STD-TRANSCRIPT-STREAM`, wire revision 2026-10-04i, W-TRN-7) the course record of 2.12 is whole and is
sent in the background, inside the same bounds. A background sender runs at the interval the course sets in Teach
(`transcripts.send_interval_s`, 600 s by default, never under 60 s): rEach's MCP server starts it from an open session
and the operating system job runs it too, so nothing waits for a turn end or a submission. Each run reads the harness
transcript and, on Claude Code, each subagent transcript from where rEach last stopped. What a tool returned to the AI
is recorded as an output entry, and a long prompt, reply, reasoning block, action input or tool output is split across
entries with `part` instead of cut. `reach transcript stream [--force]` runs it by hand, and the student's own export
shows tool output. Verified 2026-10-04 on a scratch course against Teach 0.46.0: with no hook running after the
prompts, one run from another folder sent 17 entries of every kind; a 180013-byte prompt and a 306000-byte command
output rejoined exactly; a second run inside the interval sent nothing; a course policy change to 60 s arrived by sync,
held a run at 45 s and let one through at 61 s; a prompt and reply in the extracurricular folder were neither recorded
nor sent, also after the session returned to its slice; a real `reach mcp` server sent a mid-turn reply by itself
within 90 s; and the full assignment smoke kept its 40 passes and 2 skips. Not verified: a real Claude Code, Codex or
Hermes session on a student computer, and the macOS and Windows background jobs. Hermes records no tool output, and
code entries still stop at 131072 bytes of text.
Build ✅ · Deploy 🟢 Live (released 2026-10-04 as v0.32.0, GitHub Latest; Teach 0.46.0 sets the interval). No transcript has arrived from a student yet.

### 2.13 · Slice API reference

A workspace from Teach 0.9.0 carries `api/README.md` and `api/slice-api.json` generated by Grokit 0.3.0's
`bin/slice-api` (wire revision 2026-09-29b): the operation and its types, the granted ports and their methods for a
backend slice, and the root, hooks, props, client call and runtime primitives for a panel slice. CK-PORTS reads the
granted ports from the JSON and falls back to the README. Verified for every A1 cutout, both slices, on Ruby 3.3 and
2.6.10; with no Grokit root Teach writes the old list and a build warning.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.14 · Hookless-harness provenance

The submission seal carries `hooked` and a harness that falls back to `REACH_HARNESS`; Antigravity's rules file sets
it. Teach notes a hookless submission as unwitnessed instead of flagging it for review, by a
course server setting (default: note). `hooked` is self-reported from the student's ledger, so it is a
signal, not a guarantee.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.15 · Course folders and extracurricular

`~/reach-work` holds `deliverables/<course>/<assignment>/<cutout>-<slice>/` (every slice; a sync moves older slice
workspaces there and never deletes one) and `extracurricular/`, the student's own code folder, never graded or
submitted, opened with `reach work --extracurricular`. Each folder, the root included, gets its own rules and
hooks: extracurricular allows writes only inside itself, the root refuses every write, and the public directive
CODEFILE tells the agent to put code in files, never in chat.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.16 · Receipt acknowledgments and preservation

Since 0.11.5 (wire revision 2026-09-30), every receipt Reach verifies and stores gets a receipt of its own. This is
a `reach.receipt-ack/v1` record at `~/.reach/receipts/acks/<receipt_id>.json`, signed with the install key and
carrying the digest of the receipt as received. Reach sends it to Teach, which links it to its receipt. The sends
happen at submit, at a grade poll and on `reach sync`. Sync also fetches any receipt Teach holds that this computer
lacks. `reach receipts acks` lists the records, and `reach status` counts confirmed, waiting and mismatched ones. The
A1 smoke against a scratch Teach 0.11.2 linked the ingest and grade receipts. Then, on the same scratch Teach:
- a deleted ingest receipt came back byte-identical on sync;
- Teach refused a tampered digest (409), a bad signature (400), an extra field (400), a wrong kind (400) and an
  unknown receipt (404);
- with the kill switch on, the acknowledgment stayed pending and linked on the next sync after it was turned off.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.17 · Sign-in every session

Since 0.12.0 the prompt hook asks for the student ID, then "Am I speaking with <name>?", and waits for a yes, blocking each step so the agent never sees the ID or the answer. Wrong IDs lock the session after three tries; a no ends course work for the session; both reach Teach as integrity events. The A1 smoke signs in this way before any write. Re-verified 2026-10-01 against a scratch Teach: every gate refused before sign-in, the ID stayed out of the greeting, another student's ID was refused, offline sign-in worked, three wrong tries locked the install for a minute, and Teach recorded login_failed and identity_denied.

Since 0.28.0 (`STD-SIGNIN-PASSWORD`, wire revision 2026-10-04d) the yes is followed by the password the student chose at enrollment, and the session is signed in only when it is right; the check is the prompt hook's, not an instruction to the agent. `forgot password` starts a reset that works once an instructor allowed one. Verified 2026-10-04 on a scratch Teach: the A1 smoke (40 pass, 2 skip) signs in with a wrong and then the right password; a write stayed refused until the password; with the verifier deleted the server was asked, and with the server stopped the sign-in waited; three wrong passwords locked the session; the reset set a new password and the old one stopped working on the computer, at the server and at a second enrollment; Hermes was sent to `reach login password`; no password appeared in the database dump, the server log or any rEach file. 🔵 until a student signs in this way on a hosted Teach.

Since 0.21.5 the plugin's own prompt hook signs the student in too (`STD-SIGNIN-PLUGIN-HOOK`): in Codex in every folder, keyed on Codex's `turn_id` so that when a course folder's hook also runs, only one of them judges the prompt; in Claude Code outside the course folders. Before, the sign-in lived only in each course folder's `.codex/hooks.json`, which Codex never runs until the student trusts it, so a Codex student on Windows (hand 2026-10-03, Reach 0.21.1) was told to wait for a question nothing asked. Verified by the platform smoke on Linux (15 passed): ask, confirm, yes, a second hook on the same turn silent, the signed-in context on the next turn, then the gate open. Not verified: a live Codex session on Windows.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.18 · The student's own part

Since 0.12.0 `reach part` lists the questions only the student can answer, `reach part record` takes their typed words verbatim, and `reach submit` refuses until all are answered and sends `part.json`. Since 2026-10-03 the prompt hook keeps only the latest long enough prompt in `~/.reach/state/part/pending.json`, `reach part record` takes it and deletes it, and the answer carries no session or seq; Teach stores answers as sent and checks nothing against a conversation. In the 0.12.0 smoke, submit was refused without the part and four answers were recorded. Re-verified 2026-10-01: a two-word answer was refused as too short, and in live sessions Haiku and Sonnet coached the own part on process only, without candidate answers.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.19 · Modules, module choice and transfers

Since 0.12.0 Reach verifies Teach's signed module record and refuses writes in another module's slice. In a choose-your-modules course the student locks in two modules with their own yes; `reach transfer request` asks the professor to confirm a move. On scratch data a student chose and locked two modules, a second choice was refused, a transfer was approved, and an instructor reassignment moved the student's slices. Since 0.14.3 Reach acts on the student's yes or no itself from the prompt hook, and a send that had to queue is flushed by a detached process. Re-verified 2026-10-01: the ask sent nothing; the yes alone sent it (Teach had it 3 s later); a second request while one was open was refused; a denial showed the professor's reply; approval moved the modules; a write in the old module was refused; a reassignment without a reason was refused; a choice locked on the yes, a second choice was refused, and a full module was refused. Live on Haiku and Sonnet, rEach ran the request, relayed Reach's question, and Teach received exactly one transfer after the yes.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.20 · Sandbox and drag-and-drop files

Since 0.12.0 the read and shell gates refuse paths outside the workspace and web lookups in course folders, on Claude Code, Codex and Hermes. A dropped file is copied into `materials/` within size and type limits. Driven with hook events on Claude Code; the Codex and Hermes hooks are configured but not run live. Re-verified 2026-10-01: Read, Grep, Glob, shell cat, ls of the home folder, cp and both web tools were refused outside the workspace; a .txt drop was copied, an .exe and an oversized file were refused; live, Sonnet declined to search Documents, and the dropped file was copied into materials/ and read there.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.21 · Time gate

Since 0.12.0 writes are refused in a slice that is not the current assignment or whose due time has passed, by Teach's clock. Re-verified 2026-10-01: an unreleased A2 was not delivered, and a past-due or non-current slice gave M-GATE-NOT-CURRENT.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.22 · Next step and focus anchor

Since 0.12.0 `reach next` names the student's next step, and every prompt gives the agent a short anchor naming the current step. The directives COACH, PACE and FOCUS carry the tone and topic rules; judged live on 2026-10-01 with Haiku and Sonnet: rEach stayed on the course through a chain of off-topic questions, declined life advice and pointed to people who can help, and coached a stuck student without writing the answer. Haiku occasionally praised more than the COACH rule allows and once described a step inaccurately; agents sometimes named code or files to the student.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.23 · Support in a crisis

Since 0.12.0 `reach support` prints a fixed message beginning "If this is an emergency, call 911 now." and raises a wellbeing hand to the instructors; the prompt hook catches crisis phrases even before sign-in. On scratch data the hand reached Teach's queue, listed first, within seconds. Since 0.14.3 the session context, the skill and the agent put a crisis before the greeting; live on Sonnet and Haiku the first reply gave 911 and 988 with no greeting, and Teach got a wellbeing hand.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.24 · Local size limits

Since 0.12.0 `reach sync` kept the transcript spool under the course's caps (removed with the spool 2026-10-03, restored in 0.25.0), and `reach doctor` reports the sizes. Since 0.15.0 the corpus spool waiting for admission is measured and reported but never pruned, because admission depends on every line. Re-verified 2026-10-01: the caps come from vault/guardrails/course.yml and doctor printed R-DOC-LIMITS.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.25 · Portable runtime kit

Since 0.14.0 `reach runtime install` puts Ruby 4.0.7 with the course gems prebuilt and Chrome for Testing 154.0.8037.92 under `~/.reach/runtime`, verified against a pinned manifest, and local qualification runs on them. Exercised on Linux x86_64 from the published release into a scratch home, with a backend scenario passing under the runtime Ruby and Chrome; the other four platforms are built and relocation-checked in CI only. The published r1 Linux kit needs glibc 2.38 and fails on Debian 11/12 and Ubuntu 22.04. Since Reach 0.14.6 the workflow builds the Linux kits from source in a manylinux_2_28 container for glibc 2.28; a locally built linux-x86_64 kit installed in clean debian:bullseye and ubuntu:22.04 containers and ran Ruby 4.0.7 and Cucumber 11.1.1, and both Linux kits passed in CI under runtime-4.0.7-r2, but its Windows build failed the relocation check because Chrome still held chrome.dll during cleanup. Reach 0.16.3 fixed the cleanup, runtime-4.0.7-r3 passed on all five platforms and was published, and since 0.16.4 Reach pins r3. `reach runtime status [--json]` shows the active kit, `reach runtime remove --yes [--old]` removes it, and `reach runtime
install --from DIR` installs from a folder of release files so a classroom can share one download. When Chrome's system libraries are missing, `reach runtime install` names them. Since 0.16.5 the session-start hook installs the kit in the background when it is missing (`config.yml` `runtime.auto_install`, default on; a lock, an hourly jittered limit and five attempts per pinned kit), so nobody asks the student; verified on Linux x86_64 in a scratch home and inside `codex sandbox`, where nothing starts. Before 0.16.10 it skipped any computer that already had a kit, so a student who installed r1 kept it after the pin moved to r3; since 0.16.10 it also starts when the active kit is not the pinned one, and the older kit stays on disk. Verified on Linux x86_64 in a scratch home holding an r1 kit: the background run installed the published r3 kit in 36 s, `runtime/current` moved to r3 and the r1 directory was kept.

Build ✅ · Deploy 🔵 · runtime-4.0.7-r3 published and pinned; installed from the release by the platform smoke on Linux x86_64, macOS arm64, macOS x86_64 and Windows x86_64 GitHub runners; no student machine yet, and Linux arm64 is relocation-checked only

Before 0.21.11 the macOS kits could not make a verified HTTPS request: their OpenSSL looks for CA certificates only under the build machine's `/opt/homebrew/Cellar/rv-portable-openssl` path, and since 0.21.3 every command on macOS's Ruby 2.6 runs under the kit, so a Mac student with the kit could not enroll, sync or update (field report 2026-10-03, Antigravity on macOS). Since 0.21.11 `exe/reach` points `SSL_CERT_FILE` at the kit's own `libexec/cert.pem` (`STD-CA-ROOTS`). Verified on Linux x86_64 against live Teach with a copy of the kit given the macOS kit's `cert.pem` and every system CA path hidden: without the fix `certificate verify failed`, with it Teach answered the enrollment preview. Not yet run on a Mac.

### 2.26 · Microbrain records

Since 0.15.0 every note, tip, attempt, receipt and qualification is first an rcorpus.spool/v1 line in `<rplugin state>/reach/brain-spool/`, written on any Ruby, and is admitted into Reach's own corpus (private tier, `tiers.split`) as soon as rplugin and rcorpus load. The ledger never depends on the corpus. Verified 2026-10-01 in scratch homes: without the SDK, a note, a receipt and a qualification landed as spool lines and `recent` returned them; with the SDK and a minted corpus, the same writes were admitted into `kv.private.jsonl` and `rcorpus check` reported 0; a corpus-fallback file migrated once and a rerun added nothing; with the corpus unwritable, the qualification still reached the ledger and the failure was logged. The live `~/.corpora/reach` (empty) was given the five kinds and `tiers.split`, and `rplugin corpus verify` reports 0.

Build ✅ · Deploy 🔵 · Blocker: -.

### 2.27 · Enrollment v2 and lockdown

Since 0.16.0 rEach does nothing until it is enrolled. A plugin-level prompt hook blocks every prompt in every
harness session and asks, one at a time, for the class-wide course passkey (since 0.18.1 the student-facing name of the wire's course
code, `STD-COURSE-PASSKEY`; `BUS101-K7QX-94TD`, typed any way:
dashes, spaces, case and O/0, I/L/1 in the secret are forgiven; a course id within two edits still matches), the
school username (`FLLLNNN@school.example`) and the student ID. It confirms, then enrolls with wire
shape v2. Teach answers with a signed enrollment stamp binding the install, the student, the course and a salted,
hashed fingerprint of the computer, the account and the install key. Every CLI verb except help, enroll, setup,
doctor, support, update, guide and the hooks, and every MCP tool, refuses while locked. Reach locks again when the stamp
fails, the course ends, or the fingerprint stops matching, locally or on Teach's status check. The crisis check runs
before every step. `reach enroll --course-passkey ... --username ... --student-id ...` does the same from a terminal
(`--course-code` stays as an unlisted alias).

Verified 2026-10-01 against `tools/fake_teach`, the stand-in for Teach's half:
- every flow branch: format errors, course id only, did-you-mean, expired code, refusal, five-refusal lockout with no
  further calls, start over, crisis;
- the CLI;
- a copied `~/.reach` run as another user in a Ruby 2.6.10 container (locked as moved, `fingerprint_mismatch`
  queued, then re-enrolled);
- a real Claude Code 2.1.286 session: every enrollment prompt was blocked, the agent saw none of them, and it got
  the unlock notice afterwards.

Since 2026-10-01c a second computer waits for the instructor's approval and an expired handout code says so. Since
2026-10-02e (rEach 0.18.3) a second computer is enrolled at once by default; it waits only when the course policy's
`enrollment.device_moves` is `approve`.

Since 0.16.1 a bare course id of nine or more characters (`BUS101FA26`) is answered with the course-only message
when Teach reports `details.course_only`. Built in 0.16.1 against wire revision 2026-10-01d and needing Teach 0.16.1;
not deployed live.

Re-verified 2026-10-01 against the real Teach 0.16.0 on a scratch database:
- chat and CLI enrollment;
- a device move held, approved and synced, with the old computer then reporting itself switched off;
- an expired handout code;
- a sandboxed Claude Code session enrolling through the hook.

Not verified: Codex, Hermes and Antigravity sessions, and macOS and Windows machine ids.

Build ✅ · Deploy 🔵 · Blocker: Human (the live Teach units still run 0.15.1 and need a restart, a roster and a minted code before a student can enroll with a course code).

### 2.28 · Platform smoke

Since 0.16.8 `tools/platform_smoke/run.rb` walks a student's path on any operating system without an agent: it
installs Reach from the checkout into a scratch folder whose path has a space, runs the SessionStart and
UserPromptSubmit hook command lines the way Claude Code and Codex do (through Git Bash on Windows), enrolls against
`tools/fake_teach`, and checks the gate opens, `reach status`, the machine-id fingerprint (`reg query` on Windows,
`ioreg` on macOS), the runtime kit and `reach doctor`. `.github/workflows/platforms.yml` runs it on every push to
main. Its first runs found and fixed two real defects: the directive frontmatter on macOS's built-in Ruby (0.16.6)
and the runtime Chrome check on Windows (0.16.7). Run 36932174987 passed 11 of 11 on Linux x64 (Ruby 2.6.10), macOS
arm64 and Intel (system Ruby 2.6.10), Windows x64 and Windows 11 arm64 (Ruby 4.0.7). The Windows 10 and Windows 11
x64 legs run on self-hosted VMs on SVEN-F1L1 (`tools/platform_smoke/windows-runner/bootstrap.ps1` and
`register.ps1`); they are off until the repository variable `REACH_VM_RUNNERS` is `on`.

Since 0.20.5 every leg opens real `teach.package/v1` envelopes, which no leg did before (fake_teach listed no packages
and `R-DOC-GUARD` was an expected doctor finding, so a student's Mac could fail to decrypt its guardrails package while
CI stayed green). `package_known_answer` opens a guardrails envelope sealed by Teach itself
(`tools/platform_smoke/fixtures/known-answer/`, throwaway test keys), and `sync_packages` has fake_teach seal guardrails
and workspace packages for the enrolled install, checks both are stored and revalidated with 304, and doctor must no
longer report `R-DOC-GUARD`. The smoke now keeps its workspace under the scratch root (`REACH_WORKSPACE_ROOT`).

Build ✅ · Deploy 🟡 · Hosted legs green in CI; the Windows 10 and 11 VM runners are not registered yet (waiting on the Windows ISOs, which Microsoft would not serve to a script).

### 2.29 · Microbrain learning and recall

Since 0.16.15 Reach learns about the student and their work and uses it, all on this computer. Since 2026-10-03 `Reach::Brain.capture_prompt`, called from the prompt hook, turns every gate-allowed prompt the student types, in any folder, into a private `source` spool line (never a blocked prompt, a secret-looking prompt or one holding the student's ID; `capture_min_chars` is 1; AI replies are not ingested), kept only on the computer; the host agent distils durable findings with `reach remember` (or `reach_remember`); a novelty gate (cosine at least 0.85 within the category only reinforces), a per-hour and per-day write budget, a secret and student-ID refusal and a backing-off nudge stop floods. Session start injects the profile (at most 1500 bytes) and each prompt the matching memories (at most 800 bytes) from `Reach::BrainIndex`, a BM25 and cosine read model over the spool, with decay and reinforcement salience. `reach memory list|show|forget|export` and the `reach_recall` and `reach_memory_forget` tools show and erase it; forgetting scrubs Reach's spool. Verified 2026-10-01 in scratch homes on Ruby 3.3.8 and in `ruby:2.6.10-slim`: three turns captured as source lines, a save, a reinforcement, a related save, a refused password, a held write at `per_hour: 2`, the profile in `reach hello`, matching memory and the nudge in `reach gate prompt`, forget by id and `--all --yes` leaving no claim text in the spool, the three MCP tools, a locked install refusing both commands, and brain work in 43 to 54 ms (cold 118 to 130 ms) with 2000 findings and 2000 sources in the spool. Not verified: the in-process `Rcorpus::Context` recall and `Rcorpus::Consolidate` paths, which need rcorpus 0.9.0, and a real harness session on Codex or Hermes.

Build ✅ · Deploy 🔵 · Blocker: Engineering. Verified on Ruby 2.6.10 and 3.3 (capture, remember, novelty, budget, recall, forget, spool cap) and end to end with rplugin 1.4.0 and rcorpus 0.9.0 (admission, audit 0, check 0). A student computer has no rplugin, so it runs on the spool and Reach's own recall; shipping rplugin and rcorpus in the runtime kit is deferred (TODO.md).

### 2.30 · Instructor unlock

Since 0.16.17 an instructor can lift the enrollment lock on one install. `reach instructor keygen` writes an RSA 3072 private key (0600, never overwriting) and prints the key id and the `enrollment.instructor_keys` entry; `reach instructor code [--label TEXT]` mints a never-expiring `RINS1` code and refuses when the key is not pinned in `config.yml`; pasted into the locked prompt, the enrollment hook intercepts a valid code (the agent never sees it) and stores it in `~/.reach/instructor.json`, after which an unenrolled install allows prompts without guardrails, captures nothing and tells the agent once per session it is in instructor mode. The stored code is re-verified each time, so listing its id in `enrollment.instructor_revoked` or removing its key relocks the next prompt. `reach instructor status` and `reach instructor lock` show and undo it. Verified 2026-10-01 in scratch homes on Ruby 3.3.8 and in `ruby:2.6.10-slim`: keygen, refusal to overwrite, the unpinned refusal, mint, a locked prompt blocked, the code accepted and the next prompt allowed with the instructor context once, nothing written under the transcripts directory, tampered, unpinned-key and garbage codes refused and counted toward lockout, a valid code accepted during a lockout, revocation and key removal relocking with `instructor.invalidated` logged, `reach instructor lock` moving the file aside, and an enrolled install still gating course-folder prompts. Not verified: a real harness session on Claude Code, Codex or Hermes.

Build ✅ · Deploy 🔵 · Blocker: Human. Since 0.16.18 the instructor key `343572ebf748c69d` is pinned in `config.yml`, so codes minted from it unlock installs on 0.16.18 or later; no instructor has yet unlocked a real harness session with one.

### 2.30b · Instructor personas

Since 0.16.23 (wire revision 2026-10-02a) an install holding a valid instructor unlock runs as a test student: `reach instructor dummy [--course ID]` starts a blank one and `reach instructor as USERNAME [--course ID]` a test copy of a roster student, both made by Teach 0.17.2's `W-API-ENROLL-INSTRUCTOR`, which never writes the real student's record and files everything the persona sends as instructor data. The persona has its own rEach home (`~/.reach/personas/<id>/`) and folders (`~/reach-work/personas/<id>/`), signs in with the test student ID that the start message and `reach instructor status` name, gates and captures exactly as a student's install, and ends with `reach instructor exit` (moved to `.backup`). A revoked code or removed key locks it. Verified 2026-10-02 against a real scratch Teach 0.17.2 through the assignment-one smoke extended with persona journeys (52 steps passed, 2 manual skips): unlock, a test copy of the smoke student with its workspace and 4 copied receipts, sign-in by test ID, the owned write allowed and an outside write refused, `reach check` clean, the real student's 19 table snapshots identical before and after, exit, a dummy, revocation at Teach, and the real student's install still active; the full student loop passed alongside it. The persona flow also ran in `ruby:2.6.10-slim` against a stub. Not verified: a live Claude Code, Codex or Hermes session.

Build ✅ · Deploy 🔵 · Blocker: Human (Teach 0.17.2 deployed and the instructor key pinned in the live course policy).

### 2.30c · Debug mode

Since 0.16.23 rEach records scrubbed metadata events (W-DBG-KINDS; never prompt or file text, codes, passwords or keys) under `debug/` in the rEach home, always for a persona and otherwise after `reach debug on [--for MINUTES]` or when an instructor switches it on from Teach, which the student is told about. It sends them to Teach (`W-API-DEBUG`), keeps them queued on any failure, and shows each turn's events as a hook `systemMessage`: an ASCII table on terminal surfaces, a Markdown table on desktop and IDE surfaces, with `debug.render` as the override; Hermes has no user-visible hook channel, so `reach debug show` is the way there. Verified 2026-10-02: with debug off every hook output and file listing is identical to 0.16.22's (117-line diff); against the real scratch Teach a persona's 29 events of 8 kinds were stored as classification instructor and both table formats rendered; against a stub, the scrub, local and remote switches, the once-per-session notice and the offline queue. Not verified: a live harness rendering the block.

Since 0.20.1 the person can say "enable debug mode" or "turn debug on" (and "turn debug off") to their AI partner instead of running a command; rEach switches it from the prompt hook, even before enrollment or while locked, and the agent relays the confirmation word for word. The session event then carries operating-system detail (`Reach::OsInfo`: distro or macOS or Windows version and build, kernel, arch, WSL, container, CPU, memory, disk, locale, timezone, shell, terminal, desktop, tool versions; never a hostname, username or path). Verified 2026-10-03 on a scratch home: the phrases switch it on and off, sentences that only mention debug change nothing, the confirmation shows locked and unlocked, and the spooled session event carried 33 OS fields (46 in all). Not verified: the macOS, Windows and WSL probes.

Build ✅ · Deploy 🔵 · Blocker: Human (Teach 0.17.2 deployed).

### 2.30d · Setup log and setup report

Since 0.35.0 (`STD-SETUP-LOG`), until a student is enrolled rEach writes an exhaustive local log to `setup-log/` in the rEach home: every command with its full backtrace, hook, request and response, debug event (debug mode on or off), fault, message id and an environment snapshot, plus the installers' step records (`install-<stamp>.jsonl`). It holds no typed text (only lengths) and never a password, passkey or code, and rEach never sends it. After three setup failures in a row (and every three after) it saves `reach-setup-report-<time>.json` in Downloads and shows the student the path and a `file://` link, suggesting they send it to the instructor; rejected input neither counts nor resets, and a locked command run before enrolling does not count. `reach debug export` and the `reach_debug` export action save one on demand. The debug phrases ("enable debug mode", "turn debug off") now also work in the plugin-level enrollment hook before enrollment, except at a password step. Verified 2026-10-05 on a scratch home against an unreachable course server: the phrase toggled debug and re-asked the passkey question without moving the flow; three locked `reach status` runs wrote no report; the third offline enrollment failure carried M-SETUP-REPORT-SAVED and wrote a 0600 report of schema `reach.setup-report/v1`; a typed passkey, username, student ID and password were absent from every setup-log file and report; terminal `reach enroll`, the MCP `reach_debug` export and `REACH_SETUP_LOG=0` behaved as specified; a hook ran 0.20 s with the log on and off; the same enrollment journey passed on Ruby 2.6.10 (container, no network). Not verified: `scripts/reach-install.ps1` (never run), the installer's success path, a real student or harness session.

Since 0.35.1 every path in the log, the installer records and the report starts with `~` instead of the user folder, and the enrollment fingerprint (salt, hashes, binding, hostname) is redacted; verified on a scratch home (0 raw user-folder paths in the report and the installer log, fingerprint fields `[redacted]`) and on Ruby 2.6.10.

Build ✅ · Deploy 🔵 · Blocker: Human (a real student's setup has not produced a report yet).

### 2.30d · Teach connection safety

Since 0.16.25 (wire revision 2026-10-02b, `STD-TEACH-LINK`) a student never sees a raw error, backtrace, hook error or hook timeout from rEach. `Reach::Link` tracks the Teach connection in `link.json` and tells the student once per outage that the connection was lost and their work is saved (`M-TEACH-LINK-LOST`), and once when it is back (`M-TEACH-LINK-BACK`): a hook `systemMessage` on Claude Code and Codex, a relay line on Hermes, stderr at the terminal. Every hook runs in a guard that keeps its allow or block outcome, shows at most one plain hiccup every 15 minutes, and gives the network a deadline inside the hook timeout. MCP tools and terminal commands answer in plain words. Every hidden error becomes a `fault` event and every connection change a `link` event, and both are sent to Teach even with debug mode off (reason `fault`, no message text), where instructors read them. Verified 2026-10-02 against a real scratch Teach 0.17.3: the assignment-one smoke with link and crash journeys passed 51 steps (Teach stopped and restarted, notices once each, injected crashes in Claude Code, Hermes, terminal, MCP and load paths with no raw text, faults and link events stored at Teach as `student`), and a silent server held the 25 s tool deadline. Not verified: a live harness session showing the notices.

Since 0.21.8 (`STD-CODEX-SANDBOX`) a command Codex runs in its own sandbox (outside a trusted course folder: no
network, no writes to `~/.reach`) is not an outage: `Reach::Sandbox` recognizes it, `Reach::Client` makes no request,
and the command says M-SANDBOX-AGENT (with M-SANDBOX-STUDENT for the student) instead of M-TEACH-LINK-LOST or
M-REACH-HICCUP-CLI; `reach update` and `reach doctor` say so too. The MCP tools `reach_debug` and `reach_doctor` give
the agent debug mode and the health check outside the sandbox, and since 0.21.12 `reach_update` (status, run) gives it the
updater: run starts `reach update run --apply --force` detached. Verified with the real `codex sandbox` runner on Linux;
not yet seen on a student's macOS Codex. `reach_update` was driven over stdio in a scratch home on 2026-10-03: status
named the version, run started the detached updater and the next status showed its check.
Since 0.28.2 M-SANDBOX-STUDENT names the course folder by its path on this computer and says it is the folder holding
`deliverables` and `extracurricular`; a Windows Codex student had been told they had no course folder (2026-10-04).
Verified on Linux in a scratch home with `CODEX_SANDBOX_NETWORK_DISABLED=1`; the Windows path separator was not run.

Build ✅ · Deploy 🔵 · Blocker: Human (no live harness session yet).

### 2.30e · Known issues for the agent

Since 0.21.9 (`STD-KNOWN-ISSUES`, W-API-KNOWN-ISSUES) rEach fetches Teach's known issues without signing, caches them,
names the matching ones for this operating system, harness and version in every session context, flags detected ones
(`codex_sandbox`, `hooks_not_running`) and gives the steps through `reach_known_issues` and `reach known-issues`.
Since 0.28.1 `hooks_not_running` no longer takes a session-start hook as proof that hooks run, and
`reach part record` says so when the prompt hook is silent (`M-PART-NO-HOOK`) instead of asking the student to
answer again. Verified 2026-10-04 on Linux against a scratch home with the real hook commands: prompt hook silent
for 40 minutes with a fresh session-start hook (refused with the new message, detector on), prompt hook running
with a short prompt (the old message), prompt hook running with an answer (recorded). Not run on macOS or in Codex.
Since 0.29.0 (`STD-HOOK-GUARD`) rEach does no course work in a Codex that is not running its hooks: qualify,
submit and recording an own-part answer refuse with a plain explanation and the steps to fix it, from the first tool
call after a session starts without a prompt hook, until the student's next message arrives through the hooks.
Other apps are never refused, and `hooks.require: false` in `config.yml` or `REACH_HOOK_GUARD_DISABLE=1` switches it
off. Verified 2026-10-04 on Linux against a scratch home with the real hook commands: Codex with a session-start
hook and no prompt hook (all three refused), the same state under Claude Code (not refused), the switch off (not
refused), the prompt hook running (not refused), a compaction and a hand-run `reach hello` (not re-armed), and
40 minutes with no hook (refused). Not run inside a real Codex, on macOS or on Windows.
Verified against a scratch Teach 0.27.1 (200, then 304 on revalidation), over MCP (hooks_not_running detected with no
hook run), and inside the real `codex sandbox` runner (the sandbox entry detected from the cache with no request).
Since 0.34.9 (`STD-SIGNIN-HOOK-SILENT`, wire revision 2026-10-05a) a third detector, `signin_hook_not_running`,
watches the plugin's own sign-in hook against the latest Codex session start, `hooks_not_running` keeps watching the
course-folder hooks, `reach_next` says `M-NEXT-LOGIN-NO-HOOK` instead of asking for the student ID while the sign-in
hook is silent, and a remedy is named only for a detected issue. Verified 2026-10-05 on Linux against a scratch home
with the real `reach hello` and `reach gate enroll --harness codex` commands in five sequences (nothing run, session
start only, start then sign-in hook, a new session with the sign-in hook silent, then running): the new detector
followed the sign-in hook while `hooks_not_running` stayed on; `reach_next` over the MCP path switched to the new step
only in the silent case, and `reach next` from a terminal never did. Not run inside a real Codex or on Windows.
Since 0.34.10 the same silent case on the MCP path swaps `M-LOGIN-NEEDED` for `M-LOGIN-NEEDED-NO-HOOK` in
`reach_hello`'s sign-in context and in tool refusals for a student who has not signed in. Verified 2026-10-05 the same
way: silent hook gave the new text for the MCP hello context and the bridge refusal and the old text for the hook
context; a running hook gave the old text everywhere. A false alarm stays possible when a second Codex window starts
a session, or a turn runs past 15 minutes with no session start recorded; it tells the student to restart Codex,
never to type the ID.
Since 0.34.11 the sign-in step counts as running when either prompt hook ran (the plugin's `gate enroll` or a
course folder's `gate prompt`), and tool gates refuse with `M-LOGIN-NEEDED-NO-HOOK` while neither did. Verified
2026-10-05 with the real hook commands: session start only (silent, new text), course-folder `gate prompt` only
(running, old text), a new session with both silent (silent), then `gate enroll` (running).

Build ✅ · Deploy 🔵 · Blocker: Temporal (Teach 0.27.1 is live with both entries; students update to 0.21.9 on their own).

### 2.31 · Opening a course folder

`reach work [--harness H] [--slice S | --extracurricular]` opens a slice, or the student's own folder, in the chosen
harness through the gate with rEach speaking first; `reach start [--harness H]` opens a harness in the current folder
with no course gate. With one harness found it uses it, with several it asks. Hermes is launched as
`hermes -p reach --accept-hooks chat -q "Hi rEach"` (10.5), and since 0.11.4 setup prints the absolute
`~/.reach/bin/reach work --harness hermes` command because `reach` may not be on the PATH. Verified: Hermes (2026-09-29
and 2026-09-30) and the real-Claude smoke's workspace sessions. Unverified: `reach work` for Codex and Antigravity, and
`reach start` (built in 0.2.0, no separate run recorded).

Build ✅ · Deploy 🔵 · Blocker: Human (Codex and Antigravity launches not run).

### 2.32 · Client safety and offline queue

Every call to Teach goes through `Reach::Client`: connect 5 s and read 30 s timeouts, a token bucket of 20 requests per
minute shared by every Reach process under a file lock (`~/.reach/state/bucket.json`), at most 4 retries for idempotent
requests with full-jitter backoff and `Retry-After` honored, a circuit breaker that opens for 60 seconds after five
failures, 2-second quick mode for calls a harness waits on, and a kill switch, `REACH_OFFLINE=1`. Submissions, hands,
integrity reports and transfers that cannot be sent wait in `~/.reach/outbox/` and go out on the next `reach sync`;
`reach doctor` reports a non-empty outbox (R-DOC-OUTBOX). Verified: a queued hand saved and reported as queued, a
receipt acknowledgment held pending under Teach's kill switch and linked later (2.16), offline sign-in (2.17). Unverified:
the breaker and the retry schedule have no recorded run of their own.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.33 · Seal, witness ledger and integrity reports

Every owned file carries an invisible per-install, per-file mark on its second line (Ruby) or first line (Svelte), which
Teach derives and Reach cannot forge. Each workspace has a witness ledger at
`~/.reach/state/ledger/<course>/<assignment>/<workspace>.jsonl`, an HMAC-chained record of every session, write, check,
checkpoint and qualification, plus a per-computer sidecar (`seal.json`) that records every install enrolled from this
computer. A missing or corrupt mark is re-stamped and a foreign one never; `vault_tampered`, `corrupt_mark`,
`foreign_mark`, `ledger_break`, `sidecar_conflict`, `enrolled` and `directive_dump` go to `POST /api/v1/integrity`
silently, deduplicated, queued offline, never shown to the student. The submission carries the seal block and a ledger
tail for Teach's provenance assessment. Verified in 0.4.0 against a scratch Teach: a corrupt mark healed and reported,
a foreign mark assessed `foreign:<install>:<student>`, a vault edit reported silently and healed at sync, the file
witnessed on submit. Unverified: the sidecar paths on macOS (`~/Library/Application Support/reach/seal.json`) and
Windows (`%LOCALAPPDATA%\reach\seal.json`) outside the sidecar's presence check in doctor.

Build ✅ · Deploy 🔵 · Blocker: Human (macOS and Windows sidecars not exercised).

### 2.34 · Submit gate on check findings

`reach submit` runs `reach check` first. Findings come back once with M-SUBMIT-FIX-FIRST; a second submit on the same
findings is refused with M-SUBMIT-BLOCKED-CHECK and raises a `check_gate` hand to the instructors. Only findings in the
slice's own files count (0.11.0). Verified in 0.4.0: fix-first, then blocked with a `check_gate` hand, and a clean submit
assessed `clean`.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.35 · Tool gates: write, shell and read

`reach gate session|prompt|enroll|write|shell|read` are the commands the harness hooks call. `write` allows only owned
files (and `qualify/features` and `qualify/step_definitions`), reads a Codex `apply_patch` and Hermes' `write_file` and
V4A patches, and refuses git in slice and root spaces (M-GATE-NOGIT). `shell` splits a command, refuses subshells and
command substitution and, since 0.11.3, reads quotes as the shell does and refuses inline interpreter code
(`ruby -e`, `python -c`, `node -e`, `bash -c`) outside extracurricular (M-GATE-NOCODETOOL); the shim form
`ruby <shim> qualify` is allowed. `read` and the sandbox rules are catalogued at 2.20. The gate passes offline for up to
24 hours on a verified cached package. Verified: Claude Code, Codex argv and patch forms (0.2.0), Hermes (0.11.1 and
0.11.3). Unverified: Windows hook-command quoting (TODO.md), and Codex's and Hermes' read and web gates, which are
configured but not run live.

Build ✅ · Deploy 🔵 · Blocker: Human (Windows quoting unproven).

### 2.36 · Course time

Every time rEach shows (due dates, receipt times) is in the course's timezone with its label, for example
"Sat 3 Oct 11:59 pm PDT", whatever zone the computer is in (`Reach::CourseTime`, STD-COURSE-TIME). The time gate (2.21)
uses Teach's clock. No run of this formatting is recorded on its own.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.37 · Shape-check watcher

`reach watch [--slice S]` polls a slice workspace for changed files and runs the shape check on each, the backstop for
a harness without a post-write hook; it prints a reason and keeps watching when the checker cannot run (0.4.2).
Unverified: no run of `reach watch` is recorded in CHANGELOG or TODO.md since the Codex hook path replaced the need.

Build ✅ · Deploy 🔵 · Blocker: Human (never run against a harness).

### 2.38 · Vault lock and sign-in status

`reach lock` empties the decrypted vault (it is rebuilt from the packages on demand) and `reach login status` says
whether this session is signed in (2.17). Unverified: neither has a separate run recorded.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.39 · Teach subscription

Since 0.22.0 (wire revision 2026-10-03e, Teach 0.30.0; STD-TEACH-SUBSCRIBE) Reach checks Teach's signed W-API-REVISION probe, about every 60 seconds from its MCP server while a harness session runs and about every 15 minutes from a user-level operating system job (a systemd user timer, a launchd LaunchAgent or a Task Scheduler task), and runs one `reach sync` only when a part changed, so rebuilt packages, assignments, policy, grades, hand replies, extra credit, receipts and known issues arrive without the student asking. `reach subscribe status|tick|install|uninstall` manage it, `reach doctor` prints R-DOC-SUBSCRIBE, and the prompt hook adds one plain line (M-SUBSCRIBE-UPDATES) naming what changed. `REACH_OFFLINE=1`, `REACH_SUBSCRIBE=0` and `subscribe.background: false` switch it off. Unverified: the macOS LaunchAgent and the Windows Task Scheduler job were generated as text only and never run on those systems; the Linux unit files were written to a scratch folder with no `systemctl` call.

Build ✅ · Deploy 🟢 Live (released 2026-10-03 as v0.22.0, GitHub Latest; Teach 0.30.0 serves the route). The macOS and Windows operating system jobs are generated and reviewed but have not yet run on those systems.

### 2.40 · Issue reports

Since 0.23.0 rEach reports its own technical problems to the instructors by itself (`STD-ISSUES`, wire `W-ISSUE-1` to
`W-ISSUE-8`). Every fault it hides from the student gets a signature; a fault that stops enrollment, sign-in, sync,
qualify or submit is reported the first time, any other the third time in 24 hours, once per signature per rEach
version, at most 3 a day. The report is a hand with trigger `issue` and the sealed bundle `reach.issue/v1`: where it
happened, the exception class, the backtrace frames inside the plugin, the versions, and a capsule of what
`reach doctor --report` knows. No error message, prompt, code or profile is in it. It is built and sent by a detached
process, waits in the outbox with backoff when Teach cannot be reached, and the student is told once, in plain words,
that rEach reported a problem and that nothing is needed from them, and once more when the fix is in the version they
run. A technical, setup or access hand the agent raises carries the same capsule. `reach issues` lists the registry
for an instructor; `REACH_ISSUES_DISABLE=1` turns the feature off.

Verified 2026-10-03 against `tools/fake_teach` on Linux, Ruby 3.3: a blocking fault raised one hand at once and a
non-blocking one at its third occurrence and not again; a transport fault raised nothing; with Teach stopped the
report waited in the outbox with a next-attempt time and went out on `reach issues flush`, once; the fourth issue of a
day was suppressed and counted; the kill switch left fault events flowing and raised nothing; the bundle held no
message text; the Stop hook told the student once, and told them once that it was fixed after the hand's status
named the running version; a hand the server had lost no longer stopped the reply check. One fault gave the same
signature on Ruby 2.6.10, 3.4.11 and 4.0.7, and the platform smoke passed on a copy of the tree (13 passed, runtime
steps skipped). Not verified: any Teach, because no released Teach accepts trigger `issue` yet; macOS, Windows and
Hermes; the full flow on Ruby 2.6, where only the syntax and the signature were checked; `tools/smoke` with real
harness sessions.

Build ✅ · Deploy 🟢 Live (released 2026-10-03 as v0.23.0, GitHub Latest; Teach 0.31.0 accepts the issue hand). No report from a real student install has been seen yet.

### 2.41 · Live sessions

Since 0.23.0 a student can open a live session with their instructors to find out together why something in rEach
does not work (`STD-LIVE`, wire `W-LIVE-1` to `W-LIVE-9`). The student's assistant asks through the `reach_live` tool
and rEach puts its own question to the student; or an instructor offers a session and rEach asks at the next prompt.
It opens only after the student's typed yes. While it is open rEach sends what it records in debug mode (what rEach
did, never prompts, replies, code or files) and the two sides exchange notes. rEach itself enforces two rules: a
check the instructor's side asks for (one of seven fixed ones) runs only after the student's typed yes for that
check, and nothing the student's assistant wants to send leaves the computer until the student has seen the exact
text and typed yes. For an instructor's own test student the two assistants can also write to each other, under the
same rules. Either side can end it at any time. `REACH_LIVE_DISABLE=1` turns the feature off.

On Claude Code 2.1.288 or newer rEach wakes a waiting assistant when the instructor's side wrote, asked for a check
or ended the session (a background Stop-hook entry, `reach live watch`), and it shows one desktop notification when
the instructor writes. A student whose prompts rEach blocks can still ask for, accept, follow and end a live session
by typing: the question, the instructor's notes and each check's question appear under the block text, and rEach
takes the typed yes or no there. `config.yml` `live.wake`, `live.notify` and `live.blocked` turn these off.

Verified 2026-10-03 on Linux, Ruby 3.3, against a scratch Teach built from its `mcp-wire` branch: a request, the
yes through the prompt hook, the instructor's approval and the open notice; an offer accepted and an offer refused;
a check answered yes (it ran, the result reached Teach) and one answered no (nothing ran, Teach was told); a note
staged and refused (nothing sent) and one approved (sent); an assistant message refused while another question was
waiting; debug events flowing with reason `remote` and stopping at the end; the end from either side told once. One
session ran with a real Claude Code session as the student's assistant: it found `reach_live`, relayed each of
rEach's questions word for word, and did not treat "go ahead and help them" as a yes. In the first on-screen session the
student's side showed an instructor's request only at the student's next prompt; the wait is now 45 seconds and the
assistant is told to keep waiting while an answer is expected, which has not been run from a session's start yet. Not verified: macOS, Windows,
the flow on Ruby 2.6 (on 2.6.10 only the syntax and loading were checked), Codex, Cowork and Hermes; `tools/fake_teach`, which has no live routes.

Until 0.33.2 no live session could start on Windows: the background runner was started with a process option
Windows refuses, so a typed yes was never sent and each new request asked the question again. 0.33.2 starts it with
the Windows option and answers a repeated request with "rEach is sending your answer". Still not run on a real
Windows install.

The wake ran on 2026-10-03 in a real Claude Code 2.1.288 session: the idle assistant was woken by the open notice,
an instructor's note, a check's question and the end, each once; one watcher at a time; none left after the end. The
entry is absent with Claude Code 2.1.100 and with no `claude` on the path. The desktop notification ran on Linux
only. The blocked path ran through the prompt hook with a student who had no course work: a request and yes, an
offer accepted and one refused, a note shown word for word, a check answered yes and one answered no, the end typed
by the student and the end by the instructor; a locked-out sign-in got the question, the ordinary sign-in question
did not; nothing was written to the microbrain. Not verified there: a real harness showing the block text, and a
student who becomes blocked while a watcher is still running.

Since 0.27.0 (`STD-LIVE-DIAGNOSIS`, wire `W-LIVE-10`) a computer that holds the instructor unlock can start a
diagnosis session, for working out a rEach problem on that computer directly between the two assistants:
`reach instructor diagnose [--course ID]`, or the `reach_live` tool with action `diagnose`. rEach asks the person at
the computer one question that says what the yes covers. On their typed yes the session opens at once; the
assistant there and the instructor's assistant write to each other without a question per message, and rEach runs
the fixed checks the instructor's side requests without asking again. On a computer that is not enrolled rEach
first makes a blank test student. The assistant still asks before it runs any other command or changes anything,
and it never sends a password, key, token or instructor code. The unlock code stays on the computer until
`reach instructor lock` removes it.

Verified 2026-10-04 on Linux, Ruby 4.0, against a scratch course server: the refusal without an unlock; a test
student made on an unenrolled computer and the session opened on the yes; the same on an enrolled install; two
assistant messages sent with no question; a requested check run with no question and its result returned; a
revoked code refused; the session ended by typing. Not verified: a session between two real assistants, and any run
on Windows or macOS.

Build ✅ · Deploy 🟢 Live (released 2026-10-03 as v0.23.0, GitHub Latest; Teach 0.31.0 serves the routes). No session has run against the live Teach yet.

### 2.42 · Progress checkpoints

Since 0.24.0 rEach tells Teach the first time a student reaches a checkpoint only rEach can see (`STD-PROGRESS`, wire
`W-API-PROGRESS`): the course passkey accepted, email and student ID confirmed, the first confirmed sign-in, and the
first prompt inside a workspace of each assignment. `Reach::Progress` keeps the ids and times in
`state/progress.json`, and `reach sync` sends the unsent ones in one signed request once the student is enrolled.
It sends ids and times only, never typed text, and makes no network call from a hook. `REACH_PROGRESS=0` turns it off.
Teach shows the result as the Progress column of its Students page.

Verified 2026-10-03 on Linux, Ruby 4.0.6, against a scratch Teach 0.35.0: `reach enroll` and the chat enrollment each
recorded the two enrollment checkpoints locally, sent them with the sync that follows registration and Teach stored
them with the install; a sign-in mark went out on the next `reach sync` and left the outbox empty; a repeat, an unknown id and an
id Teach records itself were not stored; a time in the future was stored as Teach's own time. Not verified: macOS and
Windows; a real harness session for the sign-in and assignment-started marks, which were driven through the library.

Build ✅ · Deploy 🟢 Live (released 2026-10-03 as v0.24.0, GitHub Latest; Teach 0.35.0 serves the route). No report from a real student install has been seen yet.

### 2.43 · Announcements, due changes and material holdings

Since 0.30.0 (`STD-ANNOUNCEMENTS`, `STD-DUE-CHANGE`, `STD-HOLDINGS`; wire `W-API-ANNOUNCEMENTS`,
`W-API-ANNOUNCEMENT-RECEIPTS`, `W-API-HOLDINGS`, `W-SAFE-16`, revision 2026-10-04g) an instructor's announcement
reaches the student through rEach. `reach sync` fetches the announcements sent to the student, their group or the
whole course into `state/announcements.json`; the prompt hook shows each one once, word for word, at most three per
prompt, and a detached `reach announcements flush` reports when each arrived and was shown. `reach announcements`
and the `reach_announcements` tool list the queue by date. When the due time the course server answers for an
assignment differs from the one rEach last saw, the student hears the earlier and the new time once. After each
sync rEach reports the names and digests of the course material it holds, and only when they changed.
`announcements.show: false` stops the display.

Verified 2026-10-04 on Linux, Ruby 4.0.6, against a scratch course server: a course announcement and a group
announcement arrived and another student's did not; a draft never arrived; the notice was shown once and the shown
time reached the server after the flush; a forged receipt id was answered as unknown and not recorded; a withdrawn
announcement left the queue at the next sync; a due time changed on the server reached rEach with no restart and was
said once; the holdings report matched what the server serves, read older after the server repacked, and current
again after the next sync; a server without the routes answered 404 and rEach parked the calls. The stock smoke run
passed 40 steps with 2 skipped. Not verified: macOS and Windows, Ruby 2.6, and a real harness session.

Build ✅ · Deploy 🟢 Live (released 2026-10-04 as v0.30.0, GitHub Latest; Teach 0.44.0 serves the routes). No announcement has been sent to a real student yet. · Blocker: -.

### 2.44 · Home inside the reach-work folder

Since 0.31.0 (`STD-HOME-IN-WORKSPACE`) rEach keeps its own files in `~/reach-work/.reach-home`
instead of `~/.reach`, and an existing install is relocated by copy, hash verification and rename, leaving the legacy
folder untouched apart from `RELOCATED.json`. Every kind of space refuses the home, a root-kind session judges writes by
target slice (`M-PICK-SLICE`), and `reach doctor` reports `R-DOC-RELOCATION`. Verified 2026-10-03 against a scratch Teach
(0.31.1) with real claude and codex CLIs: fresh install, relocation of a populated legacy install (legacy hash list
unchanged, new home identical, enrollment kept, outbox sent afterwards), two kill -9 interruptions, an occupied
destination, an instructor persona, the gate in root, slice and extracurricular kinds, harness source repoints and
Ruby 2.6.10. Not fixed by this layout alone: Codex's default sandbox still blocks the network and writes outside the
chat's folder; since 2.45 rEach changes the student's own Codex settings after their yes so a Codex chat may use the
network and write in the reach-work folder. Codex hook trust is unrelated; on Windows the project's top-level `.codex`
is read-only in the sandbox. Verified 2026-10-04 on GitHub runners (windows-2025 x64, windows-11-arm, macos-15,
ubuntu-24.04; `tools/sandbox_probe/codex_setup_probe.rb`): an install enrolled with 0.28.2 was relocated with 28 of 28
files identical in the new home, the legacy folder changed only by `RELOCATED.json`, and `reach status` still named
the student. Measured there too: on Windows the new home alone opens nothing (Codex's sandbox still refuses rEach's
folder with the home inside the chat's folder). Not verified: an update of a real install with its Claude Code and
Codex plugin copies on Windows or macOS, and `scripts/reach-install.ps1`.

Build ✅ · Deploy 🔵 · Blocker: Human (no student has updated yet; plugin-copy update unverified on Windows and macOS).

### 2.45 · rEach sets Codex up

Since 0.31.0 (`STD-CODEX-SETUP`, wire revision 2026-10-04h) rEach writes the sandbox settings
it needs into the student's own Codex configuration (`$CODEX_HOME/config.toml`) after the student's yes: on a terminal
(`reach codex configure`), in a chat (`reach_setup` configure, the yes captured by the prompt hook) or through the
`codex_configure` live action. Mode workspace (the default outside Windows) turns on network access and makes the
reach-work folder writable; mode full (the default on Windows) turns Codex's sandbox off; both mark the folder trusted.
A line editor changes only those lines, keeps a backup beside the file, refuses rather than guess, and is undone when
`codex features list` rejects only the new file. `reach codex probe`, `reach_setup` probe and the `sandbox_probe` live
action test the sandbox; `reach doctor` shows a `codex:` line and `R-DOC-CODEX`; `reach mcp` and the background tick put
the settings back at most every 6 hours while the yes stands; `reach codex off` stops that. Known issues carry a remedy
that rEach names to the agent. Verified 2026-10-03 on Linux with Codex 0.160.0 in scratch homes: the editor on 19 file
shapes in both modes (byte-exact outside the edited lines, backups equal to the originals, a second apply writing
nothing, every refusal leaving the file alone), the terminal yes and no on a pseudo-terminal, the chat yes and no
through the real MCP server and prompt hook, the hooks-off answer, the busy lock, the reapply from `reach mcp` and the
background tick (and none without a yes, after a withdrawal or within 6 hours), both live actions against a scratch
Teach on the `codex-setup` branch, the known-issue remedies and Ruby 2.6.10. A Codex chat follows the new settings
(`codex debug prompt-input` shows workspace-write, network enabled and the reach-work writable root). `codex
sandbox` does not read the file's top-level `sandbox_mode`, so the probe passes the file's own value with `-c`; with
that, the probe reported blocked before and ok after configure in both modes, and `reach doctor` printed settings ok
with internet ok and folder ok. The probe's internet check is one plain request from inside the sandbox (5 s limits,
no retry), with the token taken by the parent outside it, so a blocked rEach folder no longer reads as a blocked
internet (a sandbox with the internet open and the folder closed reported only the folder). `scripts/reach-install`
runs `reach codex configure` right after it installs, when Codex is present and a person can answer (the terminal, or
`/dev/tty` when only the input is piped), and prints the command otherwise; it runs before `reach setup`, which the
same one-line command starts next. Verified with a terminal answering yes and no, with the input piped, with no
terminal and with no Codex. `tools/fake_teach` serves `GET /api/v1/known-issues` from `known_issues.json` with
`remedy` in the W-KI-1 key order, the revision as ETag and 304; rEach fetched from it and from a scratch Teach on
branch `codex-setup` and mapped the remedies to tool calls. fake_teach has no live-session routes; the live actions
were run against the scratch Teach. Verified 2026-10-04 with Codex 0.160.0's real `codex sandbox` on GitHub runners
(`tools/sandbox_probe/codex_setup_probe.rb`, workflow `codex-setup-probe`): on windows-2025 x64 and windows-11-arm,
before the setup and in mode workspace the sandbox refused rEach's folder and the internet and a sandboxed `reach sync`
exited 1; in mode full (the Windows default) the course server, the internet and rEach's folder were reachable and
`reach sync` exited 0. On macos-15 mode workspace was enough. The ubuntu-24.04 runner cannot start Codex's sandbox
(bwrap is refused there); mode workspace passed on a Linux desktop. Not verified: `scripts/reach-install.ps1`, the
Codex desktop app and IDE extension, and a student's real Codex chat reaching the course server.

Build ✅ · Deploy 🔵 · Blocker: Human (no student's Codex has run the setup yet).

### 2.46 · Course profile

Since 0.33.0 (`STD-COURSE-PROFILE`, wire `W-POL-2`, revision 2026-10-04j) the facts of one course reach rEach from
the course, inside the guardrails package, and are no longer written in this repository: the learning system's name
and whether the submission ZIP must be uploaded there for credit, the hints for the school email and student ID, and
the wellbeing phrases and support message. With no profile rEach names no learning system, asks in plain words,
shows times in UTC when it knows no zone, and keeps its built-in crisis phrases and support message. The profile's
terms and slice names are delivered and not read yet.

Verified 2026-10-04 on Linux, Ruby 4.0.6, against a scratch course server: with no profile the preview carried no
hints, enrollment completed, no learning system was named, any email and student ID passed rEach's own check and the
built-in crisis phrases matched; one sync after a profile was written rEach named the course's learning system,
added the upload sentence, matched the course's own phrases and showed its support text; with the upload not
required the sentence was gone and the grade-of-record line stayed; the preview answered the hints and the student-ID
question carried one; a profile with an unknown section was refused and the last good one stayed. The stock smoke run
passed. Not verified: macOS and Windows, a real harness session.

Build ✅ · Deploy 🟢 Live (released 2026-10-04 as v0.33.0, GitHub Latest; Teach 0.47.0 serves a profile for both courses) · Blocker: -.

## 3 · Course reference

### 3.1 · Encrypted reference

`reach reference list|show|search|links` and the `reach_reference` MCP tool read RREF version 1 blobs, decrypted in
memory only, with the key from the guardrails package's `reference-keys.json` (wire protocol 1 revision 2026-09-28f).
Before enrollment, or with a Teach that sends no key, a blob is locked; a blob that fails authentication is refused.
The smoke covers pack, locked before enrollment, readable after sync and tamper refused. A blob whose key id is
corrupted or forged, while we hold a different key for the same course, is refused rather than reported locked
(fixed 2026-09-29).

Build ✅ · Deploy 🔵 · Blocker: -.

### 3.2 · Reference blobs come only from Teach

Since 0.14.5 the repository carries no course material: `corpus/` is gone, and `reach reference` reads `.rref` blobs
only from its vault copy of the guardrails package, where Teach ships them as `reference/<name>.rref` entries (wire
protocol 1 revision 2026-10-01a). `REACH_REFERENCE_DIR` still overrides the directory. On a scratch install whose
vault held two blobs and their keys, `reach reference list` listed both and `search` found hits; with the keys file
removed both reported locked; with no reference directory at all, list reported no reference material.

Build ✅ · Deploy 🔵 · Blocker: -.

### 3.3 · Course corpus in the microbrain

Since 0.17.1 (`STD-COURSE-CORPUS`) `Reach::CourseCorpus` ingests the course reference Teach delivers at enrollment
(Teach 0.18.2: only the student's own course, every unit) into the microbrain as private sources under
`course/<course>/`. It runs after `reach sync`, at session start when the blobs or keys changed, and from
`reach reference ingest [--force]`. Replaced files are tombstoned, and course sources are never pruned, never count
toward the spool cap and survive `forget --all`. Matching passages join each prompt under `M-BRAIN-COURSE`. Verified
2026-10-02 in a scratch run of the A1 smoke against Teach on a scratch PostgreSQL: 17 PASS. Only the enrolled
course's blob reached the vault, the course text sat only in the 0600 brain spool, and a second ingest reported
unchanged. Admission into a scratch rcorpus took all 6 operations, including the tombstone, in the private tier.
The same functions also ran on Ruby 2.6.10.

Build ✅ · Deploy 🔵 · Blocker: Temporal (tagged v0.17.1 and Teach 0.18.2 live with both course links on 2026-10-02;
students receive it on their next auto-update and sync).

### 3.4 · Storage gates and corpus compaction

Since 0.18.0 (`STD-STORAGE-GATES`) Reach measures the corpus and the microbrain together in a detached process,
warns once at 512, 1024 and 2048 MB with an offer to compact the corpus only, and at 4096 MB demands compaction,
suggests a true backup and refuses imports. `reach storage compact` (and `reach_storage`) asks the student, then
compacts in the background with rcorpus 0.11.0's compressed compaction; the microbrain is never compacted.
Verified 2026-10-02 in a scratch HOME with lowered thresholds: each warning fired once and again after a drop and a
new crossing, the demand line came at session start and on each session's first prompt, a yes compacted and a no did
not, the brain folder and spool were byte-identical before and after, and an old rcorpus was reported honestly. The
shrink is modest (a corpus-only run went from 18.2 MB to 16 MB) because rcorpus keeps the history it compacts.

Build ✅ · Deploy 🔵 · Blocker: Temporal (students receive it on their next auto-update; rplugin 1.5.0 carries
rcorpus 0.11.0).

### 3.5 · Importing another AI system's export

Since 0.18.0 (`STD-EXPORT-IMPORT`) `reach import pick` or `reach import export <path> --mode brain|copy` reads a
ChatGPT, Claude or Gemini export, folder or ZIP, in a detached resumable job after the student agrees, and the
agent distills findings from a ranked queue across sessions. Copy mode also keeps each conversation verbatim in the
corpus's private tier. Verified 2026-10-02 in a scratch HOME: a 198 MB, 20,000-conversation ChatGPT export peaked at
90 MB RSS in brain mode (30 s) and 187 MB in copy mode with admission; a job killed at 5,869 conversations resumed to
an identical catalog; imported text never reached the brain index; the job ran under Ruby 2.6.10; and
`forget --all` erased a 23,000-source copy in 13 s with `rcorpus check` clean. The osascript and PowerShell pickers
were built but not run on macOS or Windows.

Build ✅ · Deploy 🔵 · Blocker: Temporal (students receive it on their next auto-update).

### 3.6 · Transcript export

Restored in 0.25.0 (`STD-TRANSCRIPT-EXPORT`). `reach transcripts export` and the `reach_transcripts` tool save the
student's own recorded conversations as a ZIP in Downloads, grouped by assignment and slice, and the first session
after the course ends exports once in the background (`transcripts.auto_export`, default on). Verified 2026-10-03 on a
scratch course: one session of 15 entries exported.
Build ✅ Shipped · Deploy 🟢 Live (released 2026-10-03 as v0.25.0, GitHub Latest; Teach 0.38.0 accepts the entries). No real student session has been recorded yet.

### 3.7 · Late work

Since 0.19.0 (`STD-LATE-WORK`, `W-PACE-2`) a past-due slice stays writable with repeated late notices, and rEach raises
one late_work hand per assignment and one late_submission hand per late submission. Verified 2026-10-02 against
tools/fake_teach: past-due writes allowed, a future assignment still refused, notices on prompts 1 and 11 only, exactly
one hand of each kind, no network call from any hook (strace), and `late_work.allow: false` restoring the old refusal.

Build ✅ · Deploy 🔵 · Blocker: Temporal (needs Teach 0.19.0 live for the new hand types; older Teach gets student_request).

### 3.8 · Grade view

Since 0.19.0 (`STD-GRADE-VIEW`) `reach grade` shows the points Teach 0.19.0 records per assignment and in total, or says
grades are not available yet. Verified against tools/fake_teach for empty, populated, 404, 403 and offline answers; Teach
records no points yet.

Build ✅ · Deploy 🔵 · Blocker: Human (Teach has no way to record points yet).

### 3.9 · Hand types

Since 0.19.0 (`STD-HAND-TYPES`) every hand carries one of nineteen types, chosen by the agent for a student's request;
a Teach without the 2026-10-02e wire receives student_request with the type in the summary. Verified against
tools/fake_teach with a matching and a mismatched wire digest; Teach 0.19.0 accepted every type on scratch PostgreSQL.

Build ✅ · Deploy 🔵 · Blocker: Temporal (Teach 0.19.0 not yet live).

### 3.10 · Extra-credit codes

Since 0.20.0 (`STD-EXTRA-CREDIT`, wire 2026-10-02f) `reach extra-credit CODE ANSWER` redeems a code the instructor texted
the student, keeps the entry in the profile's `extra_credit` list (pending, recorded or refused), retries pending
entries and pulls Teach's list on `reach sync`. Verified against an extended tools/fake_teach for recorded, unknown,
expired, used, offline-then-sync with the same Idempotency-Key, pull of a Teach-only entry, locked install and MCP, and
end to end against a scratch Teach 0.20.0 (recorded, refused, offline then synced).

Build ✅ · Deploy 🔵 · Blocker: Temporal (students update to 0.20.0 on their own).

### 3.11 · Version report

Since 0.21.0 (`STD-VERSION-REPORT`, wire 2026-10-03a, `W-AUTH-7`) every request rEach signs carries `X-Reach-Version`,
so Teach always knows which rEach each install runs, including after a self-update, and shows it in its console.
Verified against tools/fake_teach (status, sync and a hand raise carried the version; enrollment preview and enroll
carried none) and by the Assignment 1 smoke against a Teach of the same wire revision.

Build ✅ · Deploy 🔵 · Blocker: Temporal (students update to 0.21.0 on their own; Teach 0.22.0 must be live).

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

### 4.3 · Persona, skills and agent

One persona body serves two files, `skills/reach-assistant/SKILL.md` and `agents/reach.md` (STD-PERSONA-ONE-SOURCE;
`reach doctor` checks them, R-DOC-PERSONA), plus `rules/reach.md` for Antigravity and `settings.json` naming
`reach:reach` as the session agent. The course skills are `reach-course` (how to work a slice under the instructors'
rules, reading the directive table, never spawning subagents), `reach-feature` and `reach-bug` (the two code flows, 2.11),
`reach-build` and `reach-fix` (routes to those flows), `reach-checkpoint`, `reach-submit` (runs `reach part` first) and
`reach-help` (`reach hand raise`). `skills/design-taste-frontend` is the vendored taste skill for panel slices, its
provenance checked by R-DOC-TASTE. Verified live on Claude Code with Haiku and Sonnet (course-gate, coaching, off-topic,
crisis and own-part scenarios, 2.22, 2.23, 2.18) and on Hermes with Sonnet (10.5). Unverified: the persona on Codex and
Antigravity sessions, and whether Claude applies `settings.json` `"agent": "reach:reach"` for an installed plugin (TODO.md).

Build ✅ · Deploy 🔵 · Blocker: Human (Codex, Antigravity and the plugin `agent` setting).

### 4.3.1 · Plain talk for new computer users

Since 0.18.1 (`STD-PLAIN-TALK`) the persona's "How you talk with the student" section binds in every session and
folder: the agent treats the student as a new computer user, keeps commands and rEach's workings out of the
conversation unless the student asks for exactly that, describes student-only steps as what to click, and goes faster
or deeper only on evidence (profile coding experience "quite a bit", a remembered finding, or the student's own
request), which it records with `reach remember`. `M-AGENT-TALK` repeats the rule in the signed-in, sign-in-pending
and locked session contexts. Verified 2026-10-02 with Sonnet given the persona and the signed-in context: asked to
open a side-project folder or fix a failed update, it answered in plain words and named no command. Codex,
Antigravity and Hermes sessions were not run.

Build ✅ · Deploy 🔵 · Blocker: Temporal (students receive it on their next auto-update).

### 4.4 · Real-Claude smoke

`tools/smoke/run.rb` with `tools/smoke/scenarios.yml` drives real Claude sessions with rEach loaded, each in a Docker
sandbox, against a scratch Teach on its own `reach_smoke_<run>` database, with a judge rubric per scenario and checks on
the transcript, tool use, workspace files and Teach's hands and transfers. Verified: run 20260929-040851 (7/7 and 5/5),
20260929-060009 (8 of 8 scenarios on Haiku), and the course-alignment scenarios judged live on 2026-10-01. It spends a
Claude token per scenario. Its enrollment step still uses the v1 per-student code (TODO.md).

Build ✅ · Deploy ⚫ (never runs on a student's computer) · Blocker: Engineering (the enrollment step predates enrollment v2).

### 4.5 · Fake Teach

`tools/fake_teach/server.rb` is a local stand-in for Teach's half of enrollment v2 (health, enrollment preview, enroll
shape v2, an install-signed status; every other route answers 404), with fixture courses and a roster. It is a fixture,
not Teach, and `tools/platform_smoke` (2.28) and the enrollment-v2 verification (2.27) run against it. Since 0.16.21 it
answers `400 password_required` like Teach 0.17.0.

Build ✅ · Deploy ⚫ · Blocker: -

## 5 · Interview and profile

### 5.1 · Intake interview and student profile

`reach hello`'s first-run interview asks twelve single-thing questions (studies/year, coding and AI experience, the
course's own interview question, goal, explanation style, creative lead, work times, deadline reminders) and stores
the answers in `~/.reach/profile.yml` only — never synced to Teach, never in a workspace. `reach profile
show|save|forget` and the matching MCP tools manage it directly.

Build ✅ · Deploy 🔵 · Blocker: -.

## 6 · MCP bridge

### 6.1 · MCP tools beyond reference

The MCP bridge (`.mcp.json`, Claude Code and Cowork) exposes 27 tools beyond `reach_reference` (3.1): `reach_hello`,
`reach_enroll`, `reach_sync`, `reach_status`, `reach_check`, `reach_shape_check`, `reach_checkpoint`, `reach_plan`,
`reach_submit`, `reach_receipts`, `reach_qualify`, `reach_attempts`, `reach_raise_hand`, `reach_hand_status`, `reach_directive`,
`reach_profile_show`, `reach_profile_save`, `reach_profile_forget`, and since 0.14.3 `reach_support`, `reach_part`,
`reach_transfer_request`, `reach_modules` and `reach_next`, and since 0.16.15 `reach_remember`, `reach_recall` and
`reach_memory_forget` (2.29), since 0.21.12 `reach_update` (2.30), and since 0.30.0 `reach_announcements` (2.43) — each a thin wrapper the agent calls instead of shelling out to
the `reach` CLI. The five 0.14.3 tools were driven over stdio against a scratch Teach on 2026-10-01: the transfer tool
returned Reach's own question and sent nothing until a captured yes, then one pending request reached Teach; the support
tool returned 911/988 and Teach held a hand; the part tool listed the A1 questions.

Build ✅ · Deploy 🔵 · Blocker: -.

## 7 · Doctor

### 7.1 · Doctor's individual checks

`reach doctor` runs 18 checks — Ruby version/floor, the shim, harness detection, enrollment, keys, guard state,
workspaces, Chrome (for the taste skill's pre-flight), gems, network reachability, the outbox, outdated packages,
the wire contract digest, version agreement across manifests, the persona files, the public directive table
(R-DOC-DIRECTIVES), the vendored taste skill's provenance (R-DOC-TASTE), and the sidecar — printing one line per
finding and exiting 1 if any fired. Since 0.16.2 R-DOC-GUARD and R-DOC-SEAL wait for enrollment, so a
student who has not enrolled yet (or whose AI app sandbox cannot write the seal) no longer sees them, and an
R-DOC-DIRECTIVES finding names why the file did not parse. Verified 2026-10-01 inside `codex sandbox` (codex-cli
0.159.3) before and after enrollment. Since 0.16.9 a fresh install that has not enrolled yet is not a finding
either: doctor prints an `enrollment:` line with the same words the gate uses and exits 0 when nothing else is
wrong, while a revoked, damaged, moved or course-ended enrollment is still R-DOC-ENROLL; and the harness version
probe keeps the harness's own stderr out of doctor's output (Codex warns that it "could not create PATH aliases"
whenever it runs inside its own sandbox). Verified 2026-10-01 inside `codex sandbox` (codex-cli 0.159.3) on a
fresh home (0.16.8: exit 1, R-DOC-ENROLL and the Codex warning; 0.16.9: exit 0, the `enrollment:` line, empty
stderr), under Ruby 2.6.10, and against a revoked and a damaged `install.yml` (both still R-DOC-ENROLL, exit 1).

Build ✅ · Deploy 🔵 · Blocker: -.

### 7.2 · Diagnostic report and kit Ruby fallback

Since 0.21.3 `reach doctor --report [--offline] [--format json]` prints every fact a field failure needs and no
secret: the running Ruby, its SSL library and whether native GCM works, the runtime kit, the home and Reach home,
the harness and sandbox variables, crypto self-tests, the same GCM test under every other Ruby on the computer, and
each package opened stage by stage from the stored copy and from Teach, with the network cause of a failed fetch.
On a Ruby whose LibreSSL cannot use GCM additional authenticated data (macOS's Ruby 2.6.10), every command runs
again under the kit Ruby when the kit is installed, or starts the kit install and carries on with the pure-Ruby GCM
of 0.20.6; `REACH_KIT_FALLBACK=0` turns it off. Debug session and sync events carry the same facts and the scrubbed
sync warning texts. Verified in GitHub Actions platform run 37100202414 before the rebase onto 0.21.2: 17 of 17
steps on macOS arm64 and Intel (system Ruby 2.6.10, LibreSSL 3.3.6), where `reach doctor --report` inside
`codex sandbox` (Codex CLI 0.160.0) moved to the kit Ruby 4.0.7 (OpenSSL 3.6.2) and opened the stored guardrails
package, and green on Linux and both Windows legs. Run 37100526911 on the rebased 0.21.3 passed again: 16 of 16 on
both macOS legs, with both package kinds opening from storage and from fake_teach under the kit Ruby.

Build ✅ · Deploy 🔵 · Blocker: -.

## 8 · Shape check

### 8.1 · Shape check internals

`Reach::Shape` runs 19 rules against a slice's panel once a shape has been published for it: 9 invisible-hazard
rules (S-LIF/S-ID/S-STO/S-DAT/S-EVT/S-KEY/S-DYN/S-I18N/S-CSS, one code each) and 10 visible-defect rules
(S-OVL/S-LAY/S-CSS/S-HTML/S-STATE/S-NAV). Findings without a published shape are reported as "nothing to check," not
an error. A real signed Dovetail shape has verified the parser end to end (0.4.2, 0.6.0). Since 0.9.0, when the
checker ran on a signed shape, `reach check` drops CK-PANEL's S-* findings, which CK-SHAPE already reports, and keeps
CK-PANEL-TS, CK-FUSE, CK-TEST and CK-COMMENT; with no shape or an unrunnable checker every CK-PANEL rule runs.
Since 0.14.6 shape findings are kept only for the workspace's owned files: Teach ships no suite package, so the
instructors' Panel.svelte is absent and the checker reported S-STATE-001 on it. Verified on a copy of a peer's
finance.a3s2 panel workspace: the two Panel.svelte findings are gone, status reads "shape: ok", and a literal colour
put into the student's own cutout is still reported.

Build ✅ · Deploy 🔵 · Blocker: -.

## 9 · Directives

### 9.1 · Public directive table

`directives/` holds the 13 public engineering directives (one Markdown file per opcode, frontmatter plus body,
88-character rule cap): CHECKPOINT, CODEFILE, DOVETAIL, FLOW, LEAN, NOCOM, PLAN1ST, PURE, QUALIFY, RESUME, RUBY, TOZERO and
VERIFY, rendered into `AGENTS.md`'s directive table (and `CLAUDE.md` and `GEMINI.md`); course-specific directives instead reach a
student only inside the encrypted guardrails package. `reach doctor`'s R-DOC-DIRECTIVES check keeps the two in
sync.

Build ✅ · Deploy 🔵 · Blocker: -.

### 9.2 · Course directives from Teach

Course-specific directive bodies are served by Teach one at a time over a signed request and never stored on the
student's computer: `reach directive <OPCODE>` asks `GET /api/v1/directives/<OPCODE>` in quick mode, and `reach
directive --list` lists the table. Teach holds the only read log and derives `directive_dump` events itself
(STD-DIRECTIVES-CARRY-NO-SECRETS). Verified in 0.4.1 and 0.5.0 against a scratch Teach. Unverified: the course-private
rows have not run against the live Teach with a real class.

Build ✅ · Deploy 🔵 · Blocker: Human (no class has used it).

## 10 · Harness integrations

### 10.1 · Claude Code

Terminal, desktop Code tab and VS Code, installed via `.claude-plugin/plugin.json` +
`.claude-plugin/marketplace.json`; connects the MCP bridge and the `SessionStart` hook. Since 0.15.0 the package is
generated by rplugin 1.2.0. Verified 2026-10-01 by installing the 0.15.0 tree from a local marketplace into a scratch
Claude config: the `SessionStart` hook ran `reach hello` and returned rEach's context, and `plugin:reach:reach` was
connected (the model turn itself hit the smoke token's weekly limit).

Build ✅ · Deploy 🔵 · Blocker: -.

### 10.2 · Claude Cowork

Since 0.33.3 rEach does not enroll or sign in from Cowork: an unenrolled or signed-out prompt there gets one fixed
message sending the student to the Claude app's Code tab (`M-COWORK-CODE-TAB`), because Cowork showed rEach's
blocked prompt as "Claude's response came back empty". Checked with the hook run under
`CLAUDE_CODE_ENTRYPOINT=local-agent` and real Claude turns; never run in Cowork itself.

Claude desktop, plugin added from Customize > Plugins; the reason the executable lives at `exe/reach` rather than a
top-level `bin/` (Cowork refuses a plugin that carries one).

Build ✅ · Deploy 🔵 · Blocker: Human (no session has been run).

### 10.3 · Codex

Since 0.33.4 a yes or no typed in a Codex chat to the Codex setup question is taken by the plugin's prompt hook
(`gate enroll`), not only by a course folder's prompt hook, which Codex does not run until the folder and the hook
are trusted. The plugin hook no longer counts as proof that the course-folder prompt hook runs, so a Codex that runs
only the plugin's hooks is told so (`M-HOOKS-REQUIRED`, `M-PART-NO-HOOK`) instead of leaving answers unsaved. Checked
on a scratch Teach and a scratch Codex home with the hook commands run by hand; never run in a real Codex chat.

CLI, IDE and desktop app, installed via `.codex-plugin/plugin.json` + `.agents/plugins/marketplace.json` (Codex
reads its hook through its manifest). Since 0.15.0 the package is generated by rplugin 1.2.0 and carries the MCP
bridge: installed from a local marketplace into a scratch Codex home on 2026-10-01, Codex loaded all 24 `reach_*`
tools from its plugin cache through `${PLUGIN_ROOT}`. The start-up hook moved to `hooks/codex.json` and was not run
in that test, since Codex runs plugin hooks only after the trust review; it asks the student to trust it again. The
operator ran a live Codex session
with the plugin installed on 2026-09-29 — hook-trust prompt, `SessionStart` context and greeting all confirmed — and
separately ran the manual Codex dialogue pass and the same-WiFi second-device test from `docs/smoke-assignment-1.md`
the same day.

Codex 0.156 and newer takes the Agent Plugins root `plugin.json` over `.codex-plugin/plugin.json` and then loads no
plugin hooks (openai/codex#47925), which hid both hooks from the trust review in every rEach release. Since 0.16.16
`Reach::CodexCache.repair` renames that file to `plugin.json.agent-plugins` in Codex's cached copy of rEach only, from
`reach setup`, `update/apply.rb` and `reach mcp`. Verified 2026-10-01 against Codex 0.160.0 in scratch Codex homes
through `codex app-server` `hooks/list`: 0 plugin hooks before, and the SessionStart and UserPromptSubmit hooks listed
as untrusted after setup, after `reach mcp` on a plain `codex plugin add` install, and after the update step.

Build ✅ · Deploy 🔵 · Blocker: Human (a live Codex session on macOS has not yet trusted and run both hooks on 0.16.16).

### 10.4 · Antigravity

Google's agent app and CLI (replaced Gemini CLI in 2026); reads `plugin.json` (Agent Plugins 1.0) and
`rules/reach.md` as its always-on pointer to `reach hello`. Antigravity has no documented hook format, so it ships
none; since 0.9.0 it runs `REACH_HARNESS=antigravity reach submit`, so Teach notes its submissions as unwitnessed
(2.14). `agy` is not installed on the development machine, so `reach setup --harness antigravity` and the
plugin-directory link are untested.
Since 0.23.1 (`STD-NOHOOK-ENROLL`) a locked Antigravity session is told to walk the student through `reach enroll`
in a terminal window at once, because rEach cannot ask for enrollment details in an app without hooks; a student
reported being sent to their instructor instead (2026-10-03). Exercised with `reach hello` in a scratch home on
Linux only.

Build ✅ · Deploy 🔵 · Blocker: Human (no session has been run; `agy` not installed here).

### 10.5 · Hermes

Nous Research's Hermes Agent CLI, through a dedicated Hermes profile named `reach` that `reach setup --harness hermes`
creates (`--clone --no-alias`) and `reach work --harness hermes` launches with `--accept-hooks`. Hooks, the MCP bridge
and a disabled `code_execution` toolset live in that profile's `config.yaml` only; the student's other profiles are
untouched. Verified 2026-09-29 against hermes-agent 2026.9.24 in a scratch `HERMES_HOME`: setup kept every base key
and was idempotent, and a real Hermes chat session driven by a scripted local model showed the greeting context on the
first turn, an owned write allowed, a non-owned write, a V4A patch and `git status` refused with Reach's messages,
`execute_code` absent, `pre_verify` handing `reach check` findings back to the model, and the prompt, actions, one code
entry, the reply and its chat snippet in the course record with harness `hermes`. Limits: Hermes cannot refuse a
prompt (it reaches the model marked blocked, with the refusal as context), and Hermes started without `reach work` or
under another profile is not gated.

Verified again 2026-09-29 against a local Teach 0.11.1 (a real enrollment code, the real `context.a1` backend slice
and Teach's own course rules): `reach setup --harness hermes` and `reach work --harness hermes` from a clean student
home, the gate, `reach check` through `pre_verify`, `reach qualify` and the attempt ladder (a hand at the third
failure), submit refused while unqualified, and 28 to 42 course-record entries per session filed on Teach as a
`hermes` chat. With Claude Sonnet as Hermes' model (through a local shim over `claude -p`, not a Hermes provider) the
agent followed the course skill and the feature flow, planned first, spoke only in business terms, wrote its own
scenarios and passed Teach's qualification (4 of 4 on the build, 4 of 4 failing on the starting copy, hidden 3 of 3),
and declined to submit while the student's README was blank. With Qwen3-Coder-30B (llama.cpp) the agent named code
to the student and called failing work ready; Reach's submit refusal held. Not yet run: installing from the link
through `INSTALL.md`, an interactive Hermes session, a Hermes provider connection (Anthropic, OpenRouter, Nous),
macOS or Windows, and a hosted Teach.

Build ✅ · Deploy 🔵 · Blocker: Human (install-from-link, an interactive session and a hosted Teach not yet run).

### 10.6 · Plugin packaging and hooks

`reach.rplugin.yml` is the manifest, and `rplugin package` (rplugin 1.2.0 and later) generates `.claude-plugin/`,
`.codex-plugin/`, `.agents/plugins/marketplace.json`, `plugin.json`, `mcp.json` (`reach mcp`, `${PLUGIN_ROOT}`),
`hooks/hooks.json` for Claude Code and `hooks/codex.json` for Codex from `hooks/reach.hooks.yml`: a non-blocking
`SessionStart` hook running `reach hello` and a blocking `UserPromptSubmit` hook running `reach gate enroll`, 10 and 60
second timeouts. The manifest claims `hermes: unsupported` so `rplugin install` leaves the default Hermes profile alone
(0.16.11). Every course folder gets its own hooks and rules files besides these (2.15). Verified: `rplugin check` 0,
`rplugin doctor reach` 0, a scratch Claude Code install ran the `SessionStart` hook, a scratch Codex install loaded the
bridge, `rplugin install --dry-run`. Unverified: `rplugin install reach` has not been applied for real on this machine
(a conflicting `~/.claude/skills/design-taste-frontend` and the id/directory-name mismatch block it), and on a developer
machine it links the persona into every session (TODO.md).

Since 0.21.12 the Codex MCP server starts on Windows and after the cache repair: the root `mcp.json` runs `ruby` (not
`sh`, which Windows lacks) and `.codex-plugin/plugin.json` runs `ruby exe/reach mcp` with `"cwd": "."`, because Codex
0.160 does not expand `${PLUGIN_ROOT}` there. Verified in a scratch `CODEX_HOME` with Codex 0.160.0: before and after the
repair Codex launched a command that started the real server (36 tools, `reach_update` among them), and the root launch
set the root manifest aside. Not yet seen on a Windows machine. Since 0.21.14 the generated files come from the sources again: `hooks/reach.hooks.yml` gives Codex its `ruby` hooks through
`run_by_harness` and `reach.rplugin.yml` gives `.mcp.json` its `sh exe/reach-run` through `by_harness` (rplugin 1.6.5), and
`rplugin package --check` reports 0 stale files; the shipped hook command text did not change.

Build ✅ · Deploy 🔵 · Blocker: Human (real install not applied on the development machine; no Windows Codex run).

## 11 · Planned

### 11.1 · Analytics keyed to the enrolled student

Decide and document which usage data, metadata and analytics rEach sends to Teach, and send them keyed to the
enrollment (TODO.md, docs/DESIGN-DECISIONS.md). Nothing is built.

Build ⚪ · Deploy ⚫ · Blocker: Human (the decision).

### 11.2 · Corpus-side recall in the student's kit

Ship rplugin and rcorpus in the runtime kit so a student's computer runs `Rcorpus::Context` recall and
`Rcorpus::Consolidate`; deferred 2026-10-01 pending the decision to publish them. Students run on the spool and Reach's
own recall (2.29).

Build ⚪ · Deploy ⚫ · Blocker: Human (publication decision).

### 11.3 · Erasing admitted corpus history

`reach memory forget` scrubs Reach's spool only, so a finding or source already admitted into a plane stays there until
rcorpus can erase a tombstoned id (TODO.md). Not built.

Build ⚪ · Deploy ⚫ · Blocker: Engineering (rcorpus).

### 11.4 · One rEach folder

Everything rEach keeps moves into one folder the student works in, so that Codex on Windows can return to its default
permissions after install; planned for 0.17.0, which has to prove it on Windows (docs/DESIGN-DECISIONS.md).

Build ⚪ · Deploy ⚫ · Blocker: Engineering.

### 11.5 · Git in the flows

Reach 2.0 brings version control into the feature and bug flows (ROADMAP.md); until then git is refused in slices (2.11).

Build ⚪ · Deploy ⚫ · Blocker: Engineering.

### 11.6 · Licence

The licence is `undecided` in `reach.spec.yml`; it must be decided before a public release (TODO.md). `exe/reach` and
`lib/reach.rb` carry an MIT SPDX line.

Build ⚪ · Deploy ⚫ · Blocker: Human.

### 11.7 · Security audit mode for releases

Since 0.34.0 (`STD-SECURITY-AUDIT-MODE`) a release push to GitHub passes a pre-push gate first: a scan for secrets,
credential files, local paths and student data (a salted hashed roster from Teach), then a headless read-only Claude
Code audit, blocking on a finding at or above the severity set on Teach's Ops page. Maintainer tooling only; nothing
students run changes. Checked on 2026-10-05 against a scratch remote and a stub Teach: a non-release push passes
silently, a planted private key and a seeded student email and name block with masked reports, a clean release ran a
real Haiku audit ($0.26) whose verdict the tag push reused, a stopped Teach falls back to the cached settings and
roster, the kill switch skips, and report-only never blocks. Interim: raudit takes the gate over fleet-wide. Not yet
run under Ruby 2.6.10, against live Teach, or on a real release.

Build ✅ · Deploy 🔵 · Blocker: -

## Appendix · Blocked by

- **Access**: 1.2.
- **Human**: 1.3, 1.5, 1.6, 1.7, 2.30, 2.31, 2.33, 2.35, 2.37, 3.2, 4.3, 9.2, 10.2, 10.4, 10.5, 10.6, 11.1, 11.2, 11.6.
- **Engineering**: 1.1 (the Windows installer path is unverified), 4.4, 11.3, 11.4, 11.5.
