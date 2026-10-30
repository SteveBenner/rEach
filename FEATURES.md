# FEATURES — rEach

## Public-repository exposure in the release gate — 0.68.0

The release gate now knows whether the repository it guards is public. It checks a machine-local list of public and private remote patterns first, then asks GitHub (cached for an hour), and treats anything it cannot tell as public. On a public repository:
- an exposure finding (anything the deterministic scan finds, or a model finding about secrets, student or course data, internal process, self-talk, local paths or other exposure) blocks the push, and no lease or override can let it through;
- a new `private-name` scan check flags added lines that contain a term from a machine-local private-terms list, and shows only the term's first two characters;
- home paths are high findings;
- the model audit runs only at release time, and other pushes run the deterministic scan.

Private repositories behave as before and run no private-name check.

Build ✅ · Deploy 🔵 · Blocker: none (the course server's pinned copy of the gate is re-pinned next).

Verified on 2026-10-28 on Linux in scratch repositories, with a local lease responder and a stubbed model:
- With an active lease, a public remote and an added `*.impl.yml` line holding a listed term, the run stayed blocked with the critical private-name finding and printed the exposure note (exit 1).
- The same repository with a private remote pattern was leased (exit 0) and reported no private-name finding.
- A wildcard SEC-SCAN override did not unblock the public run, and it did override the private one.
- A github.com remote was public with `gh` absent, with a `gh` error and after a hung `gh` (5 seconds). A live lookup of this repository returned public and was cached. A stub answering PRIVATE gave private.
- With no private-terms file, the scan completed and reported one informational note.
- The scan gave critical private-name and high local-path on public, and medium local-path only on private.
- On a public push without a release, only the deterministic scan ran and the console said so. A push with a version change, and a check without `--as-push`, ran the model audit.
- `ruby -wc` passed on all four changed Ruby files.

## Document assignments — 0.67.0

An instructor can make an assignment a document assignment (wire revision 2026-10-26a): written work handed in as files instead of code. `reach sync` gives the student a folder with a read-only `INSTRUCTIONS.md` (the title and the task, no due line) and the usual rules files; there is no README, brief, plan, qualification or shape check. The student and the agent write in the folder, and the agent may create and edit only `.md` and `.txt` files; pdf, Word, OpenDocument and image files the student adds are theirs. `reach submit` lists the files, refuses an empty folder, more than 200 files, a name over 255 bytes, names that differ only by case, a file with no extension or a kind the assignment does not accept (naming the file; nothing is sent), asks the student's yes, and sends one body with an idempotency key, waiting up to two minutes. After a timeout it asks Teach by that key before it queues the body once in the outbox. The grade arrives in percent with the instructor's feedback and shows in `reach grades`, `reach status` and `reach next`; a grade for an earlier submission is marked as that. An assignment handed in elsewhere keeps only `INSTRUCTIONS.md`, records no transcript and stays out of late lists, hands and exports. Directives now carry a `slice` scope: ten engineering directives apply to code slices only, and the new `FLOWDOC` and `RESUMEDOC` apply to document slices.

Build ✅ · Deploy ✅ stable since 0.68.0 (2026-10-28), with the course server's half live · Blocker: none. Resubmission after the due time is accepted and Teach marks it late (decision 2026-10-28).

Verified on 2026-10-28 on Linux, only in scratch homes, against an in-process stand-in for Teach (no socket), before and after the rebase onto 0.65.0:
- Sync provisioned `INSTRUCTIONS.md` with no due line and no README; essay.md and figure.png were submitted on a yes with Thumbs.db, `~$` lock files, .DS_Store, .tmp files and the generated files left out; a `.exe` was refused naming it with nothing sent.
- The gate allowed an agent write to essay.md and notes.txt and refused AGENTS.md, INSTRUCTIONS.md, `.claude/settings.json`, `materials/` and a binary figure.png.
- A grade of 82% with feedback showed in `reach grades`, status and next; after a resubmission all three marked it as for the earlier submission.
- An upload that timed out after the server stored it sent one POST, then asked by idempotency key and did not post again; with the key unknown it queued, and the next sync sent it once.
- An elsewhere assignment held only the read-only `INSTRUCTIONS.md`, refused writes and submission with the instructor's note, recorded no transcript and was not a late assignment.
- The directives were compiled with the candidate polispec 0.51.0: `ruby tools/policy.rb check` was ok, `Reach::Directives.problems` was empty, a document slice's rules file lists only FLOWDOC and RESUMEDOC and a code slice lists the ten code directives.

Verified on 2026-10-28 in process against the course server's own code, the 0.67.0 client with only the network call replaced, no socket:
- A 0.65.0 client was withheld (the course server then cut at 0.65.1; it now cuts at 0.67.0): its status showed no document slices and its workspace package request was refused as an invalid assignment; the 0.67.0 client saw BOOK as the current document assignment and `slices`, `packages` and late entries as Teach built them.
- A `.exe` was refused naming `run.exe`, with no POST. A submission with essay.md and figure.png was accepted: Teach stored it as `awaiting_grade`, attempt 1, not late, never offered to the grader queue, and the signed ingest receipt verified and was acknowledged.
- An assignment handed in elsewhere (FINAL): submit was refused locally with the instructor's note and no POST; a forced POST was answered 403 `submit_elsewhere`; Teach stored 0 submissions.
- A grade of 87.5% with feedback entered by the instructor reached the student on the next sync as `88%` with the feedback; `reach grades`, status and next agreed after fix 3 below, and next said to review. A grade of 50% also sent the student to review.
- Resubmission gave attempt 2 (`awaiting_grade`) while attempt 1 stayed `graded`; `reach grades` showed `88% (for your earlier submission; your newest one has not been graded yet)` and next said to wait.
- An upload whose read timed out after Teach stored it sent 1 POST and then one GET by idempotency key, which returned 200; attempt 3 was `awaiting_grade` with no second POST.
- A late assignment (LATEDOC) accepted attempts 1 and 2 with `late` 1 on Teach and `late: true` on both ingest receipts.
- The version stamp in `DOCUMENT_FROM_REACH` matched the client (0.67.0).
- After the round 3 fixes the same run again showed: FINAL, a released elsewhere assignment that was not the current one, was provisioned with a mode 444 `INSTRUCTIONS.md` and no late mention while BOOK was current (status listed only LATEDOC as late work); a grade and its ingest receipt in the same second ordered the grade first in `Reach::Receipts.list` in three scratch runs with the two timestamps forced equal, and next read `M-NEXT-DOC-REVIEW`; the 87.5 grade read `88%` in sync, status and `reach grades`.

Not verified: any request to a live Teach, uploads near 26 MiB and the 36 MiB body limit, 200 or more files, Windows and macOS, a real harness session writing to a document folder, `sidecar verify` with an empty student part, and the regenerated course matrix proof digests. With the installed polispec 0.51.2, `ruby tools/policy.rb check` was ok.

Student-first audit:

1. Learning: partly. The agent may write md and txt, so a student can lean on it for the text itself; FLOWDOC says to help in the student's own words, and an instructor who wants the exam done without help switches the assignment to hand-in elsewhere, which this version names but cannot enforce.
2. Agency and honesty: yes. The student sees the exact file list and types the yes, and an unaccepted file is named, not dropped.
3. Wellbeing and safety: yes. No countdown or pressure is added, and resubmission stays open.
4. Privacy and dignity: partly. The agent's writes are witnessed and the instructor sees which files the agent wrote; files the student adds are sent as they are, and a binary file is never read into the history.
5. Fairness and access: yes. Any kind the instructor accepts works, and the limits are plain: 25 MiB of files, 200 files.
6. Friction: yes. Drop files in the folder and ask to submit; the wait of up to two minutes is stated in the ask.
7. Failure: safe. A timeout is resolved by the idempotency key before any re-upload, an unreachable server queues the body once, and a refused submit sends nothing.
8. Recovery: partly. Recovery is resubmission until the due time and a later submission as late work; checkpoints keep text files in full but binary files only by digest, so a lost pdf or Word file must come from the student's own copy.

Known limits:
- Storage: the 50-attempt cap stays, so the worst case is 25 MiB x 50 per student per assignment; retention is a later decision.
- `STD-WIRE-DRIFT-ALARM` is expected to fire between the Teach and rEach deploys.
- Agents write only md and txt; an agent cannot produce a Word or pdf file for the student.
- The route `GET /api/v1/submissions?idempotency_key=K` and the policy key `grading.pass_percent` (default 60, when a low grade sends the student to review) are new in this revision.

## Reclaim earlier memory and work — 0.65.0

`reach reclaim` (and the `reach_reclaim` tool and `reach-reclaim` skill) finds the older rEach memory and course folders an earlier install left on the computer and brings them back after the student's typed yes. It lists the microbrain folders of the legacy `~/.reach`, of `.reach-home.set-aside-*`, `.reach-home.failed-*` and `.reach-home.pre-*` folders, of other `reach-work*` folders and of `.reach-brain`; it takes only memory that carries the enrolled student's ID and lists, then leaves alone, another student's memory and memory with no owner (the pre-enrollment `local` folder is taken only with `--only brain`). The merge never overwrites (the larger reinforcement counts, the union of pending erases, SHA-256 checks), `reclaimed.jsonl` makes a repeat a no-op, and an old folder is removed only after everything in it is settled. Course folders whose rules files are missing are adopted in place after a checkpoint autosave; `--from FOLDER` copies deliverables and extracurricular files without moving or overwriting and lists files that differ. The consent kind is `reclaim`, `--only brain|work|from` narrows it, and the greeting offers it once (`G-RECLAIM-OFFER`). The microbrain's state moved to `<reach-work>/.reach-brain/<student key>/` with an `owner.json`, migrated silently with a `MOVED.json`, and `reach uninstall` now keeps it unless `--purge-microbrain` is given. Contract: `STD-RECLAIM`, `STD-BRAIN`, `STD-UNINSTALL`, `STD-STORAGE-GATES` in `specs/app.yml`.

Build ✅ · Deploy 🔵 · Blocker: Human (stable promotion).

Verified on 2026-10-27 on Linux, only in scratch homes:
- Migration moved a populated `<home>/brain` with sha256-identical files, wrote `MOVED.json`, and `owner.json` named the student. A second student ID on the same account saw only its own brain. An `owner.json` naming another student made the brain unavailable and logged `brain.owner_mismatch`. On 2026-10-28 a home brain whose sessions named only another student was not moved and logged `brain.migrate_skipped_other_owner`, and one naming the student moved.
- The uninstall plan listed the kept microbrain and, with `--purge-microbrain`, its deletion.
- Reclaim listed an owned set-aside brain, another student's brain and the pre-enrollment `local` brain, and merged only the owned one on a typed yes (maximum reinforcement counts, union of pending erases). A repeat run was a no-op, and `local` was taken only with `--only brain`.
- `--from` copied new files, left a differing deliverable unchanged and listed it, skipped a symlink and `AGENTS.md`, and a repeat said already brought back.
- `hello` showed `G-RECLAIM-OFFER` once.

Not verified: adopting a real course folder with a real guardrails package (it ran only with the rules renderer stubbed), the `checkpoints_recover` hand-off, `reach_reclaim` over a real MCP session, the consent hook capturing a real typed yes, Windows and macOS, and uninstall apply and purge (only the plan output was read).

Student-first audit:

1. Learning: n/a. Nothing in the course path changes; the student's own earlier notes and files come back.
2. Agency and honesty: yes. The student sees the list first, only their own typed yes counts, `--only` narrows it, and the offer never acts by itself.
3. Wellbeing and safety: yes. No pressure is added; the offer appears once.
4. Privacy and dignity: partly. Another student's brain folder and memory with no owner are listed and left alone, and nothing is sent to the course server; the brain spool stays shared per computer account (Known limits).
5. Fairness and access: yes. The same flow in every app; Windows and macOS are unverified and say so.
6. Friction: yes. One command and one yes, and the move of the active home's own memory needs no step at all.
7. Failure: safe. Nothing is overwritten, a source is removed only after every file in it is settled, and a failed course folder is named while the others go on.
8. Recovery: yes. `--from` only copies, a repeat is a no-op, and the uninstall now keeps the memory so a later install finds it again.

Known limits:
- Before this version the uninstall question never said the brain spool (every prompt the student typed, under the rplugin state folder) stays. It does now (`M-UNINSTALL-BRAIN-KEEP`).
- The brain spool (findings and the copy of what was typed) is shared by every student on one operating-system account, and `BrainIndex` does not filter it by student ID, so `owner.json` separates only the `.reach-brain` folder. It is left as it was, and `--purge-microbrain` deletes the spool for everyone on the account.
- `reach reclaim --from` copies from any folder the student names after their yes and does not check whose files they are.
- The planes corpus is deleted with the home while `brain-spool/admitted` stays, so explicit planes recall restarts empty after a reinstall, though lexical recall sees everything.

## Full course smoke suite (0.61.0)

Build: runnable native fixture suite, planner, external agent-adapter interface, and evidence verifier implemented. Deploy: developer tooling only, not published. Complete r8 sweep: 278 passed and two failed out of 280 attempted; subsequent r9 fixture correction: both affected cases passed. These are separate source cohorts, not a single green 280-case snapshot. Commands and evidence protocol: `tools/smoke/README.md`.

The pinned Grokit v0.10.1 inventory has ten modules and seventy cutouts across A1–A4. Both backend and panel slices under both course profiles yield 280 cases. One synthetic profile uses student choice, the other instructor assignment. Every case includes all assignment question shapes and its slice's tagged native acceptance scenarios. Passing requires all fifteen pipeline stages, local and Teach qualification, matching signed ingest and grade receipts, and the student-facing receipt number. A plan, missing evidence, skip, partial submission, budget stop, or empty successful adapter never proves a pass. `coverage_complete` requires the whole inventory to execute successfully.

Native execution creates fresh scratch databases and course profiles, copies public Teach source, shifts dates only in that copy, and runs real Reach/Teach code and Docker graders. Only Reach HTTP transport and network pacing are replaced in process; deployed networking, TLS, and model conversation quality are not claimed. Pinned developer reference code and scenarios are explicit fixtures, not student work or proof of an agent build. No model calls occur in native mode. Each case has independent state and bounded logs/time, and only its own temporary grading containers are cleaned up.

Evidence: `.scratch/course-full-merged-r8/report.json` and `report.md` account for all 280 unique cases. Both courses had 139 passes and one failure. A1 passed 40/40; A2 passed 80/80; A3 passed 78/80; A4 passed 80/80. The two failures were Finance A3s2 backend fixtures constructing an ungranted Money zero. The generator now reduces existing typed amounts on the nonempty aggregation path, with a pinned-source shape check and build evidence. Both course profiles then passed every stage in `.scratch/course-finance-correction-r9`. The baseline remains failed, the correction remains a subset, and their source fingerprints are retained separately.

The sweep also verified the prior runtime corrections: exact declared instructor API/exception grants, distinct local practice versus protected grading scenario coverage, and visible signed receipt references. Ungranted constants remain refused. Decimal helpers are owned inside adapted fixtures, with stale private imports removed. Teach still independently runs every protected graded case and enforces submission gates. Reports include per-assignment/slice counts, failed stages, and native failure reasons. Earlier r3 raw directories and archives were removed outside this session; no deletion was performed here, and their former paths are not current evidence.

Resource guards (0.61.0): output only under an ignored `.scratch/`, disk preflight at three times the estimate, grader image preflight, a canary first case, lazy case materialization, STOP on an environment failure or three identical failures, passing cases pruned to case.json and evidence.json, and `--archive`/`--prune`. Build: ✅ implemented on branch security-validation-land (0.61.0), not merged. Deploy: developer tooling only, not published.

Checks: policy validation, rplugin check, package freshness, and doctor reported zero findings. The installer and one retry reported their Codex step timed out after 120 seconds; doctor still passed. The verifier's offline regression suite, `tools/smoke/course_matrix_check.rb` (written at Sven's request), ran 52 tests and 685 assertions with no failure, error, or skip on 2026-10-18; fourteen of fifteen deliberate verifier defects failed it, and the survivor is an equivalent change. It proves the verifier contract, not a pipeline run. It exposed that the verifier accepted a private key as the Teach public key; the verifier now refuses one, and still verifies all 280 preserved passing r8/r9 cases and refuses the two failed ones. The verifier change gives future runs a new source fingerprint; the r8 and r9 reports keep theirs. Publication remains held with the existing unpushed-main work; no production service, student data, or stable ref changed. The final report bundle is `.scratch/reach-course-smoke-20261018-r8-r9.zip`.

Student-first audit:

- Learning: yes — fabricated developer smoke answers never become student answers.
- Agency and honesty: yes — planned and executed verdicts remain distinct; enrollment still requires its native security validation pass.
- Wellbeing and safety: yes — this tooling adds no student message or pressure.
- Privacy and dignity: yes — synthetic identities and scratch homes; no live course-setting or student-data reads.
- Fairness and access: yes — both course selection paths and both slice kinds have explicit coverage.
- Friction: n/a — developer tooling adds no student steps.
- Failure: yes — failures block developer verification without touching student work or grades.
- Recovery: yes — per-case artifacts persist and cases can be selected individually.

## Security validation pass (0.61.0)

Build: ✅ on main (0.61.0, not promoted); the in-process scratch walkthrough ran the real 0.61.0 client against the Teach side of the pass. Deploy: 🔵 pending, not released or enabled for students. Blocker: Human — Teach must deploy its side first and pin wire revision 2026-10-22b byte for byte, requiring the receipt from rEach version 0.61.0; then the operator promotes rEach 0.61.0 to test and stable. Contract: `specs/security-validation.yml`.

The provided harness agent fills the practice answer shapes with fabricated data, plans and builds the practice artifacts, runs native local checks and checkpoint, asks Teach to qualify and receive the sealed package, fetches its signed receipt, and relays the verified result. Both enrollment boundaries require the fresh course, key, harness, version, challenge, and receipt binding. Failures tell the student to wait and contact the instructor through independently known details; a connection problem or impersonation is possible. This smoke uses a practice data assignment; it does not run a student's application, browser scenarios, protected scenarios, or grading.

Student-first audit:

- Learning: yes; fabrication is confined to practice work and supplies no real assignment answers.
- Agency and honesty: yes; the student hears the purpose and receives a verified result before identity or password collection.
- Wellbeing and safety: yes; the failure message is calm and directs the student to their instructor.
- Privacy and dignity: yes; validation collects no student identity or password and writes no normal student submission.
- Fairness and access: yes; the current supported harness drives the same protocol; an unavailable capability has a human recovery path.
- Friction: yes; the agent fills the practice data, and interrupted runs resume or restart.
- Failure: yes; real work and grades are untouched; the student is instructed to contact the instructor if the pass cannot complete.
- Recovery: yes; a new isolated run preserves prior practice files without reinstalling or altering real work.

Verification: the scratch walkthrough verified a signed Teach receipt, then completed a fabricated enrollment. Forged signatures, wrong course and challenge bindings, expired runs, missing passes, changed artifacts, different harnesses, wrong request keys, and proof reuse were refused. This was an in-process transport exercise, not a deployed HTTPS or platform-matrix run. Existing release blockers remain; rhomeostasis is disabled.

Since 0.64.1 the platform smoke runs the pass on every leg through the installed `reach validate` against `tools/fake_teach` over verified HTTPS before it enrolls; from 0.61.0 to 0.64.0 it had no pass, so enroll failed and the test health gate refused every stable promotion. Also since 0.64.1 the practice Check and Checkpoint mirror into the session's own directory, not the student's checkpoint mirror, so `reach doctor` no longer reports a gone security-validation work folder (R-DOC-COPIES). Verified 2026-10-23 on Linux with `ruby tools/platform_smoke/run.rb --leg test`: 18 passed, 1 skipped (the macOS-only sandbox step). The macOS and Windows legs run in `.github/workflows/platforms.yml` on push.

**The registry of the software features rEach carries, with build and deployment status.**

rEach is the student's course partner: it enrolls a student with Teach, syncs signed course packages, guards the
student's workspace, checks and plans their slice, submits it and follows the receipts, inside the student's own
agent harness.

| | |
|---|---|
| **Registry version** | 0.64.2 |
| **Last audited** | 2026-10-05 |
| **Coverage** | Complete: every surface in `README.md` and `reach.spec.yml` (enroll, sync, check, checkpoint, plan, qualify, the attempt ladder, the feature and bug flows, submit, receipts, hands, setup, installer, reference, the intake interview and profile, the MCP bridge tools (26 at 0.16.21, 41 at 0.46.1), doctor's 18 checks, the shape checker's 19 rules, the public directive table, the course record, the course folders, each supported harness catalogued on its own, and the surfaces in `lib/reach/cli.rb`'s usage text, `hooks/reach.hooks.yml`, `skills/`, `update/`, `runtime/` and `CHANGELOG.md` through 0.16.21, with planned work in section 11). |
| **Running instance** | None: rEach is a cli and plugin. Deploy is judged against the released artifact. 0.11.0 is published on GitHub `main`; no student runs it against a hosted Teach yet, so most features stay 🔵 until one does. A live Codex session against a real Teach was run by the operator on 2026-09-29 (10.3), which is the one exception. |
| **Feature count** | 108 catalogued |

## How to read this registry

Build: ✅ Shipped · 🟡 Partial · 🟠 Scaffolded · ⚪ Planned · ⛔ Torn down.
Deploy: 🟢 Live · 🟣 Live on fixtures · 🔵 Built, not enabled · 🔴 Kill-switch OFF · ⚫ No runtime path.
For a cli, 🟢 means the version students actually run carries the feature. Blockers: Access · Intelligence ·
Temporal · Inference · Financial · Human · Engineering; a dash means nothing is outstanding.

| Build | Count | Share |
|---|---|---|
| ✅ Shipped | 98 | 91% |
| ⚪ Planned | 6 | 6% |
| ⛔ Torn down | 2 | 2% |

| Deploy | Count | Share |
|---|---|---|
| 🟢 Live | 11 | 11% |
| 🟡 Partly live | 1 | 1% |
| 🔵 Built, not enabled | 83 | 77% |
| ⚫ No runtime path | 11 | 11% |

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

Since 0.53.19 the README's Install section leads with the agent-run installer, the only install that creates the
managed copy that updates itself, and shows a harness's own marketplace commands only as a manual fallback and as the
Claude app's Cowork route, where the installer cannot run; `reach.spec.yml` `installer.from_a_link` says the same, where
it had still said INSTALL.md offered the harness's plugin install and sent the Claude app and Codex app to a
marketplace. Documentation only: no code path changed, and the text reaches a student's archive only with the next
tagged release. The deployment figure (`docs/architecture.md`, figure 08) still lists a plugin marketplace as the way in
for Claude Code and Codex and was not regenerated.

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

### 1.3.1 · Moving rEach to another AI app

Since 0.44.0 (`STD-HARNESS-MOVE`) a student moves rEach to Claude Code, Codex, Antigravity, or Hermes on the same
computer without enrolling again: `reach harness move --to <app>` in a terminal, or `reach_setup` action `harness` in a
chat, which asks rEach's own question (consent kind `harness_move`) that the plugin or course-folder prompt hook takes;
in an app that runs no rEach hooks (Antigravity, or no app can be told) the chat gets the terminal command instead.
On yes it runs the same install as `reach setup --harness <app>`, rewrites every course folder's harness files, adds
the Codex settings step when the target is Codex, and says what to do next. rEach stays in the old app. Verified in the
scratchpad with stub claude, codex and agy on PATH: each target's install commands ran, a failed install changed
nothing else, unknown, same-app and declined moves did nothing, and a chat yes (fed to the consent follow-up and to the
plugin hook's `codex_setup_answer`) moved rEach while a no did not; with no app detectable or a move from Antigravity the chat got the terminal command. Not verified: a real harness, a full `gate enroll`
run signed in, Ruby 2.6.10, and Windows or macOS. A chat question asked before enrollment is not taken (the prompt hook
runs enrollment first); the terminal command works then. Since 0.44.2 (wire revision 2026-10-07b, Teach 0.76.1) Teach keeps the
install's app at the last one reported, so the console shows the app in use.

Build ✅ · Deploy ⚫ (not released) · Blocker: Human (release, push; Teach 0.76.1 deploy)

### 1.4 · Automatic updates

Since 0.13.0 Reach keeps a managed `~/.reach/plugin` install current by itself, from GitHub releases and tags together
(since 0.16.14 the newest version from either, so a tag newer than the last release is offered), checked at session start and hourly from detached processes, staged in the background and installed at the
next session start by the release's own `update/apply.rb`, with every phase in `~/.reach/state/update.json` so an
interrupted update resumes (`reach update status|check|run`). Verified 2026-09-30 against a GitHub-shaped local HTTPS
mirror (real releases API and real Dovetail archive): the login install, the mid-session stage and notices, a kill
mid-download, a crash after the swap and both crashes between the renames all completed, and a real Claude Code
plugin cache moved from 0.12.9 to 0.13.0 through the refresh. Students on 0.12.0 or earlier have no updater and need
one manual reinstall; only tagged versions are offered.

Since 0.50.10 a copy that lives only in a harness plugin cache (no managed install, so no session-start
install) schedules a due check from the prompt hook and tells the agent once per chat (`M-UPDATE-RUN`) to start
the refresh with `reach_update` or `reach update run --apply`. Verified 2026-10-11 through the actual Claude Code
prompt hook in an isolated course workspace: detected and downloaded notices, session deduplication, scheduled
check without application, updater disablement, and applying-state suppression. Refresh subprocesses were
replaced; no real cache refresh or student outcome was observed.
Since 0.51.10 a copy of rEach that cannot update itself says so instead of claiming that an update is running in the
background (iss_7c1c10db).
Since 0.51.10 a rEach that is locked before enrollment completes still checks for updates at session start, so a fixed
version reaches a student whose enrollment keeps failing (`STD-AUTO-UPDATE`).
Since 0.51.10 asking rEach to update when it is already current says that nothing changed and that the student keeps
working in the same chat (`M-UPDATE-NOTHING`).

Build ✅ · Deploy 🟣 (native fixture smoke; stable artifact published) · Blocker: Human (student refresh, Codex refresh, and Windows remain unverified). Native test deployment of v0.50.10 at 0f363bc8867e2dea2b76b6b8be7dac516ac6c7f5 has health ok and verified receipt dpl_5620455813cd40d27a13. The operator also deployed that release to stable with health ok and verified receipt dpl_6c27331c726476c79381; no student refresh outcome is claimed.

Since 0.52.15 (`STD-APP-COPY-UPDATE`) a copy in the Codex app or Claude desktop app plugin cache finds the harness CLI in the standard install folders when PATH lacks it (the apps start with a minimal PATH on macOS, which is why no macOS install had refreshed), and a copy that neither the managed updater nor a found CLI can update tells the assistant once per chat how the student updates (`M-UPDATE-APP-NOTICE`: the app's Plugins page, or a reinstall with the installer, which makes the self-updating managed copy). A refresh skipped for want of a CLI is logged as `cache_skipped` with the folders tried.

Since 0.52.15 a Windows state file write retries a rename that fails with `EACCES`, `EPERM` or `EBUSY` for up to one second with jitter before it gives up and removes its temp file, because a second process briefly holding the file produced five non-blocking `Errno::EACCES` faults on 0.52.12. Verified with a scratch script that made the first renames fail: three failures wrote on the fourth attempt, a permanent failure raised after seven attempts in 0.93 s with no temp file left, and a non-Windows host raised at once. Not seen on a real Windows machine.

Since 0.52.15 the local stub run of a qualification takes a slice's starting copies from the workspace package the slice was provisioned from (the version its marker records), not the newest one, so a past-due slice of an earlier assignment qualified after the next assignment arrived no longer loses its owned files (`reach.spec.yml` qualify steps). Verified in a scratch home with stubbed package reads: before, a marker at package 100 with a newer package 200 holding only other roots gave a stub run with the owned file absent; after, it holds package 100's starting copy, a current-assignment slice is unchanged, and a marker with no stored package falls back to the newest. Not verified: a real Cucumber stub run (so whether the dropped files end in QF-VACUOUS was read from the code, not seen), a real late qualification against Teach, and the course server's stored packages, which were not checked.

Since 0.52.16 (`STD-STATE-FILE-HELD`) a state file another program keeps held is no longer a fault. After the one second of Windows retries `StateFile` raises `Held`; `install.yml` is rewritten only when something besides `last_checked_at` changed or the stored time is an hour old, and on Windows a timed-out `install.yml.lock` wait raises `Held` instead of writing without the lock (Teach bug iss_5fc4). `Held` is never sent to Teach (the setup log records it with a count), the subscribe tick treats it as busy and registers no failure, every `reach_*` tool answers it with a calm try-again result (`M-STATE-HELD`), and `Reach::OldCopy` tells the assistant once per chat (`M-OLD-COPY-NOTICE`) that an older rEach is still running: on an ordinary prompt only when the running copy is older than the managed or a Codex or Claude cache copy found, and when a file is held when any of those copies has a different version, because an older rEach, which cannot be changed, may be the program holding the file. Verified in scratch homes on Linux with `File.rename` and `Paths.windows_host?` stubbed in the scratch script only: `reach_sync` answered busy with no error, no fault was built, the subscribe result was busy with failures still 0, two syncs a minute apart wrote `install.yml` once, and on a prompt the notice came once per chat when a cache copy was newer than the running one and not with an older cache copy or equal versions, and with a file held it came once with an older cache copy. Not seen on a real Windows machine or with a real 0.51.0 copy running.

Since 0.56.16 (`STD-AUTO-UPDATE`) the background subscribe tick requests a scheduled update using the existing lock, cooldown, offline, disable, and retry controls. The MCP bridge also requests the session update when it starts. Managed installs can apply; cache copies follow their existing harness refresh capability. Verification: the real background updater moved a scratch managed 0.51.0 install to stable 0.54.3. Session startup from an isolated non-managed Codex cache copy completed a scheduled check without a harness CLI or a managed-update announcement. Harness CLI refresh and unaided upgrades of older app-only copies remain unverified. Deploy: built, not released.

Since 0.64.17 (`STD-RUNTIME-ROOT-REPLACED`) a rEach process whose plugin cache version folder an update replaced, such as the MCP bridge of an open Codex chat, reads its files from the newest version folder beside it, or the managed install, instead of the removed folder, so `reach sync` keeps setting up the course folders. Before, the course folders stayed unprovisioned after an update until a new process started. Verified in a scratch home with the process's own folder pointed at a missing version: the newer sibling and then the managed install were chosen and the policy loaded, and with neither the policy refused as before. Not verified on a real Windows Codex chat across a real update. Build ✅ (0.64.17) · Deploy 🔵 (0.64.17 pending).

Build ✅ (branch update-app-copies, 0.52.15, not pushed) · Deploy 🔵 (not released; takes effect on a copy only once it reaches 0.52.15, so the installs stuck on 0.51.0 need the announcement or a reinstall) · Blocker: Human (the instructor approves the ship; stable promotion). Verified on Linux in scratch homes with PATH=/usr/bin:/bin: a fake codex in `~/.local/bin` was found and refreshed a codex cache copy; with no CLI the notice came once per chat and `cache_skipped` was logged; an uncached copy got the notice. Not verified: the app-bundle CLI paths of the Codex app and Claude desktop (none searched, none documented), and any real macOS app.

Since 0.64.24 (`STD-AUTO-UPDATE`) `reach update status`, the `reach_update` tool and `reach update check` never present a check that gave no answer as one. A check answered only when no check failed since it, it finished and it recorded a channel ceiling (`Reach::Update.answered_check?`); otherwise the headline is `M-UPDATE-UNKNOWN`, or `M-UPDATE-UNCHECKED` when no check has run, and the remote versions line reads `unknown` instead of `none newer`. Before, all of those printed `M-UPDATE-CURRENT`, so an install whose checks kept failing was reported up to date. Verified in scratch homes on Linux: a real update check aimed at an address that cannot resolve (a DNS failure) recorded one failure and the status then read `M-UPDATE-UNKNOWN` with remote versions `unknown`, through both the CLI and the `reach_update` tool's status path; `reach update check` printed `remote versions: unknown` right after that failure; seven hand-written manifests read as designed (healthy, failed after a success, never checked, finished without a ceiling, a newer version ready, a newer version ready after a failed check, and a manifest written before the ceiling was recorded). Not verified: a real successful check against GitHub, a real student machine, and Windows. Known side effects: a manifest written before the ceiling was recorded reads `M-UPDATE-UNKNOWN` until its next check (up to an hour after an upgrade), and `last_error` is still not cleared by a later success.

Build ✅ (0.64.24) · Deploy ⏳ (not yet on stable) · Blocker: Human (stable promotion).

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
Since 0.37.1 (`STD-BRAND-IDENTITY`), the public docs use the adult cosmic hands banner and the shared three-sparkle
mark. The self-contained SVGs are rendered and inspected in a browser; the logo matches the canonical rStack asset.
Since 0.38.5 the rEach logo is the wordmark in `assets/logo/` (blue for light backgrounds, white for dark), with five
human-and-robot hands pictures, and `README.md` opens with the white bottom-center one. `assets/` is export-ignored,
so the archives students install and update from leave the artwork out.
The linked shared setup handout lives in the instructor corpus, outside this public plugin repository.

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
the ID lengths and username shapes live Teach accepts. Since 0.16.21 the last step
is a password the student chooses twice (at least 8 characters) and is told to write down; the hook hides it from
the agent, Hermes students finish in a terminal, and Teach keeps only its scrypt hash. Since 0.18.2 `reach setup`
and `update/apply.rb` write `teach.url` to `~/.reach/state/teach.json`, read after `REACH_TEACH_URL` and `config.yml`,
so an install whose `config.yml` is missing or broken still enrolls against Teach; verified in a scratch `REACH_HOME`. Since 0.21.11 `Reach::Runtime::TEACH_URL` builds the same URL in as the last resort, and a terminal enroll that cannot reach Teach names the URL and the network cause instead of saying the work is saved. Since 0.21.13 enrollment requests leave the Teach connection state alone, so that message is the only line; verified against live Teach from a scratch home (one line on failure, no `link.json` written, no reconnect line after a successful preview). Since 0.35.2 (`STD-ENROLL-NO-RELAY`) `reach enroll <code>` and the `reach_enroll` tool enroll nothing: the pre-v2 request they sent (`Reach::Enroll.generate_and_register`) was refused by Teach as `invalid_request` every time, which students saw as "That course passkey wasn't accepted" (live Teach, 2026-10-05). The tool takes no arguments and answers `M-GATE-NOENROLL`, `M-ENROLL-NO-HOOK` (Codex not running a sign-in prompt hook) or, once enrolled, `M-ENROLL-ALREADY` with the `reach_next` step; a bare passkey on the command line answers `M-ENROLL-POSITIONAL`. Verified 2026-10-05 in a scratch home against a dead Teach port: the real MCP server over stdio (schema has no properties; Claude unenrolled, Codex with hooks silent, Codex after `gate enroll`), an enrolled install with the lock stubbed open, and the CLI with a bare passkey (exit 1, no request), no arguments (usage) and the flag form (still reaches preview).
Since 0.51.10 the rEach commands asked of the student in a terminal on Windows (to sign in, to choose or reset the password, or to open a course folder in Hermes) are written so that they run when pasted into PowerShell (`Runtime.terminal_command`), while the lines the assistant runs itself keep the plain form in Claude Code, whose shell on Windows is Git Bash (`Runtime.agent_command`).

Build ✅ · Deploy 🔵 · Blocker: -

### 2.2 · Sync

`reach sync` fetches new packages, verifies them, refreshes workspaces and fetches grade receipts. A workspace's
`README.md` is student-owned and preserved.

Since 0.53.23 (`STD-LATE-ASSIGNMENTS`, wire revision 2026-10-18c, W-PACE-3) sync also gets the work areas of an
assignment whose due time has passed while the student still owes it: it fetches that assignment's workspace and shape
packages next to the current assignment's, provisions the work areas under the assignment's own folder, and merges its
shape files into the one shape vault. The current assignment's packages are chosen by the assignment each stored package
names, not by the highest version. `reach status` names the assignment on a line of its own (Also open as late work),
the greeting's course line does the same, and the work is late work as before. A course server that sends no list, an
offline sync, and a student with nothing past due see no change. Verified against `tools/fake_teach` with a late
assignment beside the current one: both work areas provisioned with their own package versions, both shape files in
the vault, a second sync answered 304 for every package, the current assignment still provisioned when the late package
is the newer one, an envelope naming another assignment refused and not stored, an offline sync keeping every work
area, and the output without a late assignment identical to 0.53.20's. Not verified: a real course server round trip,
the greeting hook end to end (only its course line), and `rplugin check`.
Student-first audit for 0.53.23:
1. Learning: yes — the student gets the same starting files as classmates for the assignment they still owe, and nothing is done for them.
2. Agency and honesty: yes — status and the greeting name the assignment as past due and open as late work; doing it stays the student's choice.
3. Wellbeing and safety: yes — the wording states lateness as a fact with no warning or countdown.
4. Privacy and dignity: yes — nothing new is sent; the request names an assignment the student already owns.
5. Fairness and access: yes — the same on every operating system and harness; no branch on either.
6. Friction: yes — no new step; the next sync provisions the work areas and nothing asks the student to pick.
7. Failure: yes — a failed fetch or provision adds a warning and leaves the current assignment untouched; an offline sync keeps what is stored.
8. Recovery: yes — a deleted work area returns on the next sync, and no work area is ever removed.

Build ✅ · Deploy 🔵 · Blocker: Human (needs a course server that sends late assignments)

### 2.3 · Workspace gate

`reach gate` runs from harness hooks: owned files are writable, anything else is refused, and coursework before
enrollment is blocked.

Since 0.50.1 the Claude Code hooks rEach writes on Windows run under PowerShell (`& ...; exit $LASTEXITCODE`), the
`hello` repair pass rewrites existing Windows workspaces, and a blocked enroll or prompt on Claude Code answers with a
JSON block instead of stderr. The fix was confirmed on a student's Windows computer against 0.48.1 and ships on test;
the plugin's own `sh exe/reach-run` hooks are unchanged on Windows.

Since 0.50.3 Claude Cowork gets the same JSON block for a prompt blocked outside the Code tab hold.
Since 0.51.10 every course hook rEach writes for Codex on Windows runs as
`& "<ruby>" "<reach>" ...; exit $LASTEXITCODE` in PowerShell (`Harness.hook_line`, `STD-CODEX-WINDOWS-HOOKS`), where it
had been a PowerShell parse error that left Windows Codex students with no gates, and a platform smoke step proves the
form through powershell.exe and pwsh.exe.
Since 0.64.5 the Codex shell gate judges a command as PowerShell on a Windows host, and on any host when every segment
starts with a modeled Verb-Noun cmdlet, so a Windows Codex student's `Get-Content`, `Get-ChildItem` and `Select-String`
reads are no longer refused as `M-SHELL-UNMODELED`, and `Select-Object -First N` or `-Last N` passes as `head` or `tail`
(`Gate.cmdlet_command?`, `STD-CODEX-WINDOWS-HOOKS`). Run on Linux against the gate only; the Windows host rule has not run
on a student's Windows computer, and what Codex sends in the payload there is unconfirmed.
Since 0.51.10 a course whose rules are in place but whose named slice is not on this computer gets a message that says
so and lists the slices (`M-GATE-NOSLICE`, `M-GATE-NOSLICE-NAMED`) instead of "Your course rules haven't arrived yet".

Build ✅ · Deploy 🔵 · Blocker: Human (0.50.3 on test, stable is the operator's; plugin hooks still need `sh` on Windows; 0.64.5 reached stable at e279583 with 0.64.6).

### 2.4 · Check

`reach check` runs the one checker over the owned files: Ruby syntax, the Ruby 2.6 floor, shape, comments, test code,
purity, granted ports and Dovetail panel rules, each finding with a rule id, file, line and fix. The rules are
CK-RUBY-SYNTAX, CK-RUBY-FLOOR, CK-RUBY-SHAPE, CK-COMMENT, CK-TEST, CK-PURE, CK-PORTS, CK-FUSE, CK-PANEL (with Dovetail's
S-* ids) and CK-SHAPE; `--format text|agent|json|hermes` and `--changed <path>` serve the post-write hooks.

Since 0.52.16 (`STD-CODEX-PATCH-CHECK`) the post-write hook understands a Codex `apply_patch`. Its patch is in `tool_input.command`, not in a file path, so `reach check --format agent` had no target and, from a root session with two or more slices, ended with `M-PICK-SLICE` ("Which slice?") after every patch (Teach bug iss_a045, since 0.51.11). It now reads the targets from the patch, rebased on the tool's working folder or the event's folder, and checks each slice the patch touched, once; a patch that touches only root files exits quietly, and the hook never asks which slice. Verified in a scratch home on Linux with synthetic Codex and Claude payloads and two slices: a patch inside one slice checked that slice only, a patch spanning two checked both, a root-only patch exited 0 with no output, a Claude Write checked its slice as before, and the unchanged 0.52.15 code printed "Which slice?" and exited 2 for the first payload. Not seen in a real Codex session.

Build ✅ · Deploy ✅ (on main and stable since 0.52.16) · Blocker: none.

### 2.5 · Checkpoint

`reach checkpoint save|list|show|restore` snapshots the owned files under the Reach home's checkpoints folder, with
no git in the workspace.

Since 0.53.26 (`STD-CHECKPOINT-AUTOSAVE`) student work is never more than one edit from a saved copy. rEach saves a
hidden automatic entry after every harness write of an owned file, before every write the slice gate allows, after
every `reach check`, before a sync touches an existing workspace and after a restore; entries are content-addressed so
an unchanged file costs nothing, and the hook command lines in course folders did not change. Every entry is mirrored
to the computer account's application data folder outside reach-work, and reads fall back to it; since 0.53.29 both stores are filed under a key derived from the enrolled student id (a salted hash since 0.53.30), with folders mode 0700, so a later student on the same computer account never sees, counts or recovers an earlier student's saves; a store an earlier release left under the unkeyed path or local is adopted only when the student's own store or the workspace ledger proves it is theirs. Since 0.53.34 `reach checkpoint dismiss --slice S` stops the missing-folder report for a folder the student removed on purpose, and `reach checkpoint forget [--slice S]` deletes the saved copies after the student's yes (terminal or consent) with a receipt; retention is still manual. At session start, in
`reach status` and in `reach doctor`, rEach says when an owned file is missing or empty while a save holds it, or when
a work folder is gone while its saves remain, and `reach checkpoint recover` (the `reach_checkpoint` tool's `recover`
action) puts the folder back and restores the newest save that still holds the missing files; since 0.53.27 an
automatic save that records the loss never silences the notice, only a named save or a restore does. `reach checkpoint list` shows named saves and says how many
automatic ones `--all` shows; `restore <n>` takes any number and saves the current state first as a visible entry. A
reach-work folder inside a cloud-synced folder gets one reminder to keep its files on the device, and
`reach-work/README.md` says what the hidden folder holds. Verified in a scratch state: an
autosave per write and per allowed write, dedupe by digest, hidden-by-default list, restore from a pre-0.53.26
`files/` entry, list and recover from the mirror after the primary store was removed, recovery of a removed work
folder once a package could provision it, the notice shown once and the cloud-folder reminder, `REACH_AUTOSAVE=0`,
the README written once, and the gate still refusing a write outside the slice.

Student first (the eight questions): learning yes (nothing writes code; history removes the fear of trying); agency
yes (automatic saves are named as such and hidden unless asked, a restore still asks first, the README explains the
hidden folder); wellbeing yes (a missing file is one calm sentence with the one command that brings it back); privacy
yes (every copy stays on the computer and PRIVACY.md lists them); fairness yes (Claude Code, Codex and Hermes save on
every write, Antigravity on every check; each platform has a data folder rule the fingerprint sidecar already uses);
friction yes (no new step; one new verb, only for recovery); failure yes (an autosave or mirror failure never blocks a
write, a hook or a check, and doctor says so); recovery yes (`recover` re-provisions and restores; any entry restores
and the current state is saved first).

Planned next, not built: a dated archive ZIP per course per day that had changes, written to Downloads and never
deleted by rEach, with a course-end archive; and de-identified work snapshots on the course server with the
transcript flush, so a lost laptop loses no unsubmitted work.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.6 · Plan

`reach plan save|note|show` keeps the slice plan at `<workspace>/.reach/plan.yml`, read back at every session start.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.6b · Plan audit

Since 0.54.0 (STD-PLAN-AUDIT) every qualification follows a plan that passed a second-pass audit. After each `reach plan save` the agent runs the `reach-plan-audit` skill in a fresh subagent or a separate pass, which reads only `reach plan audit packet` (the plan and the released constraints: behaviour, operation, contract, required instructor APIs, the slice's constraints, graded names, owned files) and records pass or fail with `reach plan audit record`, bound to the plan and constraints digests in `.reach/plan-audit.json`. `reach qualify`'s first step, `plan_audit`, follows the course profile's `qualify.plan_audit`: enforce refuses without a current passing record (QF-PLAN-NONE, QF-PLAN-UNAUDITED, QF-PLAN-AUDIT-FAIL), uncounted on the attempt ladder; advise records a notice; off skips it; no key means advise. `reach check` adds CK-INSTRUCTOR-API (owned Ruby never calls a required instructor API), and each qualification sends the plan, its digest and the audit to Teach (wire 2026-10-19a, W-QUAL-PLAN-1). The reach-feature skill forbids faking a required API with a fixed answer (the QUALIFY directive is generated from specs/polispec/behavior.yml and is unchanged). Verified in a scratch home on a copy of a real advisor.a1 workspace, with the enrollment lock, sign-in and the other qualify steps stubbed: CK-INSTRUCTOR-API flags the copied file and passes a version calling `ports.formula.score`; enforce stops with each finding and leaves the ladder at 0; a pass record proceeds; a behaviour edit makes it stale and a progress note does not; advise, off and no key behave as specified. Not verified: a real qualification POST to Teach with the new manifest keys, Ruby 2.6.10 (none on this host), and a real student harness running the skill as a subagent.

Since 0.62.1 a required instructor API whose method name ends in `?` or `!` (`ports.evidence.known?(ref)` on opportunities.a2s2) counts as called: `Reach::Check.instructor_api_findings` and `Reach::Passes.api_called?` ended their call pattern in `\b`, which cannot match after `?` when `(` or a space follows, so CK-INSTRUCTOR-API reported the API as never called, `Qualify.step_check` failed the check step with QF-CHECK on every attempt, and the weighted passes saw it as unused. The pattern now ends in `(?![A-Za-z0-9_])`. Checked on 2026-10-22 by running both methods from the worktree on scratch workspaces: a call to `known?` and to `can?(user, action)` gave no finding where 0.62.0 gave CK-INSTRUCTOR-API, a plain `fetch` call is unchanged, and a workspace that never calls the API, or only `known` and `known_refs`, still gives the finding. Not verified: a full qualification of opportunities.a2s2 against a Teach, and a student's install. Build ✅ Built (0.62.1) · Deploy 🔵 Built, not on stable · Blocker Human: operator promotion of rEach 0.62.1.

Since 0.54.1 (wire 2026-10-19b) the third consecutive enforced refusal raises one agent hand with trigger `plan_audit` (the plan, the audit and the refusal count in its details), next M-QUALIFY-PLAN-HAND; a passing audit resets the count, and a Teach that does not advertise the trigger gets `student_request`. Verified in a scratch workspace with the hand send stubbed: refusals 1 and 2 raise nothing, 3 raises one hand, 4 raises none, a pass clears the count. Not verified: a real hand reaching Teach.

Build ✅ · Deploy 🔵 · Blocker: needs Teach 0.98.0 live (wire 2026-10-19b) and a course profile carrying qualify.plan_audit; without it rEach runs in advise mode

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
course, assignment and course-time stamp, and says until when the student may submit again; since 0.64.11 (wire revision 2026-10-25b, W-SUB-1) a slice may
also be submitted after the due time, and each is marked late (before it, a submitted slice was refused before asking);
since 0.64.12 (wire revision 2026-10-25c, W-SUB-1) at most 50 submissions of a slice that were not rejected are accepted,
before or after the due time, and the 51st is refused with a 409 conflict. The assignment-one smoke asked, captured the yes, submitted and checked the
ZIP against a scratch Teach 0.18.0; resubmission and the past-due refusal were exercised against the fake Teach.
Since 0.53.21 `reach submit archive` also saves the ZIP of an assignment that was not submitted, saying it is not a
submission and must be uploaded to the learning system or sent to the instructor, and `reach qualify` recommends it when
the qualification could not be done (browser missing, scenarios could not start, the local panel preview could not open,
or the course server could not run them). It works at any point, even while rEach is locked; a timed test still refuses it. Checked on
2026-10-17 in scratch state with real slice workspaces: an unsubmitted A2 saved its ZIP with the export text, an unknown
assignment and an unnamed one were refused, and the recommendation fired on a reported preview failure (Ferrum::StatusError); on an install that was not enrolled the CLI and
the reach_submit tool saved the ZIP while every other command and tool stayed locked.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.7c · Partial submission and whole-folder export

Since 0.53.22 (wire 2026-10-18a, `STD-SUBMIT-PARTIAL`) `reach submit --partial` hands in unfinished work that has not
passed its checks, on the student's yes, with only the safety checks; Teach (0.97.11 or newer) keeps it for the
instructor, never grades it on its own, and a partial never stops a later submission. `reach submit archive --all`,
`--course C` and `--extracurricular` save more of the student's own work as one ZIP, never rEach's home. Checked on
2026-10-18 in scratch state: the scoped ZIPs held only the student's files across two courses and extracurricular, a
missing course and two selectors were refused, the size cap skipped, and an unenrolled install still saved; in-process,
a partial reached the course server with partial true in body and manifest, a plain submit stayed refused, an older
course server's answer refused the partial, and the closed rule ignored partial receipts. End to end on 2026-10-18 against
a scratch Teach 0.97.11: the course server accepted partial work, the student was asked and said yes, the partial was
received with a receipt marked partial, it was not graded automatically, a plain submit stayed refused, an instructor regrade graded it and rEach stored the grade receipt, and the later
qualified full submission superseded it; `reach submit archive --all` held only the student's files.

Build ✅ · Deploy 🔵 · Blocker: Teach 0.97.11 on the course server

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
QF-LOCAL-FAIL. A panel scenario that fails because the browser cannot be found gives QF-NOBROWSER with the remedy `reach doctor --install-chromium`
and spends no attempt-ladder rung; checked on 2026-10-10 against a scratch run of the context.a1 reference build with and without Chrome, built on
the dev branch and not yet released. Since 0.58.1 (`STD-QUALIFY-PANEL-ID`) a panel scenario that opens the panel by its cutout id
(`When I open the "records.a2s1" panel`) gives QF-PANEL-ID with the module-id correction instead of an unable preview failure and an
export offer, and `reach check` flags the step as CK-PANEL-ID; checked on 2026-10-21 with a student's recorded A2 failure and feature
file, which gave QF-LOCAL-FAIL, unable and the export offer on 0.58.0 and QF-PANEL-ID, two CK-PANEL-ID findings and no export on
0.58.1, and no CK-PANEL-ID once the step named "records". Since 0.60.1 (`STD-QUALIFY-PANEL-EXAMPLE`) a panel scenario that runs an
example by a label the practice README does not list (`I run the "records.a2s1" example "coffee"`) gives QF-PANEL-EXAMPLE, from the local run or from the
course server's run, with the practice labels in the next step, and `reach check` flags it as CK-PANEL-EXAMPLE; checked on 2026-10-22 against the
practice README of records.a2s1 and the failing rows of a student's recorded course-server run, which gave QF-REMOTE-FAIL and an empty next step on
0.60.0 and QF-PANEL-EXAMPLE with both labels on 0.60.1; the local-run branch was read and syntax-checked but not driven, because no panel kit
run was available. Build ✅ Built (0.60.1) · Deploy 🟢 Live on stable since v0.60.1 (published release, 2026-10-22) · Blocker -. Since 0.21.2 the Teach half (upload and polls) runs under its own 20-second deadline after the local steps, so an MCP
qualify whose local steps outlast the 25-second tool budget still reaches Teach; verified on 2026-10-03 in the slice-build
smoke (run 20261002_215550, context.a4s2, on the same change over 0.20.5), where both qualifications reached the scratch
Teach and finished, against none in the run before. Since 0.33.5 (`STD-KIT-CLEAN-ENV`) every launch of the kit Ruby unsets
the computer's own Ruby and Bundler variables (`RUBYLIB`, `RUBYOPT`, `GEM_*`, `BUNDLE_*`): a student's Ruby 3.3.8
exported `RUBYLIB`, so the kit Ruby 4.0.7 died at start and qualify never ran; reported on 2026-10-05. Checked on
Linux with those variables set: `Reach::Suite.install_gems` and `cucumber` on a Grokit kit fail with the student's
error on 0.33.4 and run (exit 0) on 0.33.5; the student's own machine and macOS/Windows not yet run.
Since 0.51.10 a failed graded case says whether, on the course's data, the call raised an error or a value differed
(`M-QUALIFY-KIND-RAISED`, `M-QUALIFY-KIND-DIFFERED`, instructor decision 2026-10-13), and no step text or values are
shown.
Since 0.51.10 on Windows files are compared by file id, because Ruby's `lstat` and `fstat` disagree on `st_dev` and
made rEach treat every file of a part as changed while reading it, so qualification skipped each file as an unsafe
path and still used a try; a qualification that cannot read a file now names it and stops without using a try
(`QF-UNREADABLE`).
Since 0.51.10 `reach qualify` explains the likely cause when a graded case fails while the assistant's scenario of the
same name passes (`M-QUALIFY-HIDDEN`).
Since 0.51.10 a local check that cannot start shows the real error instead of bundler's "failed to load command" line.
Since 0.56.16 (`STD-QUALIFY-LOCAL-UNABLE`, wire 2026-10-21f) a local run whose checking tools cannot start is recorded as skipped for the environment with its cause. Its stub and port probe are also skipped, with no invented local pass. The course server decides the qualification; an ordinary scenario failure still blocks locally. Weighted passes, patterns, timing, and fault capture remain in the sequence. Verification: a real local run with no bundle executable returned environment-unavailable with no code-failure finding; server verdict handling accepted a passing fixture while retaining the skipped local record. A complete remote qualification roundtrip was not exercised in this change. Deploy: built, not released.

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
Since 0.51.10 a failed live qualification on files identical to the last counted failed attempt uses no try and raises
no ladder hand when the course server marks it not counted (`M-QUALIFY-IDENTICAL`, instructor decision 2026-10-13).
Since 0.51.10 a run that fails in the local checks, before it reaches the course server, on owned files and scenarios
identical to the last counted failed attempt of the slice, local or live, uses no try and raises no ladder hand either
(`M-QUALIFY-IDENTICAL-LOCAL`, instructor decision 2026-10-13); a ladder state without stored digests, or a passing run,
counts as before.

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
Since 0.51.10 a transcript sent from the Codex app or Claude desktop on a Mac hides the computer account name instead
of the word "root" (`lib/reach/deidentify.rb`).
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
Since 0.51.10 every generated rules file (slice, course root, and extracurricular) carries a paragraph saying that
rEach's own tools are how the course's work is done, that reading a directive with `reach_directive` is never
inspecting protected materials, and that only rEach's own folder, vault, and package files are protected
(`Reach::Guardrails::TOOLS_RULE`).

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

### 2.17 · One sign-in per computer for 12 hours

Since 0.12.0 the prompt hook asks for the student ID, then "Am I speaking with <name>?", and waits for a yes, blocking each step so the agent never sees the ID or the answer. Wrong IDs lock the session after three tries; a no ends course work for the session; both reach Teach as integrity events. The A1 smoke signs in this way before any write. Re-verified 2026-10-01 against a scratch Teach: every gate refused before sign-in, the ID stayed out of the greeting, another student's ID was refused, offline sign-in worked, three wrong tries locked the install for a minute, and Teach recorded login_failed and identity_denied.

Since 0.28.0 (`STD-SIGNIN-PASSWORD`, wire revision 2026-10-04d) the yes is followed by the password the student chose at enrollment, and the session is signed in only when it is right; the check is the prompt hook's, not an instruction to the agent. `forgot password` starts a reset that works once an instructor allowed one. Verified 2026-10-04 on a scratch Teach: the A1 smoke (40 pass, 2 skip) signs in with a wrong and then the right password; a write stayed refused until the password; with the verifier deleted the server was asked, and with the server stopped the sign-in waited; three wrong passwords locked the session; the reset set a new password and the old one stopped working on the computer, at the server and at a second enrollment; Hermes was sent to `reach login password`; no password appeared in the database dump, the server log or any rEach file. 🔵 until a student signs in this way on a hosted Teach.

Since 0.48.0 (`STD-PASSWORD-RESET-QUEUE`, wire revision 2026-10-09a) no student can reset a password: forgot or reset words answer `M-LOGIN-RESET-BY-INSTRUCTOR` and only the instructor's Reset password button in Teach starts a reset, which rEach picks up from the status document, removes the local verifier and asks for a new password twice before it signs the student in. Built, exercised in a scratch home against a stand-in Teach; not yet deployed.

Since 0.21.5 the plugin's own prompt hook signs the student in too (`STD-SIGNIN-PLUGIN-HOOK`): in Codex in every folder, keyed on Codex's `turn_id` so that when a course folder's hook also runs, only one of them judges the prompt; in Claude Code outside the course folders. Before, the sign-in lived only in each course folder's `.codex/hooks.json`, which Codex never runs until the student trusts it, so a Codex student on Windows (hand 2026-10-03, Reach 0.21.1) was told to wait for a question nothing asked. Verified by the platform smoke on Linux (15 passed): ask, confirm, yes, a second hook on the same turn silent, the signed-in context on the next turn, then the gate open. Not verified: a live Codex session on Windows.
Since 0.51.10 (`STD-SIGNIN-ONCE`, instructor decision 2026-10-13) one sign-in covers every new chat on the computer, in any AI app, for 12 hours (`policy login.max_hours`) instead of one sign-in per chat; it is stored in `state/login/signin.json` and tied to the enrolled student and the install (a test student keeps its own); switching student, re-enrolling, "no, not me", a wrong-password lockout (also a rate-limited password check), and `reach login out` end it (`lib/reach/login.rb`).
Since 0.51.10 `reach login out` signs the student out on this computer, so every chat then asks for the sign-in again; it touches only the active student (the enrolled student, or the test student on an instructor's computer) and is safe to run when already signed out.
Since 0.51.10 on Hermes, signing in from a separate terminal signs the chat in, and after a password reset the chat names `reach login reset` instead of looping on `reach login password` (iss_39127440).

Build ✅ · Deploy 🔵 · Blocker: -

### 2.18 · The student's own part

Since 0.12.0 `reach part` lists the questions only the student can answer, `reach part record` takes their typed words verbatim, and `reach submit` refuses until all are answered and sends `part.json`. Since 2026-10-03 the prompt hook keeps only the latest long enough prompt in `~/.reach/state/part/pending.json`, `reach part record` takes it and deletes it, and the answer carries no session or seq; Teach stores answers as sent and checks nothing against a conversation. In the 0.12.0 smoke, submit was refused without the part and four answers were recorded. Re-verified 2026-10-01: a two-word answer was refused as too short, and in live sessions Haiku and Sonnet coached the own part on process only, without candidate answers.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.19 · Modules, module choice and transfers

Since 0.12.0 Reach verifies Teach's signed module record and refuses writes in another module's slice. In a choose-your-modules course the student locks in two modules with their own yes; `reach transfer request` asks the professor to confirm a move. On scratch data a student chose and locked two modules, a second choice was refused, a transfer was approved, and an instructor reassignment moved the student's slices. Since 0.14.3 Reach acts on the student's yes or no itself from the prompt hook, and a send that had to queue is flushed by a detached process. Re-verified 2026-10-01: the ask sent nothing; the yes alone sent it (Teach had it 3 s later); a second request while one was open was refused; a denial showed the professor's reply; approval moved the modules; a write in the old module was refused; a reassignment without a reason was refused; a choice locked on the yes, a second choice was refused, and a full module was refused. Live on Haiku and Sonnet, rEach ran the request, relayed Reach's question, and Teach received exactly one transfer after the yes.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.20 · Sandbox and drag-and-drop files

Since 0.12.0 the read and shell gates refuse paths outside the workspace and web lookups in course folders, on Claude Code, Codex and Hermes. A dropped file is copied into `materials/` within size and type limits. Driven with hook events on Claude Code; the Codex and Hermes hooks are configured but not run live. Since the fix for iss_83205c76aa1c the gates leave reach's own installed skills readable (the plugin's skills directory and the Codex plugin cache's reach skills), because Codex has no Skill tool and loads reach-feature by reading its SKILL.md; verified in a scratch state: Read, cat, sed -n and nl of the skill pass while /etc, `..`, a symlink out, plugin.json, the vault, and writes onto the skill stay refused. The managed copy's skills (`.reach-home/plugin/skills`) were still refused as inside the reach home, and sed or nl of a skill was refused in the course root; both are fixed after iss_b60398d3b34a and verified in a scratch state with the same refusals kept (state, keys, plugin code, `..`, symlinks out, sed -i, redirects). A Codex plugin-cache copy older than 0.50.7 has no skill exemption at all and is replaced only by the cache refresh and a new chat. Not verified: a live Codex session. Re-verified 2026-10-01: Read, Grep, Glob, shell cat, ls of the home folder, cp and both web tools were refused outside the workspace; a .txt drop was copied, an .exe and an oversized file were refused; live, Sonnet declined to search Documents, and the dropped file was copied into materials/ and read there.
Since 0.51.10 the managed copy's skills are readable and `sed`, `nl`, and `cat` of an installed skill pass inside a slice (iss_b60398d3, iss_7b90ff43).
Since 0.51.10 Claude Code's Glob with a full-path pattern from the course folder is judged by the pattern's own folder, searches that reach rEach's folder stay refused, and a `$W/**` Glob from a slice is now refused.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.21 · Time gate

Since 0.64.10 (wire revision 2026-10-25a, W-PACE-1 to W-PACE-3) a student may work on any released assignment, past or future, and M-GATE-NOT-CURRENT is retired. From 0.12.0 to 0.64.9 writes were refused in a slice that was not the current assignment, by Teach's clock; until 0.19.0 a slice whose due time had passed was refused too, and since then it stays writable as late work (3.7, W-PACE-2). Since 0.53.5 the prompt anchor (M-ANCHOR) also names an overdue earlier assignment the student is finishing, and the instructor's request, as on the step, so the agent no longer steers late work back to the current assignment. That wording outlived 0.64.10: an earlier assignment still inside its `rolling_until` window is open work, not late work, so it matched neither case, and an agent could decline to finish an earlier assignment while a later one was current. Since 0.68.4 the anchor names any released assignment the student chooses, earlier or later and due or not, and says the current assignment is never a limit, as PACE does. Since 0.68.5 the assignment context line and the reach-course skill say the same, so an agent at the course root no longer reads the named assignment as a session lock. Re-verified 2026-10-01 (before 0.64.10): an unreleased A2 was not delivered, and a past-due or non-current slice gave M-GATE-NOT-CURRENT.

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

Since 0.56.16 (`STD-KIT-LOCK-MATCH`) a fallback prebuilt profile requires an identical Gemfile and a matching source lock apart from line endings and the PLATFORMS section. The source lock must match the digest recorded by the kit; the installed Windows lock may add native platform gem entries and checksums. Version requirements, sources, resolved versions, and checksums must match. Windows refuses a fallback bundle install and explains how to repair its prebuilt gems. Verification: hosted Windows x64 loaded Nokogiri, FFI, Cuprite, and Cucumber from the prebuilt profile on a plain PATH. Changed requirements, resolutions, and profile digests were refused locally. Deploy: built, not released.

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
institutional username (the student's school email address) and the student ID. It confirms, then enrolls with wire
shape v2. Teach answers with a signed enrollment stamp binding the install, the student, the course and a salted,
hashed fingerprint of the computer, the account and the install key. Every CLI verb except help, enroll, setup,
doctor, support, update, guide and the hooks, and every MCP tool, refuses while locked. Reach locks again when the stamp
fails, the course ends, or the fingerprint stops matching, locally or on Teach's status check. The crisis check runs
before every step. `reach enroll --course-passkey ... --username ... --student-id ...` does the same from a terminal
(`--course-code` stays as an unlisted alias).
Since 0.51.10 (`STD-FINGERPRINT-OS-USER`) a Mac no longer locks itself as moved when the student enrolled in Terminal
and then opened the Codex app or Claude, or the other way round: an app-launched process reports the account as
`root`, so the live fingerprint also carries the uid's account-name and `root` forms for the same uid
(`Fingerprint.matches?`).

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
Since 0.54.6 (`STD-GATE-REPLACED`, wire 2026-10-20b) a copy switched off by the student's own newer enrollment is told
so: Teach's `403 revoked` carries `details.reason replaced` and the newer enrollment's harness, platform and day, and
rEach shows `M-GATE-REPLACED` (plus `M-GATE-REPLACED-WHERE`) everywhere the lock is shown instead of blaming the
instructor; `M-GATE-REVOKED` stays for an instructor's revoke, an unenrollment and a Teach without details. Verified
2026-10-20 in a scratch home.
Since 0.64.15 (`STD-FINGERPRINT-OS-USER`) a machine id or login name probe that fails is retried and, if it still fails,
does not lock the install as moved for 24 hours, and a security validation refusal names its cause.
Since 0.64.16 that cause reaches the student and the agent, and a validation step refused on this computer says nothing was sent to Teach
instead of warning of a connection problem or impersonation.

Build ✅ (0.64.16) · Deploy 🔵 (0.64.16 pending) · Blocker: Human (the live Teach units still run 0.15.1 and need a restart, a roster and a minted code before a student can enroll with a course code).

### 2.27.1 · A reinstall keeps the computer

Since 0.43.1 (`STD-FINGERPRINT-SALT-KEPT`) the fingerprint salt is also kept in the per-computer sidecar
(`seal.json`, field `fingerprint_salt`), and a fingerprint built with no `~/.reach/fingerprint.json` takes it from
there. A student who deletes the rEach home and enrolls again from the same computer account sends the old salt, so
Teach's same-computer check passes and no device move is recorded. Deleting the sidecar too still counts as a move.
Verified in the scratchpad on Linux: enrolled-style build and store, home moved aside, rebuilt; the salt matched and
the course server's same-computer check answered true, and false once the sidecar was also moved aside. Not verified: Windows or macOS, a real enrollment against Teach, and installs that enrolled before
0.43.1 (their sidecar gets the salt at their next enrollment or persona enroll, not before).

Build ✅ · Deploy ⚫ (not released) · Blocker: Human (release, push)

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

The `kit_gems` platform-smoke step exercises a lock with an extra platform and loads nokogiri, ffi, cuprite, and cucumber using the kit Ruby and a plain PATH. Hosted run 39526045138 passed every selected OS leg, including the native Windows x64 check. Windows ARM64 passed its supported checks and skipped the absent runtime kit.

Build ✅ · Deploy 🟡 · Hosted legs green in CI; the Windows 10 and 11 VM runners are not registered yet (waiting on the Windows ISOs, which Microsoft would not serve to a script).

### 2.29 · Microbrain learning and recall

Since 0.16.15 Reach learns about the student and their work and uses it, all on this computer. Since 2026-10-03 `Reach::Brain.capture_prompt`, called from the prompt hook, turns every gate-allowed prompt the student types, in any folder, into a private `source` spool line (never a blocked prompt, a secret-looking prompt or one holding the student's ID; `capture_min_chars` is 1; AI replies are not ingested), kept only on the computer; the host agent distils durable findings with `reach remember` (or `reach_remember`); a novelty gate (cosine at least 0.85 within the category only reinforces), a per-hour and per-day write budget, a secret and student-ID refusal and a backing-off nudge stop floods. Session start injects the profile (at most 1500 bytes) and each prompt the matching memories (at most 800 bytes) from `Reach::BrainIndex`, a BM25 and cosine read model over the spool, with decay and reinforcement salience. `reach memory list|show|forget|export` and the `reach_recall` and `reach_memory_forget` tools show and erase it; forgetting scrubs Reach's spool. Verified 2026-10-01 in scratch homes on Ruby 3.3.8 and in `ruby:2.6.10-slim`: three turns captured as source lines, a save, a reinforcement, a related save, a refused password, a held write at `per_hour: 2`, the profile in `reach hello`, matching memory and the nudge in `reach gate prompt`, forget by id and `--all --yes` leaving no claim text in the spool, the three MCP tools, a locked install refusing both commands, and brain work in 43 to 54 ms (cold 118 to 130 ms) with 2000 findings and 2000 sources in the spool. Not verified: the in-process `Rcorpus::Context` recall and `Rcorpus::Consolidate` paths, which need rcorpus 0.9.0, and a real harness session on Codex or Hermes.
Since 0.51.10 inside Codex's sandbox, where the memory spool is not writable, `reach remember` from the terminal no longer faults: it changes nothing, exits 1, and says to use the `reach_remember` tool (`M-BRAIN-SANDBOX`, iss_880fa940).

Build ✅ · Deploy 🔵 · Blocker: Engineering. Verified on Ruby 2.6.10 and 3.3 (capture, remember, novelty, budget, recall, forget, spool cap) and end to end with rplugin 1.4.0 and rcorpus 0.9.0 (admission, audit 0, check 0). A student computer has no rplugin, so it runs on the spool and Reach's own recall; shipping rplugin and rcorpus in the runtime kit is deferred (TODO.md).

### 2.30 · Instructor unlock

Since 0.16.17 an instructor can lift the enrollment lock on one install: a `RINS1` code pasted into the locked prompt is intercepted by the enrollment hook (the agent never sees it) and, on an unenrolled install, stored in `~/.reach/instructor.json`, after which prompts are allowed without guardrails, nothing is captured and the agent is told once per session it is in instructor mode. The stored code is re-verified each time, so revoking it or retiring its key relocks the next prompt. `reach instructor status` and `reach instructor lock` show and undo it. Not verified: a real harness session on Claude Code, Codex or Hermes.

Since 0.35.11 a valid code typed at any prompt, in any sign-in, lockout or enrollment-lock state, is never judged as an
answer or counted. On an enrolled install it signs that chat in as the enrolled student and clears the sign-in and
enrollment lockouts (`M-INSTRUCTOR-SIGNED-IN`); a new chat signs in as usual. Since 0.35.13 that code is never stored
on an enrolled install: the chat gets a pass (`instructor_passes.json`, no code) that lets it through every enrollment
lock until the sign-in expiry, and revoking the code or removing its key voids it. `reach instructor unlock` (no
argument; the code is read hidden) does the
same from a terminal for the chat waiting to sign in, so it works when no hook runs. When an instructor allows a
password reset in Teach, a locked-out student's next message lifts the lockout. Only a chat that already passed the
student ID and yes goes straight to the new password. Verified in a scratch home against the fixture Teach with a
scratch pinned key, in every sign-in state, with both prompt hooks firing for one prompt (exactly one answers); not
yet run in a real harness session. The 0.35.13 pass was verified the same way: no stored code, every sign-in state,
the revoked, stamp-invalid, moved and course-ended locks lifted for that chat only, revocation and key removal voiding
the pass, the command-line argument refused, and a non-enrolled install unchanged. 0.35.13 was never released; its
pass ships in 0.35.14, which signs each pass with an HMAC keyed from the install key and ignores a pass that is
unsigned, edited, dated ahead or longer than a sign-in. The seal stops other programs and accidents, not the student
at that computer, who can read the install key. 0.35.14 also removes a code that 0.35.12 stored on an enrolled
install at the next session start, and neither that removal nor `reach instructor lock` keeps the code in its backup. Since 0.35.15 each session start on an install enrolled as a student also strips the code
from backups that `lock` made before 0.35.14 and logs `instructor.backup_scrubbed`. Verified in scratch homes: a coded
backup scrubbed once and kept at 0600, a second run changing nothing, a code-free backup and other files untouched, an unwritable backup logged as failed while the next one was still scrubbed,
and a non-enrolled install's backups left as they were.
Checked in scratch homes before commit: hand-edited passes refused, a stored code removed, `lock` keeping no code, and a
non-enrolled install unchanged; not yet run in a real harness session.

Since 0.36.0, instructor keyring (Teach 0.62.0 serves it): the instructor keys and revoked code ids are no longer pinned in `config.yml` (`enrollment.instructor_keys` and `enrollment.instructor_revoked` are deleted and no longer read). `Reach::InstructorKeyring` fetches `GET /api/v1/instructor/keyring` from the configured Teach URL through the anonymous quick client (If-None-Match with the revision, 304 refreshes the cache), checks the schema and every field, and on an install holding `signing_public_keys` requires the signature to verify with the key named by `signing_key_id`; an unenrolled install accepts a well-formed keyring from the configured Teach URL. A keyring whose `issued_at` is older than the cached one is dropped, a rejected one leaves the cache alone and logs `instructor.keyring_rejected` with the reason, and on an enrolled install a cache file that no longer verifies is ignored. The cache is `instructor_keyring.json` (0600) under the root state folder, fresh for `instructor.keyring_refresh_s` (default 900); it is refreshed at session start (`hello`, quick) and before a typed code is verified when stale, and offline the cache is used. With no cache a code is refused with reason `keyring_unavailable` and `reach instructor unlock` prints `M-INSTRUCTOR-KEYRING-UNAVAILABLE`. A key listed in `retired_key_ids` is never pinned (`key_unpinned`), a revoked code id is refused (`revoked`). `reach instructor keygen` and `code` now print `M-INSTRUCTOR-MINT-IN-TEACH` and exit 1; `reach instructor status` also shows the keyring revision, age and key ids. Verified 2026-10-06 in scratch homes against a WEBrick fake keyring server signed with a scratch RSA key: signed keyring accepted on an enrolled install, tampered, wrongly signed and unknown-signer keyrings rejected with the cache kept, a hand-edited cache ignored, 304 handling, revoked, retired and rollback cases, offline with and without a cache, the CLI messages, and `ruby tools/platform_smoke/run.rb --skip-runtime` giving 12 passed, 1 failed (the known doctor findings), 3 skipped. A typed code with no keyring cached gets `M-INSTRUCTOR-KEYRING-UNAVAILABLE` in the prompt hook too and is not counted toward the lockout (checked in a scratch home). A computer that is not enrolled holds no Teach signing key, so it takes the keyring unsigned, and only over https; its own user can still point rEach at another server, as they could edit `config.yml` before. Not verified: a real harness session.

Also run against a real scratch Teach 0.62.0: its keyring accepted with the scratch signing key and rejected with a wrong one, and a code minted on that Teach verified. Not yet run against the live Teach or in a real harness session.
Build ✅ · Deploy 🟢 Released 2026-10-06 as Latest; the live Teach keyring serves key `5270f8bf0dbf413b` and 0.36.0 fetched it. Key `343572ebf748c69d` is pinned nowhere in rEach 0.36.0.

### 2.30b · Instructor personas

Since 0.16.23 (wire revision 2026-10-02a) an install holding a valid instructor unlock runs as a test student: `reach instructor dummy [--course ID]` starts a blank one and `reach instructor as USERNAME [--course ID]` a test copy of a roster student, both made by Teach 0.17.2's `W-API-ENROLL-INSTRUCTOR`, which never writes the real student's record and files everything the persona sends as instructor data. The persona has its own rEach home (`~/.reach/personas/<id>/`) and folders (`~/reach-work/personas/<id>/`), signs in with the test student ID that the start message and `reach instructor status` name, gates and captures exactly as a student's install, and ends with `reach instructor exit` (moved to `.backup`). A revoked code or removed key locks it. Verified 2026-10-02 against a real scratch Teach 0.17.2 through the assignment-one smoke extended with persona journeys (52 steps passed, 2 manual skips): unlock, a test copy of the smoke student with its workspace and 4 copied receipts, sign-in by test ID, the owned write allowed and an outside write refused, `reach check` clean, the real student's 19 table snapshots identical before and after, exit, a dummy, revocation at Teach, and the real student's install still active; the full student loop passed alongside it. The persona flow also ran in `ruby:2.6.10-slim` against a stub. Not verified: a live Claude Code, Codex or Hermes session.

Build ✅ · Deploy 🔵 · Blocker: Human (Teach 0.17.2 deployed and the instructor key pinned in the live course policy).

### 2.30c · Debug mode

Since 0.16.23 rEach records scrubbed metadata events (W-DBG-KINDS; never prompt or file text, codes, passwords or keys) under `debug/` in the rEach home, always for a persona and otherwise after `reach debug on [--for MINUTES]` or when an instructor switches it on from Teach, which the student is told about. It sends them to Teach (`W-API-DEBUG`), keeps them queued on any failure, and shows each turn's events as a hook `systemMessage`: an ASCII table on terminal surfaces, a Markdown table on desktop and IDE surfaces, with `debug.render` as the override; Hermes has no user-visible hook channel, so `reach debug show` is the way there. Verified 2026-10-02: with debug off every hook output and file listing is identical to 0.16.22's (117-line diff); against the real scratch Teach a persona's 29 events of 8 kinds were stored as classification instructor and both table formats rendered; against a stub, the scrub, local and remote switches, the once-per-session notice and the offline queue. Not verified: a live harness rendering the block.

Since 0.20.1 the person can say "enable debug mode" or "turn debug on" (and "turn debug off") to their AI partner instead of running a command; rEach switches it from the prompt hook, even before enrollment or while locked, and the agent relays the confirmation word for word. The session event then carries operating-system detail (`Reach::OsInfo`: distro or macOS or Windows version and build, kernel, arch, WSL, container, CPU, memory, disk, locale, timezone, shell, terminal, desktop, tool versions; never a hostname, username or path). Verified 2026-10-03 on a scratch home: the phrases switch it on and off, sentences that only mention debug change nothing, the confirmation shows locked and unlocked, and the spooled session event carried 33 OS fields (46 in all). Not verified: the macOS, Windows and WSL probes.

Since 0.53.4 (wire revision 2026-10-16b) every refusal says what was refused. The local `gate-refusals.jsonl` line and the debug `gate` event with outcome block carry `command` (the shell command) or `tool` and `target` (the write or read tool and the path it named), each the first line only, scrubbed like every debug string and cut to 200 characters, so a here-document body, later lines and file contents never leave the computer. Until then both carried only the message id, and an instructor could not tell which command a student had been refused. Verified 2026-10-16 on a scratch home: a refused multi-line shell loop with a here-document recorded only its first line, a refused write recorded the tool and path but not the content, a refused read recorded the tool, the home folder showed as `~`, and a direct `M-SHELL-UNMODELED` refusal recorded the command. Not verified: a real student session. Since 0.53.6 the command in the debug event is masked so that no inline secret reaches Teach through it: only known command names, shell syntax and the shape of the rest stay (`for … in * ; do cat "$…" ; done <<…`, `export … && curl -… … …`), so no word the student typed reaches Teach unless it is a known command name; the local log keeps the scrubbed line. Verified 2026-10-17 on a scratch home and on Ruby 2.6.10: an API key assignment, a Bearer header, URL credentials, `-pPASSWORD` and `--token=` never appeared in the debug spool. Since 0.53.13 a refused path reaches Teach relative to the course folder, or as `~/….pdf`-style placeholders when it lies outside the course; verified 2026-10-17 on a scratch home (`~/Documents/<name>.pdf` became `~/….pdf`, a Windows desktop file `/….xlsx`, a slice file stayed `A1/slice/notes.md`). Since 0.53.14 the slice ledger's shell record, which a submission carries, keeps the command in the same masked form (`…=… ruby … -… …`) beside the digest of the command as run. Records written before 0.53.14 keep the raw command, since rewriting them would break the ledger's signature chain. Since 0.53.15 a refused path is resolved before masking, so a symlink inside the course to a personal file shows as `/….pdf`, and an MCP tool shows as `mcp__…`.

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
Since 0.44.1 (iss_895a0a5f250729ab1914) a working directory that was removed under a running process is not a hiccup:
`Reach::Paths.cwd` answers the user's home instead, so `reach_hello` and the workspace-bound MCP tools answer normally
after an update or reinstall replaced the plugin copy the bridge started in. Verified on Linux in a scratch home:
`Reach::Hello.run` from a removed directory raised `Errno::ENOENT` on 0.44.0 and answered its session context on 0.44.1.
Not verified on the macOS Codex installs that reported it.

Build ✅ · Deploy 🔵 · Blocker: Human (no live harness session yet).

### 2.30e · Health checks for the agent (known issues until 0.63.2)

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
Since 0.64.18 a student who is enrolled but not signed in also gets the silent case when neither prompt hook ran in
the last 15 minutes, even though one ran after the last recorded session start. That stamp comes from the plugin's
own SessionStart hook, so when Codex loads none of the plugin's hooks it froze with them and kept the detector off.
Verified 2026-10-26 on Linux with Codex CLI 0.164.0 against the fixture Teach in a platform-smoke scratch home: with a
root `plugin.json` in Codex's cached copy, app-server `hooks/list` showed only the six course-folder hooks, a typed
prompt reached the model and `reach status` said `Sign in: type your student ID.`; after `Reach::CodexCache.repair`
the three plugin hooks loaded trusted and a headless `codex exec` sign-in went from the ID to the password to signed
in. In the silent state the real MCP server answered `reach_hello` with `M-LOGIN-NEEDED-NO-HOOK` and the
`signin_hook_not_running` health line, and `reach_next` with `M-NEXT-LOGIN-NO-HOOK`; 0.64.16 answered `M-LOGIN-NEEDED`
and `M-NEXT-LOGIN` there. A prompt hook that ran a minute earlier, a hook older than the session start, 14 quiet
minutes and a signed-in student all kept their old verdicts. Not run on Windows or in the Codex desktop app.
Build ✅ (0.64.18) · Deploy ✅ (0.64.18 on stable).
Since 0.64.19 the silent sign-in state no longer opens with the `G-LOGIN` greeting on the MCP path: `reach_hello` returns
no greeting, so the agent cannot greet the student with "please type your student ID" while the context says no hook
can take it. The hook-driven session start keeps `G-LOGIN`. A signed-in student whose plugin hooks are silent while the
course folder's hooks keep running is also reported now: the course folder's tool hooks and the plugin's prompt hook
each record the Codex `turn_id` they ran under (`prompt_turn` and `work_turn` in `hooks_seen.json`), and
`HookLiveness.prompt_turns_unseen?` is true when a tool hook ran in the last 15 minutes under a turn no prompt hook
stamped, after the last stamped prompt. The `hooks_not_running` detector (`reach doctor` and the health line) reads it;
`HookLiveness.prompt_hook_dead?`, and with it the `M-HOOKS-REQUIRED` refusal, does not. Verified 2026-10-26 on Linux in
the platform-smoke scratch home with state files written for six situations (same turn, new turn with fresh tools, a
50-minute turn on one id, a new turn with tools quiet, no prompt turn ever, old stamps with no turn ids) and the real
MCP server: `reach_hello` answered with a null greeting and `M-LOGIN-NEEDED-NO-HOOK` where 0.64.18 answered `G-LOGIN`.
Not run against a live Codex that sends a subagent's tool hooks under a turn id of its own, which would raise the
health line wrongly; the refusal is left off for that reason.
Build ✅ (0.64.19) · Deploy 🔵 (0.64.19 pending).
Since 0.35.16 (`STD-CODEX-PROMPT-JSON-BLOCK`) `gate enroll` and `gate prompt` with `--harness codex` block by printing
`{"decision":"block","reason":...}` on standard output and exiting 0, not by exiting 2. Codex on Windows runs hooks
in the session's PowerShell (`-Command`), which turns a native exit 2 into 1, and Codex treats exit 1 as a hook
failure that does not block: the student's passkey, student ID, yes or password went on to the model and rEach's
question never showed. Codex's `UserPromptSubmit` handler blocks on that JSON exactly as on exit 2 with standard
error (codex-rs `hooks/src/events/user_prompt_submit.rs`, main 402f5b6). Every other harness and gate keeps exit 2.
Verified 2026-10-05 on Linux in a scratch home with the real hook commands: `gate enroll --harness codex` and
`gate prompt --harness codex` exited 0 with only the JSON block on standard output, and `gate enroll --harness
claude-code` still exited 2 with the question on standard error; the platform smoke (`--skip-runtime`) passed
`hook_codex` and `hook_prompt_open`, a full Codex sign-in through the plugin hook (ask, confirm, yes, wrong
password, password, signed-in context) with every block read from the JSON. Not run under PowerShell or inside a real Codex;
the tool gates (`gate write`, `shell`, `read`) still blocked with exit 2 until 0.35.17. Since 0.35.17 they block with
exit 0 and `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
"permissionDecisionReason":...}}`, which Codex's PreToolUse handler treats like exit 2 with standard error (codex-rs
`hooks/src/events/pre_tool_use.rs`, main 28a264f); before, under PowerShell a blocked Codex tool call could run.
Verified 2026-10-05 in a scratch home with the real `gate write`, `gate shell` and `gate read --harness codex`
commands on an install that is not enrolled: each exited 0 with only the deny JSON on standard output, and
`gate shell --harness claude-code` still exited 2 with the message on standard error. Not run under PowerShell or
inside a real Codex.
Since 0.64.0 (`STD-HEALTH`, wire revision 2026-10-23a) known issues are gone: rEach fetches nothing from
`/api/v1/known-issues`, and `reach_known_issues` and `reach known-issues` are removed. The four detectors are local
health checks (`Reach::Health`) with the same conditions, named in the session context with the student's steps and,
for the sandbox and untrusted hooks, the `reach_setup` configure call; `reach doctor` reports the hook checks as
`R-DOC-HEALTH`. The hook and harness code moved unchanged to `Reach::HookLiveness`. A hand whose Teach issue carries
a workaround shows it in `reach_hand_status`. Verified 2026-10-23 on Linux in a scratch home with a Codex session
start and no prompt hook: the 0.63.2 detectors and the new checks fire the same three checks; `reach doctor` printed
three `R-DOC-HEALTH` lines; `reach_hello` over the real MCP server carried the three lines; the hook guard refused
with the unchanged `M-HOOKS-UNTRUSTED`; `reach_known_issues` and `reach known-issues` fell through to the lock; and
`Reach::Hands.status` with a stubbed answer returned the trimmed workaround. Not run inside a real Codex, on macOS or
on Windows, and no Teach sends `student_workaround` yet (Teach phase A).

Build ✅ · Deploy 🔵 · Blocker: Temporal (Teach must send `student_workaround`; students update to 0.64.0 on their own).

Since 0.64.21 `reach_hand_status` and `reach hand status` refuse a hand id that is not one plain path segment (empty,
or with a slash, `?`, `#` or a space) before any request, with `M-HAND-ID-UNKNOWN`: nothing was asked of the course
server, a request for help still waiting to be sent has no id yet, and the open hands are listed. Such an id reached a
path the course server has no route for, its bare not-found answer carried no error code, and rEach reported that as
its own fault while the student read that rEach had let their instructor know. Verified 2026-10-27 on Linux in a
scratch home through the real MCP dispatch and client, answered in process by the course server's code on a scratch
database: before, an empty id and `a/b` each sent a request and recorded a fault; after, neither sends anything or
records a fault, `abc?x=1` no longer reaches another hand's path, a well-formed id is sent as before, and the CLI
prints the same refusal with exit 1. Not run in a real Claude Code or Codex session.
Build ✅ (0.64.21) · Deploy 🔵 (0.64.21 pending).

### 2.31 · Opening a course folder

`reach work [--harness H] [--slice S | --extracurricular]` opens a slice, or the student's own folder, in the chosen
harness through the gate with rEach speaking first; `reach start [--harness H]` opens a harness in the current folder
with no course gate. With one harness found it uses it, with several it asks. Hermes is launched as
`hermes -p reach --accept-hooks chat -q "Hi rEach"` (10.5), and since 0.11.4 setup prints the absolute
`~/.reach/bin/reach work --harness hermes` command because `reach` may not be on the PATH. Verified: Hermes (2026-09-29
and 2026-09-30) and the real-Claude smoke's workspace sessions. Unverified: `reach work` for Codex and Antigravity, and
`reach start` (built in 0.2.0, no separate run recorded).
Since 0.51.10 in the Codex app `reach work` keeps the work in the current chat (`M-WORK-HERE`, `M-WORK-CODEX-PROJECT`)
instead of asking the student to open the slice's folder as a new chat.
Since 0.51.10 `reach work` inside a Codex chat whose sandbox keeps the folder's Codex settings read-only skips the
rewrite and no longer reports a problem.

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

Since 0.41.0 (`STD-README-SUBSTANCE`) a README.md whose five template sections do not each hold 25 words is CK-README:
qualify stops at its check step and submit refuses with M-SUBMIT-README, never sending it. Verified on the 2026-10-06
A1 packages: the README of the one-slice qualification that prompted it fails all five sections, a complete one passes.

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
Since 0.51.10 in a slice chat where `reach` is not on the PATH (Codex on a Mac, for example), the shell gate no longer
refuses rEach's own commands as "would change files outside your slice": checking work, `reach qualify --list`,
opening work, saving own-part answers, and reading directives through rEach's runtime Ruby now run
(`Gate.check_vault_or_keys_reads!`, `ruby.exe` recognised; iss_3c176307, iss_8bfc0e0c, iss_9bd140bb, hand_11dd6ea8).
Since 0.51.10 a shell command the gate cannot check, such as a loop, gets a message saying that nothing is broken and
how to keep going in the same chat (`M-SHELL-UNMODELED`, iss_f4c2d035).

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
whether the student is signed in on this computer (2.17). Unverified: neither has a separate run recorded.

Build ✅ · Deploy 🔵 · Blocker: -

### 2.39 · Teach subscription

Since 0.22.0 (wire revision 2026-10-03e, Teach 0.30.0; STD-TEACH-SUBSCRIBE) Reach checks Teach's signed W-API-REVISION probe, about every 60 seconds from its MCP server while a harness session runs and about every 15 minutes from a user-level operating system job (a systemd user timer, a launchd LaunchAgent or a Task Scheduler task), and runs one `reach sync` only when a part changed, so rebuilt packages, assignments, policy, grades, hand replies, extra credit, receipts and known issues arrive without the student asking. `reach subscribe status|tick|install|uninstall` manage it, `reach doctor` prints R-DOC-SUBSCRIBE, and the prompt hook adds one plain line (M-SUBSCRIBE-UPDATES) naming what changed. `REACH_OFFLINE=1`, `REACH_SUBSCRIBE=0` and `subscribe.background: false` switch it off. Unverified: the macOS LaunchAgent and the Windows Task Scheduler job were generated as text only and never run on those systems; the Linux unit files were written to a scratch folder with no `systemctl` call.
Since 0.51.10 on Windows every detached rEach process (update checks, sync, report flushes, the live watch, and the scheduled course check) starts through `Runtime.spawn_background` with `CREATE_NO_WINDOW`, the scheduled check relaunches itself windowless, and free disk space comes from `GetDiskFreeSpaceExW` instead of PowerShell.

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

Since 0.38.7 the report names the rEach version that raised the fault (`environment.reach_version`, null when the
record predates 0.38.7), and every `fault` event carries `reach_version`, because the spool and the pending record
outlive a self-update; verified 2026-10-06 in scratch homes with copies labelled 0.38.6, 0.38.7 and 0.38.8 and fed into
Teach 0.65.1 on a scratch database (see `CHANGELOG.md`).

Build ✅ · Deploy 🟢 Live (released 2026-10-03 as v0.23.0, GitHub Latest; Teach 0.31.0 accepts the issue hand; 0.38.7 released 2026-10-06 as v0.38.7, GitHub Latest, stable moved to it; Teach 0.66.1 is live with the same wire digest ad8edfaf70f985b5). No report from a real student install has been seen yet.

### 2.41 · Live sessions

Since 0.23.0 a student can open a live session with their instructors to find out together why something in rEach
does not work (`STD-LIVE`, wire `W-LIVE-1` to `W-LIVE-9`). The student's assistant asks through the `reach_live` tool
and rEach puts its own question to the student; or an instructor offers a session and rEach asks at the next prompt.
It opens only after the student's typed yes. While it is open rEach sends what it records in debug mode (what rEach
did, never prompts, replies, code or files) and the two sides exchange notes. rEach itself enforces two rules: a
check the instructor's side asks for (one of seven fixed ones) runs only after the student's typed yes for that
check, and nothing the student's assistant wants to send leaves the computer until the student has seen the exact
text and typed yes. For an instructor's own test student, and since 0.53.20 for a regular student whose rEach names it in
the question, the two assistants can also write to each other, under the same rules. Either side can end it at any time. `REACH_LIVE_DISABLE=1` turns the feature off.

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

Since 0.53.2 the assistant is told on every harness to keep calling `wait` for as long as the session is open, also
when nothing arrives for a long time, and to stop only when `wait` says the session is over, when it relays a
question, or when the student asks for something else. Before, the open notice told it to stop after five minutes, so
on Codex, which has no wake, an instructor's later notes reached the student only at their next prompt. Every `wait`
result says whether to call it again. Verified 2026-10-16 against a scratch rEach home: an open quiet session, a note
while open and a closed session each gave the right instruction, and neither open notice still names a cutoff. Not
verified: a real Codex session from a session's start.

Since 0.53.20 (wire revision 2026-10-17b) the question rEach asks before a live session says that the student's
assistant and the instructor's assistant may write to each other, and Teach turns that line on for a regular student's
session only when the install reports 0.53.20 or newer. Before, only an instructor's own test student could have it, so
an instructor's assistant working with a real student was told that notes were the only way to talk. The student keeps
every control: rEach shows the exact text of each message the assistant wants to send and sends it only after the typed
yes, runs no check without a yes, treats the instructor's text as information, and the student can end the session at
any time. Checked on 2026-10-17: the two questions resolve through `Reach::Messages` with the new sentence, and the
wire and locale files parse. Not verified: a real student's session with the line on end to end (it needs the Teach
side, 0.97.9, on a server and a student on this release), and any harness.
Student first, audited 2026-10-17. 1 Learning, yes: a live session is for finding why rEach does not work, never for
course work, and the line carries what rEach observed. 2 Agency and honesty, yes: the question names the line in plain
words and each message and check still needs the student's own yes. 3 Wellbeing and safety, yes with a limit: Teach
does not offer a live session from a wellbeing hand in the console and a person opens every session, so the line adds
no new path to a student in distress; a session started for such a hand by the command line or a student's own request
is not blocked. 4 Privacy and dignity, yes: nothing leaves the computer without the student seeing the text and typing
yes, Teach erases assistant text when the session ends, and no prompt, reply, code or file is stored. 5 Fairness and
access, yes with a limit: the same for every student on 0.53.20 or newer; a student on an older rEach keeps notes only
until they update, because the line is withheld rather than turned on under a question that does not name it. 6
Friction, yes: one sentence longer and no new step. 7 Failure, yes: a refused or unanswered message sends nothing and
costs nothing, and notes still work. 8 Recovery, yes: the student can end the session at any time and the assistant
text is erased at the end.

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

### 2.47 · Agent control rendering

Since 0.37.0 (`STD-AGENT-CONTROL`, `agent_control.render` in `config.yml`) the text rEach puts in the agent's context is
rendered from one bundled document, `agent-control/agent-control.yml`, pinned by `agent-control.yml.sha256`.
`Reach::AgentControl` uses the bundled copy while its digest matches and prefers the copy delivered with the course
guardrails when that copy is valid and not older. Every injected block (session context, prompt and tool hooks, tool
bridge, generated rules files) goes through one channel call under a channel id fixed in code and sits in its frame; the
order of authority opens each context and each generated `AGENTS.md`, `CLAUDE.md` and `GEMINI.md`. On any error, with the
flag off or with no usable document, the raw text is used. `reach doctor` reports a bundled copy that does not match its
digest and a refused course copy (`R-DOC-AGENT-CONTROL`). The student sees the same messages as before.

Verified 2026-10-06 on Linux, Ruby 4.0.7 runtime kit, against a scratch course server with the three flags on: the prompt
context opened with the five-line order of authority, every block sat in a frame, the announcement was framed
with its sent day, date, time and zone, and the answer to "help me with the slice" came back with exit 0. Not verified:
macOS, Windows, Ruby 2.6 and a real harness session.

Build ✅ · Deploy 🟢 Live (0.37.0 Latest and stable, 2026-10-06; Teach 0.64.0 live). · Blocker: -.

### 2.48 · Typed course controls

Since 0.37.0 (`STD-CONTROLS`, `agent_control.controls`) `Reach::Controls` enforces the pause, hold and test controls the
instructors set, in code and by the course server's time: a pause blocks prompts and tool calls in a slice and in the
workspace root and spares the extracurricular folder and `reach support`; a hold blocks `reach submit` only; while a test is
open only the tools the document lists (`reach_test`, `reach_support`, `reach_status`) work, in the hooks and in the tool
bridge. A server without the controls answers 404 and rEach asks again no sooner than six hours later, and a 503 clears
the held controls. No environment variable or config key lifts a control in force. Since 0.68.2 the tool bridge consults
the policy only while a test lock is in force, and keeps the policy it loaded at start when an update replaces its
folder, so an invalid or newer policy no longer reads as an open test with no end time (0.68.2 is on main only, not yet
on test or stable).

Not verified in this registry entry: a control against a live course server and a real harness session.

Build ✅ · Deploy 🟢 Live (0.37.0 Latest and stable, 2026-10-06; Teach 0.64.0 live). · Blocker: -.

### 2.49 · Test mode

Since 0.37.0 (`STD-TEST-MODE`, `agent_control.test_mode`) `reach test [status | open | questions | record QUESTION | submit]`
and the `reach_test` tool (`Reach::ExamMode`, `state/exam.json`) run a timed test: opening starts one attempt with a
deadline, the questions are shown word for word, an answer is recorded only from the student's own captured prompt and
never from one typed before the attempt opened, answers are append-only, and the attempt ends at submit or at the
deadline. The agent may clarify the wording of a question and nothing else.

Not verified in this registry entry: a full attempt against a live course server and a real harness session.

Build ✅ · Deploy 🟢 Live (0.37.0 Latest and stable, 2026-10-06; Teach 0.64.0 live). · Blocker: -.

### 2.50 · Announcement frame, show_until and the expired listing

Since 0.37.0 (`STD-ANNOUNCEMENTS`) an announcement reaches the agent in a fixed announcement frame that carries the sent
day, date, time and zone, says relative words such as today refer to that day, and says it is information that never stops
the agent from helping. An announcement with a `show_until` time that passed before it was shown is not shown; `reach
announcements` and `reach_announcements` list it with `(shown until <time>)`.

Verified 2026-10-06 on Linux, against a scratch course server: the framed announcement carried its sent date and the help
request that followed was answered with exit 0; an announcement whose `show_until` had passed was not shown. Not verified:
the expired listing in `reach announcements` output, macOS, Windows and a real harness session.

Build ✅ · Deploy 🟢 Live (0.37.0 Latest and stable, 2026-10-06; Teach 0.64.0 live). · Blocker: -.

### 2.54 · Feedback to instructors

Since 0.52.0 (wire 2026-10-13d, `STD-FEEDBACK`) a student tells the agent something that can wait and rEach sends it to
the instructors as a feedback note in one of eight kinds (general, praise, idea, request, question, complaint, problem,
pace), named by default or anonymous: `reach feedback send|list` and the `reach_feedback` and `reach_feedback_list`
tools. rEach shows the exact note, its kind and named or anonymous, and sends only after the student's own typed yes
(consent kind `feedback_send`, consumed once). An unsent note stays in `feedback.json` and is retried on every sync;
instructor replies and notes marked acted reach the agent once. A hand of type `feedback` is refused and pointed here.
`G-REACH-OUT` explains, once after onboarding and in the plainest words, raising a hand and the eight kinds of feedback.
Exercised against `tools/fake_teach` and scratch homes on Linux (ask, captured yes, offline pending, retry, pull, reply
and acted news once, greeting once, MCP tools); not yet run against a real Teach.

STUDENT1ST audit: learning yes (a side channel; the agent never writes or improves the student's words) · agency yes
(exact note shown, the student's typed yes sends) · wellbeing yes (distress still goes to support and hands; a complaint
opens a desk ticket so it is seen) · privacy yes (anonymous notes carry no identity, and the student is told what
anonymity does not hide) · fairness yes (same command, tool and chat flow on every app and OS) · friction yes (one
sentence and one yes; the notice shows once) · failure yes (an unsent note stays saved and is retried) · recovery yes
(change or drop it before the yes; `reach feedback list` shows each note's state).

Build ✅ · Deploy 🔵 · Blocker: -.

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
tools/fake_teach: past-due writes allowed, a future assignment refused (before 0.64.10), notices on prompts 1 and 11 only, exactly
one hand of each kind, no network call from any hook (strace), and `late_work.allow: false` restoring the old refusal (and, since 0.64.10, no refusal of either).

Since 0.64.11 (wire revision 2026-10-25b, W-SUB-1) a slice may be submitted again after its due time, and each is
marked late. Since 0.64.12 (wire revision 2026-10-25c, W-SUB-1) Teach accepts at most 50 submissions of one slice that
were not rejected, partial ones included, before or after the due time; the 51st answers 409 conflict and stores
nothing, and `rejection_fixes.conflict` in `locales/en-US.yml` tells the student the part has reached the limit of 50
submissions and to ask the instructor. `M-LATE-CAN-SUBMIT` names the limit, and `rejection_fixes.forbidden` no longer says
"current assignment". `Reach::Submit.check_closed!` is removed, `Reach::LateWork.info`
reports `can_submit` true always and no longer carries `submitted_before_due`, and `M-SUBMIT-CLOSED`,
`M-LATE-CANNOT-SUBMIT` and `M-LATE-CANNOT-SUBMIT-ONTIME` are retired; Teach no longer answers `deadline_passed`. The
paragraph below describes 0.53.3 to 0.64.10 and no longer applies.

Since 0.53.3 a slice counts as on record when any ingest, grade or validation receipt for it is stored
(`Reach::Receipts.on_record?`), not only an ingest receipt. Until then a submission an instructor accepted by hand,
which reaches the student's computer with only a grade receipt, was offered once more as late, and Teach refused it with
deadline_passed. Verified 2026-10-16 against a scratch rEach home: a grade receipt alone closes the slice (the late
notice and `reach submit` both say it is already submitted), a grade receipt for another slice does not, and with no
receipt the one late submission is still offered. Not verified on a student's computer.

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
Since 0.41.0 (`STD-SMOKE-ASSIGNMENT-GUARDS`) the smoke writes its own schedule overlay with A1 due 14 days out, runs
rEach inside its own signed-in session instead of the host harness's, and checks the README gate, assignment
completeness and the reassignment void. Run `~/.cache/reach-smoke/a1/20261006-234634` against Teach 0.70.0 recorded
43 pass, 2 skip (codex-conversation, lan-second-device) and 0 fail.

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

### 4.6 · Compatibility matrix

Since 0.42.0 (`STD-ENV-REPORT`, `STD-COMPAT-TESTED`) every signed request reports the harness, OS family, OS release,
CPU architecture and Ruby version it was made from, so the instructors' side can count what works where; and the
platform smoke builds a tested matrix per leg and harness group (core, claude-code, codex) in the platforms workflow's
matrix job. Verified on Linux: the header reached a stub server and a forced failure left the request intact; matrix.rb
folded this host's report and two hand-made ones into the expected cells. Not verified: a workflow run on GitHub
(the matrix job has never run), and the tested scope is commands and hook command lines, not a live agent session.

Build ✅ · Deploy 🔵 (released with 0.42.0, no student has it yet) · Blocker: Human (release)

### 4.6.1 · Verified harness labels

Since 0.53.0 (`STD-HARNESS-VERIFIED`, wire 2026-10-16a, W-AUTH-8) one detector, `Reach::HarnessIdentity`, names the
harness and how sure rEach is of it. Every hook records its session's label in `state/harness_sessions.json` (newest 64
sessions of 14 days); a hook's own requests and any process whose `CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID` names a
recorded session report it as verified, environment markers as inferred, and the parent process, the last hook label or
the terminal or unknown fallback as weak. Every signed request carries `X-Reach-Harness-Confidence` beside
`X-Reach-Env`, and the harness is worked out per request, so the MCP server follows its session instead of freezing its
first answer. Verified on Linux with a scratch REACH_HOME: a real gate hook command line recorded its session and a
second process with that session id reported it verified; an unrecorded session with a VS Code entrypoint was inferred;
no markers was weak; one long-lived process changed from weak to verified once a hook recorded its session; signed
headers carried both values and neither under REACH_ENV_REPORT_DISABLE=1; pruning kept 64 and dropped a 15-day entry.
Not verified: that Codex's `CODEX_THREAD_ID` equals its hook `session_id` (if not, non-hook Codex processes report
inferred), and a live Claude or Codex session.

Build ✅ · Deploy 🔵 (takes effect on a copy once it reaches 0.53.0; the course server reads the confidence once it is updated) · Blocker: Human (release)

### 4.7 · Stable cadence

Since 0.43.0 (`STD-STABLE-CADENCE`) `stable`, the branch every student install follows, moves at most once a day and
only after the platform smoke passes on the Latest tag: `.github/workflows/stable.yml` plans with
`tools/stable_promote.rb` at 15:00 UTC, calls the platforms workflow on the tag, and promotes or holds (a `stable-hold`
issue). A release that changes `hooks/` gets a dated notice ref a day before it can reach `stable`, and rEach shows Codex
students `M-UPDATE-HOOKS-NOTICE` once. The managed updater now installs only the version `stable` points at (before,
any newer tag). Verified in the scratchpad: the plan's four answers, notice, promote, prune and hold against a scratch
bare origin with a stubbed gh; the updater's ceiling, missing-stable refusal and notice against canned ref listings;
`ver_stable`'s windows with stubbed answers. Not verified: a run of the workflow on GitHub, and Ruby 2.6.10 (not
installed here). Installs older than 0.43.0 keep taking the newest tag until they reach 0.43.0.

Build ✅ · Deploy ⚫ (not released) · Blocker: Human (release, push)

Since 0.64.14 a passing smoke on test also closes every open `stable-hold` issue (`apply ready`); before, only
`apply promote` closed them, and the workflow stopped running that once stable moved by the operator's
`polispec promote reach --to stable`, so the v0.64.0 hold (#4) stayed open after every later smoke passed. #4 and the
stale v0.64.8 `stable-ready` issue (#3) were closed by hand on 2026-10-25 after v0.64.12 passed on test (run
40246555650, five legs green). The same release gives both installers 5 download attempts with full-jitter exponential
backoff from 2 s capped at 30 s (the 0.64.6 macOS x64 smoke leg failed when three attempts to fetch Dovetail timed out),
and no whole-download timeout on Windows (one would fail the 66.7 MB Ruby kit on a slow connection). Verified: the Ruby installer against an unresolvable host, 3 attempts in 3.0 s
before and 5 in 11.4 s after. Not verified: `reach-install.ps1` (no PowerShell here) and the hold-closing path on
GitHub, which runs on the next stable run that plans a promotion.

Build ✅ · Deploy 🔵 (main, then test by promotion) · Blocker: Human (stable promotion)

## 5 · Interview and profile

### 5.1 · Intake interview and student profile

`reach hello`'s first-run interview asks twelve single-thing questions (studies/year, coding and AI experience, the
course's own interview question, goal, explanation style, creative lead, work times, deadline reminders) and stores
the answers in `~/.reach/profile.yml` only — never synced to Teach, never in a workspace. `reach profile
show|save|forget` and the matching MCP tools manage it directly.
Since 0.51.10 the interview is offered once per install: a student who skips it is saved as `skipped` (a new profile
status), and a partial profile is offered the resume greeting once (`state/interview.json`).
Since 0.51.10 the interview welcome no longer comes back in every new chat after the student answered or skipped it.

Build ✅ · Deploy 🔵 · Blocker: -.

## 6 · MCP bridge

### 6.1 · MCP tools beyond reference

The MCP bridge (`.mcp.json`, Claude Code and Cowork) exposes 27 tools beyond `reach_reference` (3.1): `reach_hello`,
`reach_enroll`, `reach_sync`, `reach_status`, `reach_check`, `reach_shape_check`, `reach_checkpoint`, `reach_plan`,
`reach_submit`, `reach_receipts`, `reach_qualify`, `reach_attempts`, `reach_raise_hand`, `reach_hand_status`, `reach_directive`,
`reach_profile_show`, `reach_profile_save`, `reach_profile_forget`, and since 0.14.3 `reach_support`, `reach_part`,
`reach_transfer_request`, `reach_modules` and `reach_next`, and since 0.16.15 `reach_remember`, `reach_recall` and
`reach_memory_forget` (2.29), since 0.21.12 `reach_update` (2.30), since 0.30.0 `reach_announcements` (2.43), and since 0.37.0 `reach_test` (2.49) — each a thin wrapper the agent calls instead of shelling out to
the `reach` CLI. The five 0.14.3 tools were driven over stdio against a scratch Teach on 2026-10-01: the transfer tool
returned Reach's own question and sent nothing until a captured yes, then one pending request reached Teach; the support
tool returned 911/988 and Teach held a hand; the part tool listed the A1 questions.
Since 0.51.10 the tools carry MCP annotations (`MCPBridge::LISTED_TOOLS`), so in Codex only the four tools that can
delete the student's data (`reach_profile_forget`, `reach_memory_forget`, `reach_transcripts`, and `reach_storage`)
and the three that send work or a request to the course server (`reach_submit`, `reach_qualify`, and
`reach_raise_hand`) still go to Codex's approval review, and read-only tools such as `reach_directive` and
`reach_status` no longer do.
Since 0.51.10 `reach_plan`, `reach_check`, `reach_checkpoint`, `reach_shape_check`, and `reach_part` take a `slice`
argument, and every `--slice` (submit and hand raise included) resolves a slice by exact name, dashed form, or a
unique `-<name>` ending, listing the slices when the name is unclear or unknown (`Workspace.named_slice!`).
Until 0.63.1 `reach_part` used that argument only when recording: the listing took the focused slice, else the course's
current assignment, so an A2 slice named from the top of the course folder after A2 was due listed the A3 questions.
Since 0.63.1 a named slice decides the listing, as `reach part --slice` does. Checked on 2026-10-22 by calling
`MCPBridge#part_tool` from both trees with no focused slice, current assignment A3 and two slices: 0.63.0 listed A3
for `slice: opportunities.a2s1`, 0.63.1 lists A2, the call without a slice still lists A3, and an unknown slice is refused.
Not verified: a student's harness calling the tool.

Build ✅ · Deploy 🔵 · Blocker: -. (0.63.1: Build ✅ Built · Deploy 🔵 Built, not on stable · Blocker Human: operator promotion.)

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

Since 0.37.0 doctor also runs `R-DOC-AGENT-CONTROL` (2.47): the bundled `agent-control.yml` matches its digest and carries every channel rEach uses.
Since 0.51.10 `reach doctor` no longer says the qualification tools are missing when rEach's own Ruby already carries them (`R-DOC-GEMS`, iss_8bfc0e0c).

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
both macOS legs, with both package kinds opening from storage and from fake_teach under the kit Ruby. From 0.21.3 to
0.35.11 that handled move also recorded a fault event (`crypto_self_test`) on every command, which reached the
course's technical support as a problem although nothing had failed; since 0.35.12 it records nothing. Checked on
2026-10-05 on Linux with a Ruby 4.0.6 whose GCM `auth_data=` was made to raise as LibreSSL does: three
`reach doctor --report --offline` runs with and without a kit spooled three fault events each before the change and
none after it, with every run exiting 0 on the same GCM path as before. Not run on a Mac.
Reports of the event kept arriving under 0.35.12 and later: a fault event written before 0.38.7 carries no
`reach_version`, the spool outlives an update, and a harness plugin copy can stay older than the `reach` on PATH, so
events written by an older rEach and flushed later were filed under the version of the install that sent them, or
under no version once Teach read it from the event alone. Since 0.38.9 `Reach::Debug.flush` moves every spooled `crypto_self_test` fault
event to `debug/stale-<day>.jsonl` before it batches and sends none, whichever version wrote it; nothing is deleted.
Checked on 2026-10-06 on Linux with the same simulated LibreSSL failure: three `reach doctor --report --offline`
runs under 0.35.11 spooled three such events; a flush under 0.38.9 batched none of them, moved all three to the
stale file, kept a real fault in its batch, and a run under a normal Ruby spooled nothing. Not run on a Mac.

Build ✅ · Deploy 🟢 Live (0.38.9 released 2026-10-06 as v0.38.9, GitHub Latest, stable moved to it; student Macs have run the kit fallback since 0.21.3) · Blocker: -.

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
Since 0.51.10 the panel shape check no longer stops with "dovetail check returned no report" when a panel file holds a
character such as … or ’ and the app runs commands with no language setting (Codex on a Mac): the checker runs with
`RUBYOPT=-EUTF-8` (iss_91a2cfaa).

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
Since 0.51.10 `reach directive COACH FOCUS LANG` prints every directive named, not only the first.

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

Since 0.35.7 the hook knows every Cowork entry point Claude Code 2.1.289 names (`local_agent`, `remote_cowork_trigger`,
`claude-coworker` and `claude-coworker-terminal` as well), and a Cowork prompt hook that would still block answers
with the same Code tab message and exit 0, because on Windows every Cowork message ended in an empty turn. Checked by
running the hook under each entry point before and after, and with the first check switched off; never run in Cowork
itself.
Build ✅ · Deploy 🔵 · Blocker: Human (send one message in Cowork on a Windows computer with rEach installed).

Claude desktop, plugin added from Customize > Plugins; the reason the executable lives at `exe/reach` rather than a
top-level `bin/` (Cowork refuses a plugin that carries one).

Build ✅ · Deploy 🔵 · Blocker: Human (no session has been run).

### 10.3 · Codex

Since 0.35.9 the Ruby in every command rEach writes into a course folder is the runtime kit installed in the rEach
home whenever one exists, whichever Ruby wrote the folder, so Codex's approval of the course hooks no longer breaks
when a different Ruby rewrites them. Each session start rewrites a course folder whose rEach commands name another
Ruby or shim (for example, a kit left behind by a home move) and refreshes Codex's trust. Checked in a scratch home
with codex 0.160.0 `app-server hooks/list` (modified, then trusted after the repair); the Windows quoted-command
form is not yet run on Windows.

Since 0.35.6 (`STD-CODEX-HOOK-TRUST`) the plugin's two Codex hooks carry the course session and prompt work, so
sign-in, prompt recording and the course prompt rules no longer depend on a course folder's hooks, which Codex never
ran because it trusts each hook by the hash of its command. The course folder's `.codex/hooks.json` keeps only the
tool and stop hooks, and under the student's Codex-settings consent rEach records Codex's trust for them and marks each
course folder a trusted project. Missing or stale trust refuses qualify, submit and part answers with
`M-HOOKS-UNTRUSTED`, whose remedy is `reach_setup configure`, never a restart. Hashes and keys were checked against
codex 0.160.0 `app-server hooks/list` in a scratch Codex home for the root, slice and extracurricular folders (all
handlers trusted after the write); not yet run on a real Windows Codex, where Codex's own spelling of the hook path
is unverified.

Build ✅ · Deploy 🔵 · Blocker: Human (a Windows Codex student has to sign in on 0.35.6).

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

**0.35.18, from one real Windows Codex Desktop install (2026-10-05):** ✅ built, ✅ released as Latest and on `stable` (any student
machine that updates). Student installs follow the `stable` branch (moved only on a Latest release) instead of `main`; course-code
parsing no longer sends chat sentences; the request log redacts the passkey; consent is bound to the asking chat;
`work_at` comes only from course-folder work hooks; the submission ZIP leaves out read-only kit files and uses the
Windows Downloads known folder; the runtime kit matches a lock in LF or CRLF form; `update run --apply` refreshes a
plugin-cache install through the harness CLI. Verified on Linux with scratch homes, fake harness CLIs and the
fixture Teach. The maintainer confirmed it working in real Codex Desktop on Windows on 2026-10-05 (0.35.19); the Claude Code
app's marketplace box is still untested. Since 0.35.20 `CODEX_CLI_PATH` is used only when it names `codex` or
`codex.exe`, and `tools/release_stable.rb` moves `stable` to a Latest release (fast-forward only).

Since 0.51.10 Codex's automatic approval review no longer refuses rEach's own course steps, such as reading a course
directive, as protected-material access (iss_0db3ea38, iss_62145750, iss_ed5705ca).
Since 0.51.10 in the Codex app rEach works on each part of the assignment from the course project chat (iss_00788df8).
Since 0.51.10 a yes to a question asked through rEach's tools (in the Codex app, or in Claude Code after `/clear`) is
recorded in the chat that shows the question, whether that chat is in the course folder or any other folder, and also
when another chat asked the question (instructor decision 2026-10-13) or the assistant added a short note after it;
the assistant's own text never counts (iss_26e0e026).

### 10.4 · Antigravity

Google's agent app and CLI (replaced Gemini CLI in 2026); reads `.antigravity-plugin/plugin.json` (Agent Plugins 1.0),
the MCP server from `mcp.json` (while its Agent Plugins flag is on) and `rules/reach.md` as its always-on pointer to
`reach hello`. Antigravity has no documented hook format, so it ships none; since 0.9.0 it runs
`REACH_HARNESS=antigravity reach submit`, so Teach notes its submissions as unwitnessed (2.14).
0.68.1 removed the root `plugin.json` so Codex would read rEach's hooks, which left Antigravity with no manifest:
`agy plugin validate` (agy 1.4.7) found no plugin.json and no components. Since 0.68.3 (packaged with rplugin 1.19.8)
the manifest lives in `.antigravity-plugin/`, which Codex does not read, and `rules/reach.md` declares
`trigger: always_on`, which Antigravity requires of a rule. `agy plugin validate` on the 0.68.3 tree finds the
manifest, 18 skills, one agent, the MCP server and the rule with no errors; its warnings that `AGENTS.md` and
`hooks/hooks.json` are not loaded and that `design-taste-frontend` is large were there before. No `mcp_config.json`
ships, because Antigravity's native MCP file takes no root variable and rplugin 1.19.7 wrote the packaging machine's
path into it; with Antigravity's Agent Plugins flag off, rEach has no MCP server there and works through its skills.
`reach setup --harness antigravity` and the plugin-directory link have not been run.
Since 0.23.1 (`STD-NOHOOK-ENROLL`) a locked Antigravity session is told to walk the student through `reach enroll`
in a terminal window at once, because rEach cannot ask for enrollment details in an app without hooks; a student
reported being sent to their instructor instead (2026-10-03). Exercised with `reach hello` in a scratch home on
Linux only.

Build ✅ · Deploy 🔵 · Blocker: Human (the manifest validates with `agy` 1.4.7; no Antigravity session has been run).

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

### 2.51 · Brain planes on the student's computer

Since 0.38.0 (`STD-BRAIN-PLANES`) the microbrain is admitted into rEach's own rBrain corpus at
`~/reach-work/.reach-home/corpora/reach` on every computer that has the runtime kit, not only where rplugin is installed.
A pinned SDK kit (rplugin 1.9.0 and rBrain 0.14.0 runtime files and the microdatabase corpus template, about 120 KB,
release asset `sdk-1.9.0-0.14.0-r2` published with `--latest=false` on the instructor's publication decision of
2026-10-06, its manifest sha256 compiled into rEach since 0.38.1) installs itself in the background at session
start (`reach sdk install`, `reach sdk status`; `REACH_SDK_DISABLE=1` stops downloads). Admission and the daily
consolidation run in a detached child under the kit Ruby with a clean Ruby environment, never in a hook. `reach_recall`
goes through rBrain Context in a child capped at 10 s, with the query in a 0600 file, and falls back to the lexical index. `reach memory forget` erases
through rBrain Erase in a child capped at 30 s; a forget that cannot reach the planes is queued (0600) and runs before the
next admission. `reach doctor` names the route (`R-DOC-BRAIN-PLANES`). Spool mode stays the complete fallback with no kit,
no SDK, an instructor persona, `brain.planes: false` or `REACH_BRAIN_PLANES_DISABLE=1`. No embedding model is shipped, so
plane recall is lexical and graph only, and `rcorpus check` reports each finding's embedding as pending. Since 0.64.23 the daily
consolidation rebuilds the corpus index when it wrote, because the pinned rBrain `Consolidate` does not, so `rcorpus check` and
`rplugin doctor reach` report no `index_manifest` finding after it.

Verified 2026-10-06 on Linux in scratch homes: a pinned install downloaded the published r2 asset from GitHub, verified
it and placed it, and the planes then took a remembered record, recalled it through the child in 0.27 s and erased it on
forget; an unpinned, corrupted or kit-less install was refused; the build is deterministic and its privacy gate
refused a planted home path, tailnet host, private address, access token and the builder's name; under Ruby 2.6.10 (Docker) `remember` returned in 198 ms while a detached child admitted the
record into the planes; recall went through the child in 0.25 s and fell back to the index; forget erased the text from
spool and planes, and a queued forget ran before the next admission; with no kit every brain verb matched 0.37.3. Not
verified: macOS, Windows, Hermes and a real student session.

Build ✅ · Deploy 🟢 Live (0.38.1 Latest and stable, 2026-10-06; SDK r2 published; not yet seen on a student's computer; the 0.64.23 index rebuild is not yet on stable). · Blocker: -.

### 2.52 · Audit hardening (2026-10-08 review)

Since 0.46.1 rEach carries the fixes from the 2026-10-08 five-area review (`TODO.md` "Audit 2026-10-08", RAUD-01 to
RAUD-67; `CHANGELOG.md` 0.46.1).
- **Shell gate.** It fails closed: a command it cannot model is refused (`M-SHELL-UNMODELED`), wrappers are unwrapped, and run-a-string forms are refused. Every operand of a mutating command must be owned, and PowerShell commands are translated to the modeled forms. The five reproduced bypasses are closed.
- **Consent.** It takes only `yes` or `y`, bound to the question shown, and a live diagnosis needs the consent recorded locally. Since 0.63.2 a short reply that starts with `yes` or `y` and adds only words from a fixed filler list (at most 8 words, such as "Yes, submit it") counts too; until then a student's "Yes, submit it" left `reach_submit` asking again. `yeah`, `ok` and `sure` still never count on their own or as the first word. Checked on 2026-10-22 by calling `Reach::Consent.yes?` on 0.63.2: "Yes, submit it", "yes please" and "Y, submit" are yes; "yeah", "ok yes", "yes but wait", "maybe yes", "yes no" and "Yes submit my A2" are not. Build ✅ · Deploy 🔵 On test (0.63.2). · Blocker: Human (stable promotion).
- **Atomic, locked state.** `install.yml`, receipts, acks, packages and keys are written atomically, and `install.yml` changes happen under a lock.
- **Student files.** A package refresh no longer locks the student's own files.
- **Outbox.** Queued submissions replay in order, and a refused one is kept and reported.
- **Release gate.** It reports a missing Teach URL instead of crashing.
- **Privacy.** Debug uploads and code paths are de-identified.
- **Updates.** They stop after the attempt limit and roll a failed migration back.

Verified 2026-10-08 in scratch homes:
- The reviewers' repros now pass: the three-writer `install.yml` race loses nothing, a corrupt receipt is moved aside, the symlink-chain archive writes nothing outside its folder, and a cp1252 byte gives findings.
- The gate table runs 477 commands through `Reach::CLI.gate_dispatch` with 0 mismatches under Ruby 4.0.6 and Ruby 2.6.10 (Docker). That is 296 blocked, including every reviewer bypass and the Windows PowerShell rows, and 181 allowed.
- A failed migration restores the previous plugin and stops at 5 attempts.
- Six racing `update.json` writers lose no update.
- `ruby -wc` is clean on every changed file under 2.6.10 and 4.0.6, and the tree loads under both.

Not verified: a real Windows or macOS host (schtasks, launchctl, PowerShell), or a live harness session.

Build ✅ · Deploy ⚫ (not released) · Blocker: Human (push and release; Teach re-pin of the gate files)

### 2.53 · Enrollment confirm loop and unreadable hooks.json (Windows)

Since 0.46.2 a failure on the student's computer after the password confirm is reported with its error and a fault
instead of asking for the password again, and a course folder's `.codex/hooks.json` is replaced atomically and
rewritten at session start when it does not parse (`STD-ENROLL-PASSWORD`, `STD-STATE-FILE-REPLACE`; `CHANGELOG.md`
0.46.2). Found on a Windows Codex app student on 0.38.10: Teach recorded a new install for every confirm while the
student was asked to type the password again, and Codex reported the course folder's hooks.json unparseable.

Verified 2026-10-08 in a scratch home under Ruby 4.0.6 with stubs: a confirm whose registration raised `EACCES`
answered `M-ENR-PASSWORD-RETRY-FAILED` naming `EACCES`, went back to `awaiting_password`, dropped the stored digest and
recorded the fault; a step error answered `M-ENR-STEP-FAILED` with the current question; an empty `.codex/hooks.json`
counted as stale, `configure_all` rewrote it parseable and read-only with no temporary file left, and the rewritten
folder was no longer stale; `Stamp.store!` succeeded after two refused renames. Not verified: a real Windows host or a
live Codex session, and which save actually failed on the student's computer (no debug events were uploaded).

Build ✅ · Deploy ⚫ (not released) · Blocker: Human (push and release)

### 10.7 · Handout parity

Since 0.38.10 (`STD-HANDOUT-PARITY`) rEach does what the student setup and troubleshooting handout shows: the install
greeting asks to connect to the course first, deliverables/ and extracurricular/ exist right after install, `update
reach` gets a word-for-word reply and the version answer reads "rEach X is installed and up to date", the
re-enrollment password sentence shows only to students who enrolled before, Codex refuses enrollment and sign-in
outside reach-work, Antigravity opens a terminal window for enrollment and sign-in, Hermes prints the approve-once
rule, a submission answers in one message with a ZIP named like A1-jruiz-20261007.zip, times read "Oct 19, 2026 11:59
PM PDT", and a raised hand carries the last step that worked and what the student saw with passkeys, labelled
passwords and the student ID left out, adding the course's support contact from Teach when it cannot be sent. Checked
on 2026-10-06 in scratch homes against fake Teach (platform smoke 12 passed, the one doctor failure is this machine's
Codex sandbox and also fails on 0.38.8). The terminal windows ran on Linux only; macOS and Windows windows are
unverified.
Since 0.51.10 on Linux the sign-in and enrollment window opens with ptyxis and with a plain gnome-terminal
(`Reach::Desktop.terminal`).

Build ✅ · Deploy 🔵 · Blocker: Engineering (macOS and Windows terminal windows unverified)

## 11 · Planned

### 11.1 · Analytics keyed to the enrolled student

Decide and document which usage data, metadata and analytics rEach sends to Teach, and send them keyed to the
enrollment (TODO.md, docs/DESIGN-DECISIONS.md). Nothing is built.

Build ⚪ · Deploy ⚫ · Blocker: Human (the decision).

### 11.2 · Corpus-side recall in the student's kit

Shipped in 0.38.0 as 2.51: the SDK kit ships rplugin and rBrain as a separate pinned release asset beside the runtime
kit, and a student's computer runs `Rcorpus::Context` recall and `Rcorpus::Consolidate` in a child under the kit Ruby.

Build ✅ · Deploy 🟢 (see 2.51) · Blocker: -.

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

Since 0.51.7 rEach is MIT-licensed: `LICENSE` at the root (copyright PatḗrasAI), `licence: MIT` in `reach.spec.yml`,
`"license": "MIT"` in the three plugin manifests, and a License section in the README naming Dovetail's own
AGPL-3.0 (run as a separate process) and the MIT tasteskill. `exe/reach` and `lib/reach.rb` carry an MIT SPDX line. Since 0.51.11 `reach.rplugin.yml` declares `license: MIT`, so `rplugin package` (rplugin 1.13.0 or newer) writes it into the native manifests and `rplugin check` finds none stale.

Build ✅ Shipped · Deploy 🔵 on main; students get it with the next stable promotion.

### 11.7 · Security audit mode for releases

Since 0.34.0 (`STD-SECURITY-AUDIT-MODE`) a release push to GitHub passes a pre-push gate first: a scan for secrets,
credential files, local paths and student data (a salted hashed roster from Teach), then a headless read-only Claude
Code audit, blocking on a finding at or above the severity set on Teach's Ops page. Maintainer tooling only; nothing
students run changes. Checked on 2026-10-05 against a scratch remote and a stub Teach: a non-release push passes
silently, a planted private key and a seeded student email and name block with masked reports, a clean release ran a
real Haiku audit ($0.26) whose verdict the tag push reused, a stopped Teach falls back to the cached settings and
roster, the kill switch skips, and report-only never blocks. Interim: raudit takes the gate over fleet-wide. Not yet
run under Ruby 2.6.10, against live Teach, or on a real release.

Since 0.40.0 the hook runs `tools/release_gate/gate.rb` (11.8): block at high by default, `REACH_SECURITY_AUDIT=0`
ignored, the instructor's recorded override the only way past a block, and Teach's own pushes pass the same gate.

Since 0.64.6 the entropy rule judges a quoted value after a leading `${NAME}/` or `$NAME/` (`ENV_REFERENCE` in
`tools/security_audit/scan.rb`), so the plugin-root hook commands that 0.64.3 put in `specs/app.yml` no longer block the
gate or keep the model audit from running. Run against the real 0.64.3 diff and eight probes: the three findings are
gone, and random values with and without such a prefix are still flagged.

Build ✅ · Deploy 🔵 · Blocker: - (0.64.6 reached stable at e279583)

### 11.8 · Release integrity gate and accepts-aware degrade

Since 0.40.0 (`STD-RELEASE-GATE`, `STD-COMPAT-ACCEPTS`) a release push passes one pre-push gate shared with Teach
through `specs/release_gate.yml`: the security scan and audit, then nineteen spec-named checks on compatibility (wire
digest against the live and main Teach, pinned copies against their owner, installs that could not report), version
integrity (collisions across branches and worktrees, VERSION against its eight homes and the tag, tags without a
GitHub release, a release that would demote Latest, `stable` behind Latest without a hold), known broken state (open
blocker alarms and issues, a failing doctor, a backup line that is not green) and instability (flapping alarms until 0.64.22,
a long-lived unit on stale code). One severity scale; critical and high block; a check that cannot run says so and blocks
in the critical class. Every run and every override is recorded on Teach; the override is typed on a terminal with a
reason and an expiry, raises an alarm until one push consumes it, and no environment variable skips the gate. Teach
also advertises the hand triggers, debug kinds and harnesses it accepts, so a drifted install degrades (issue hand with
capsule null) instead of going silent. Checked on 2026-10-06 against scratch bare remotes, a scratch Teach and a scratch
database: a wire change blocked (CMP-WIRE-LIVE), a version collision blocked, a planted student-style address blocked
Teach's push, an alarm opened three times in 24 hours refused the push and the push passed once that window had
elapsed, a terminal override let exactly one push through and the next was
refused, `reach doctor` named the missing gate, and the four accepts cases behaved as specified in process. The hook's blind spot
for a push named `HEAD:main` was found on the first live push and fixed before the tag. Not yet run on a live tag or release; `agent-control/agent-control.yml` is still the v2 copy, so CMP-PIN warns medium
until it is re-pinned from Teach main. 0.40.1 moved Teach's schedule, settings, alarm names, routes, scopes, port and
commands out of `specs/release_gate.yml` into the private superproject's copy (`STD-TEACH-OPAQUE`); the public file keeps
the tables the gate reads; the 0.40.0 commits before this fix are superseded, and no tag or release carried them.
Since 0.47.1, until its removal in 0.64.22, INST-FLAP skipped the gate's own `release_gate:*` and `release_gate_override:*` alarms, as KNOWN-ALARM does,
so a refused push no longer keeps the gate refusing for 24 hours. Checked on 2026-10-08 in process with the live
flapping facts: the gate's own alarms (8 and 7 openings) produced no finding, and `doctor` (3 openings) still did.
Teach's pinned copies of `checks.rb` and `specs/release_gate.yml` still need re-pinning.
Since 0.64.22 INST-FLAP is gone from the gate: the check, its table entry, its order and facts lists, and its entry in
`specs/release_gate.yml` and `specs/app.yml` are removed, because how often an alarm opens is the service desk's to
track, not a release's to wait on. Checked with `ruby -c` and by loading `checks.rb` against `specs/release_gate.yml`
(18 checks in the table and the spec, none named INST-FLAP, order and facts lists consistent); no gate run against the
live Teach was made. The flapping facts Teach still reports are no longer read.
Build ✅ Built, Deploy 🔵 Pending (push, then Teach re-pins `checks.rb`).
Since 0.47.2 `gate.rb check --as-push` exits as the push would: zero when an active lease or a covering override would
let the push through, consuming nothing. Polispec's G-GATE runs it, because a plain `check` ignored every override and
lease, so no override could unblock `polispec promote` while fleet-state findings (CMP-INSTALLS, KNOWN-ALARM) stood.
Since 0.47.4 the platform smoke's doctor step tolerates `R-DOC-BRAIN-PLANES`, `R-DOC-SUBSCRIBE` and the unconfigured-Codex
`R-DOC-CODEX` only in the wording a bare runner produces, so `platforms.yml` can pass again on every OS leg; a different
wording of those codes still fails the step. On a leg with no runtime kit (Windows arm64) it also tolerates
`planes: spool mode (no runtime kit)`. GitHub run 37913694151 on the branch passed linux-x64, macos-x64, macos-arm64
and windows-x64 and failed windows-arm64 on that no-kit wording, which this change covers.
Run 37914351415 on 9b7e4fa then passed all five legs. linux-x64 passed only on a re-run: its first attempt printed
`background job not installed`, which still fails by design (the runner had no systemd user manager that time).
Since 0.47.5 the smoke points `RPLUGIN_HOME` and `XDG_STATE_HOME` into its scratch directory, so polispec's local test
deploy step no longer loads the machine's own rplugin, fails on `planes: in-process` or writes into the real
`~/.corpora/reach`.
Since 0.49.0 polispec runs that smoke hermetically, with rplugin, XDG and rEach homes pointed at scratch and the real corpus,
`~/.reach` and `~/reach-work` fingerprinted as protected roots. A runner with no systemd user manager skips the subscribe check.
`to_stable` now also needs 24 h on test (G-SOAK), live Teach serving this wire (`gate.rb wire-live`), a lease with 20 minutes
left (`--min-lease-minutes`) and no live student activity (F-LIVE). Latest is flipped by the operator once
`stable_promote.rb latest-status` says the tag is eligible. The smoke keeps the subscribe job's systemd units in its
scratch (`REACH_SYSTEMD_USER_DIR`), so no run installs a real `reach-subscribe.timer`. Since 0.49.1 G-RCHECK and G-RDOCTOR
run outside the isolation (`hermetic: false`, polispec 0.15.1), because they read the installed plugin and its event logs.
Build: on main (0.49.1). Deploy: test after `polispec promote reach --to test`.
Since 0.47.6 the smoke is the polispec `deploy.health.run` of the test and prod environments (polispec 0.12.0), so a
passing test deploy records health `ok` and satisfies G-TESTED for `polispec promote reach --to stable`.

Build ✅ · Deploy 🔵 (no tag, release or `stable` move until the instructor approves) · Blocker: Human

### 11.9 · Issue closeout trailers

Since 0.45.0 (`STD-ISSUE-CLOSEOUT-HOOK`) `tools/release_gate/install` also enables `.githooks/commit-msg`, which asks
the course server which open issues a commit fixes and appends `Fixes-Issue:` (identity evidence only: the issue id,
the issue branch, or its ship subject) and `Probably-Fixes:` (scored candidates, never a state change) trailers. It
sends the subject, message, branch and at most 200 staged path names, never diff content, and never blocks a commit;
`CLOSEOUT_DISABLE=1` or `git config closeout.enabled false` turns it off. Maintainer tooling only; nothing students run
changes. Checked on 2026-10-08 in a scratch repository against a stub server: trailers added as answered and not
duplicated, a down server (0.46 s) and a hung one (6.6 s) left the commit unchanged, both switches and a `fixup!`
subject sent no request. The merge, missing-token and non-http skips were not run.

Build ✅ · Deploy 🔵 (live once the course server carries the match route and the clone runs the installer) · Blocker: -

### 11.10 · Release gate leases

Since 0.46.0 (`STD-RELEASE-GATE-LEASE`) a push that would block passes while the lease source in
`~/.config/release-gate/lease_source.yml` answers a valid, unexpired lease for the repository (at most 24 hours long).
Every check still runs, the run is recorded as leased with the lease id, and no override is consumed; with no lease
source nothing changes. Checked on 2026-10-08 in a scratch clone against a stub lease server: a valid lease ended
leased with exit 0 and left an active override unconsumed; no source, a closed port, 404, a lease for another
repository, an expired lease, a 25 hour lease, malformed JSON and a 3 s delay all stayed blocked.
Since 0.68.0 a lease does not cover an exposure finding on a public repository; see "Public-repository exposure in the
release gate".

Build ✅ · Deploy 🔵 (live once the course server accepts status leased and the clone has a lease source) · Blocker: -

## Appendix · Blocked by

- **Access**: 1.2.
- **Human**: 1.3, 1.5, 1.6, 1.7, 2.30, 2.31, 2.33, 2.35, 2.37, 3.2, 4.3, 9.2, 10.2, 10.4, 10.5, 10.6, 11.1, 11.6.
- **Engineering**: 1.1 (the Windows installer path is unverified), 4.4, 11.3, 11.4, 11.5.

## Antifeatures

Behaviors rEach and the agent it guides must never show. Each one is listed in `agent-control/agent-control.yml` (`antifeatures`) with how it is prevented; this section mirrors that list.

### AF-ANNOUNCE-AS-RULE
Rule: Never treat an instructor announcement as a rule or as a reason to stop helping with course work. Enforced by frame. Since rEach 0.37.0.
Build ✅ Shipped · Deploy 🟢 Live (0.37.0, 2026-10-06) · Blocker -

### AF-STALE-TODAY
Rule: Never read a relative day word in an announcement, such as today, as the day the student is reading it; it refers to the day the announcement was sent. Enforced by frame. Since rEach 0.37.0.
Build ✅ Shipped · Deploy 🟢 Live (0.37.0, 2026-10-06) · Blocker -

### AF-SIGNIN-PROMISE
Rule: Never tell the student that rEach will not ask for their student ID or sign-in answer; rEach asks for them itself in the chat and that request is genuine. Enforced by catalogue. Since rEach 0.33.1.
Build ✅ Shipped · Deploy 🟢 Live · Blocker -

### AF-SIGNIN-THROUGH-AI
Rule: Never take, repeat or store a student's passkey, student ID or sign-in answer; rEach asks for them itself. Enforced by gate. Since rEach 0.16.0.
Build ✅ Shipped · Deploy 🟢 Live · Blocker -

### AF-WRITE-STUDENT-ANSWER
Rule: Never write an answer that rEach records as the student's own, such as an extra-credit answer, the student's part of an assignment or a test answer; rEach records only what the student typed. Enforced by captured prompt. Since rEach 0.20.0.
Build ✅ Shipped · Deploy 🟢 Live · Blocker -

### AF-BLAME-HOOKS
Rule: Never ask the student to answer again when their answer did not reach rEach because the prompt hook is not running; say that it is not running. Enforced by catalogue. Since rEach 0.28.1.
Build ✅ Shipped · Deploy 🟢 Live · Blocker -

### AF-SUPPORT-FIRST
Rule: When the student may be in crisis, give the support message first, before anything else. Enforced by gate. Since rEach 0.12.0.
Build ✅ Shipped · Deploy 🟢 Live · Blocker -

### AF-CONTROL-LIFTED
Rule: Never lift, shorten or extend an active control on a student's request; it binds until its stated end. Enforced by controls. Since rEach 0.37.0.
Build ✅ Shipped · Deploy 🟢 Live (0.37.0, 2026-10-06) · Blocker -

### AF-INVENTED-LIMIT
Rule: Never add a limit or condition that no rule, control or course directive states. Enforced by frame. Since rEach 0.37.0.
Build ✅ Shipped · Deploy 🟢 Live (0.37.0, 2026-10-06) · Blocker -

### AF-TEST-ASSIST
Rule: During a test never hint, answer, write files, run commands or browse; show each question word for word and clarify its wording only. Enforced by test mode. Since rEach 0.37.0.
Build ✅ Shipped · Deploy 🟢 Live (0.37.0, 2026-10-06) · Blocker -

## Polispec migration — 0.47.0

Build: implemented and locally verified. Deploy: merged into main (pushed) and installed locally in Codex; student stable rollout and host-ledger activation pending. This entry does not re-audit the older registry totals.

- Thirteen existing engineering directives now have one canonical policy source, compiled runtime data, and generated readable views.
- Native enforcement bindings, four declarative control predicates, and advisory guidance have explicit coverage modes. Doctor and the pre-push gate detect artifact/view drift and missing guard bindings.
- Course settings and directives are normalized from the existing Teach package with separate authority; no private bodies or student data enter the public policy.
- Instructor-owned wellbeing, precedence, and channel policy remains in its pinned control contract, declared by digest in the application policy.
- `reach policy` reports authorities and coverage without exposing private content. Damaged installed policy refuses governed mutations while recovery and support remain available.
- The development policy carries persona model/effort bounds. CI checks the exact planned test commit, and stable promotion is operator-only.

Student-first audit: learning and assignment ownership are preserved; student agency and authored answers remain unchanged; wellbeing/support precedence stays with Teach; no new private-data disclosure; Ruby 2.6 and offline support remain; existing refusals retain their recovery routes; no work or receipt is deleted; reinstall/sync restores the appropriate policy. Existing native guards are retained, not replaced by model judgment. Hookless-host and planned NOTICE limitations remain as previously documented.

No tests were added under NOTEST. Validation evidence and any release blockers are recorded in the change history; a policy declaration is not proof that its prose is fully enforced.

Verification on 2026-10-08: plugin package/check and policy drift checks report zero findings. The existing Linux artifact smoke produced 12 passes, one doctor failure, and three skips on both baseline b0df42e and candidate c9cc74e. The shared failure lists R-DOC-CODEX, R-DOC-BRAIN-PLANES, and R-DOC-SUBSCRIBE; runtime download checks were skipped, and the macOS-only sandbox check was inapplicable. Later adapter changes preserve serialization bytes and use only course-supplied enforcement pointers; policy validation and the deterministic secret scan pass. Full model release audit and cross-platform runs are separate evidence. The release gate reports existing Teach/rEach wire alignment and alarm findings; the current operator lease is reported by the gate, not a clean-release verdict.

Local installation on 2026-10-08: rplugin check and doctor report zero findings; reach policy reports 13 directives, 49 native bindings, four declarative controls, four advisory entries, and no policy problems. The local corpus index was rebuilt and six derived embeddings of already-retired sources received retirement markers through the corpus API; source records and journal history were preserved. The full model audit was rerun after packaging corrections: no high security finding in that run, with existing fleet alarms blocking the overall release gate and public-documentation warnings retained for review. The development policy remains versioned for host-side resolution; its paths are generic home-relative defaults and its roster is development configuration, not student policy. Stable was not moved, and no matching formal verifier exists for this change in the local attestation corpus.

Publication status: the main push was refused at 2026-10-09T02:23:39Z by the existing KNOWN-ALARM and INST-FLAP checks, with no active reach lease. main was pushed at 2eac996 on 2026-10-09 under a reach gate lease (rEach now holds its own gate app); the gate still reported KNOWN-ALARM and INST-FLAP. No release was created and stable was not moved.

## Security and privacy audit remediation — 0.47.3

Fixes all ten findings of the 2026-10-08 audit (~/rstack/FINDINGS.md). F01 private tool calls and extracurricular reads
are withheld from transcripts; F02 every collector reads owned files through Reach::SafeFiles; F03 credential-shaped text
is redacted before storage and upload; F04 consent fails closed without proof the question was shown; F05 profile
sharing needs a native one-use consent; F06 local transcript retention, opt-in auto export and `reach transcripts
forget` (server half: Teach 0.80.4 STD-TRANSCRIPT-RETENTION); F07 import approval bound to content digests; F08
updates pinned to the discovered commit; F09 Gemfile.lock patched and the Ruby 2.6 suite lock retired; F10 bounded
JSON, ZIP, tar and response processing.

Student-first audit:
1. Learning: n/a, no coaching or assignment behavior changed.
2. Agency and honesty: yes, profile sharing and forgetting are asked by Reach in plain words, and PRIVACY.md states every copy and period.
3. Wellbeing and safety: yes, support and wellbeing paths are untouched; no new alarms.
4. Privacy and dignity: yes, private profile, memory, extracurricular files and credentials no longer leave the device, and copies expire.
5. Fairness and access: partly, Hermes cannot answer a consent question outside a captured assignment session (fails closed), and Ruby 2.6 to 3.1 computers run local checks on the auto-installed runtime kit.
6. Friction: yes, one consent question only where the student's data leaves the computer.
7. Failure: yes, refusals delete nothing and say what to do; a mismatched update stays on the installed version.
8. Recovery: partial, forgetting and expiry are irreversible by design; nothing is deleted before the course ends.

Verification on 2026-10-09: each finding's acceptance was exercised with throwaway scripts against the real modules
(temporary HOME, REACH_OFFLINE=1, synthetic data), then re-run together on the merged tree: all passed. A real GitHub
`archive/<sha>.zip` carries the commit as its ZIP comment. rplugin check, install and doctor (scratch HOME) report zero
findings; `tools/policy.rb check` is ok. Not verified: a Ruby 2.6.10 interpreter run, a live Teach round trip, Windows
and macOS hosts.

Build ✅ Built · Deploy ⬜ Not released (needs Teach 0.80.4 live first: CMP-WIRE-LIVE) · Blocker Human (Teach stable promotion, rEach release)

## Environments file — 0.49.2

rEach 0.49.2 moves the environments out of `specs/polispec/policy.yml` into `specs/polispec/environments.yml`, adding audience, exposure, operators, rollback, freezes and notes for each environment. polispec renders the `[ENVS]` row in AGENTS.md and `.agents/directives/envs.md`, and the plugin manifest declares `serves: real_users`. No runtime behavior changes. Verified with `polispec validate`, merge parity against the old inline block, `polispec agents render --check` and `rplugin check reach`.

Build ✅ Built · Deploy ⚪ Not deployed (main only) · Blocker Human (promote to test, then `polispec promote reach --to stable`)

## Canary update channel and promotion hop — 0.50.0

rEach 0.50.0 adds the `canary` update channel for opted-in students and the polispec hop that feeds it. `updates.channel` (or `REACH_UPDATE_CHANNEL`) selects stable or canary; setup records canary from a `#canary` or `@canary` harness source; the updater's ceiling is the highest version tag on the channel branch's tip, falls back to stable with a log line when origin has no canary branch, and never downgrades. `reach doctor` prints the channel and its ceiling. `specs/polispec/environments.yml` declares the canary env and `promotion.to_canary` (from test, operator, G-GATE, G-TESTED, 24-hour G-SOAK, G-RCHECK, G-RDOCTOR, F-CLASS, F-DUE); `to_stable` keeps `from: test` and gains F-CLASS and F-DUE. No student is in the ring and no canary branch exists until the operator's first `polispec promote reach --to canary`.

Build ✅ Built · Deploy ⚪ Not deployed (branch canary-ring only) · Blocker Human (land on main, promote to test, create canary)

## Recovery checkpoint for approved main fixes — 0.50.10

The approved fixes in 0.50.5 through 0.50.9 are built and published on main at c31487e: prompt-hook liveness, continuing after failed passes, reading installed skills through the Codex gate, missing-browser qualification guidance, and resolving the only slice from an MCP server started elsewhere. This checkpoint advances the eight release version declarations so native test promotion can create a new tag instead of rejecting the already tagged 0.50.9. It also carries the approved plugin-cache update prompt fix, preserved from its reviewed commit. Existing tags and releases are retained.

Build ✅ · Deploy 🟣 (native fixture smoke; stable artifact published) · Blocker: Human (student outcome unverified). The recovery checkpoint, approved updater fix, and closeout trailer are published in v0.50.10 at 0f363bc8867e2dea2b76b6b8be7dac516ac6c7f5 on main, test, and stable. Native test deployment dpl_5620455813cd40d27a13 and operator stable deployment dpl_6c27331c726476c79381 have health ok and verified receipts for that source SHA and release tag. Stable promotion remains operator-only. A closeout trailer is eligible only while a fresh successful stable deployment receipt and current stable/tag containment agree; publication to main or test alone does not close an issue or hand. No student stable outcome is claimed, and the older registry entries and totals have not been re-audited.



## Codex root chat working folders and terminal guidance — 0.50.11

Since 0.50.11 a shell tool call with a workdir is judged in that course space. A chat opened at the course root can run an owned slice command with the slice as its working folder; shell-routed patches resolve relative file paths against the same folder. Outside working folders and symlink escapes remain refused, and slice ownership, pace, and active controls still apply. Without a terminal, reach work prints the folder to open as a new chat in Codex, Claude Code, or Hermes and exits without starting the harness.

Verified on 2026-10-11 through the actual Codex gate CLI with synthetic enrollment and workspace JSON payloads: owned writes and relative patches passed; unowned writes, outside and symlink working folders, escaping patches, root writes without a workdir, and wrong-assignment writes were refused. The native nonterminal Codex launch printed the folder and returned 0. These checks ran on Linux with network and background subprocess boundaries; no Windows student session or student outcome was observed.

Build ✅ · Deploy 🟣 (native fixture smoke; stable artifact published) · Blocker: Human (student outcome unverified). Native standby published v0.50.11 at 2e7d89e9d9ca8b8e817fd5c0dd0145b6158de6a8 to main and test; the operator then promoted that release to stable. Test deployment dpl_b6673acdcd3827e7c50c and stable deployment dpl_878e38e83e448dd09c81 have health ok and verified receipts for that source SHA and release tag; the stable receipt was recorded at 2026-10-11T22:47:15Z. All six native test promotion gates passed. Stable promotion remains operator-only. GitHub Latest now points to 0.50.11, verified on 2026-10-11; the earlier Latest hold has ended. No student outcome is claimed. This documentation update does not change the release version or tag, and the older registry totals have not been re-audited.

## Qualification coverage ownership and next action — 0.50.12

The QF-UNCOVERED next action names the assistant as the author of the technical qualification scenarios and directs it to repair the exact missing names and tag, then requalify within the current attempt ladder. Student explanations and contributions remain in the student's own words. The feature and bug skills ask only for a missing business expectation and continue the repair instead of ending with a readiness summary. Coverage stops before behavior checks and supplies no behavior result. Qualification parsing, ownership gates, submission readiness, and ladder limits are unchanged.

Build ✅ (published on main as 0.50.12) · Deploy 🔵 (native test promotion blocked; stable not promoted) · Blocker: Access (installed-plugin doctor gate), Human (corpus maintenance authorization and student session verification). The guidance fix is published at 8a0b94478646495dc457688d3ed5409cadd868e5. Native test promotion stopped before publication at G-RDOCTOR: the installed rEach corpus spool holds eight unadmitted records older than 24 hours. No v0.50.12 test tag or deployment receipt was created; test, stable, and GitHub Latest remain 0.50.11. Synthetic native coverage runs reproduce three missing cases, retain rejection of the wrong tag, and pass coverage only with exact names and the correct tag. No student files or answers were accessed or changed, and no student qualification pass is claimed. The older registry totals have not been re-audited.

Student-first audit: learning preserves the student's business decisions and reflections; agency states the assistant's next action clearly; wellbeing adds no pressure and retains existing human escalation; privacy adds no data collection; fairness uses the same guidance in every harness; friction assigns the technical repair without another student task; failure retains all checks and ladder stops; recovery uses the existing checkpoint and bug flow.

## rEach Sidecar import — 0.51.0

`reach packet import FOLDER` and the `reach_packet` tool bring the work a student did in the rEach Sidecar (the signed offline folder the instructor hands out) into their real workspace: `Reach::Packet` verifies the manifest and the signature against `config.yml` `sidecar.allowed_signers`, matches the student's email and course to the install, checkpoints existing work and keeps any plan or scenario file it replaces under `.reach/before-sidecar-import`, replays the sidecar's checkpoints, copies the owned files, qualify scenarios and plan, records the answers in the student's words (`Reach::Part.import!`, unverifiable by the prompt hook by design), keeps the bundle's offline receipt for `reach submit` as `evidence/sidecar-receipt.json`, and runs `reach check` and `reach qualify`. Skill `reach-sidecar`; standard STD-PACKET-IMPORT.

Build ✅ (on main, 0.51.0) · Deploy 🔵 (not promoted; `sidecar.allowed_signers` carries the live Teach signer line, SHA256:SYdcumMaOSZieVk8ioh8YU8ft7etCR8yyywqEcd3ELM) · Blocker: Human (promotion). Verified on a real scratch install against a scratch course server: a packet built from that server, worked in the packet (start, implementation, two checkpoints, four answers, qualify, bundle), imported with five files, two replayed checkpoints, four answers and the bundle receipt, `reach check` clean, `reach qualify` passed, and the submission carried `evidence/sidecar-receipt.json`; tampered, extended, wrongly signed and unsigned folders refused. The code loads and `reach packet --help` runs on Ruby 2.6.10 in a container. Not covered: a real Windows host (ssh-keygen lookup through PATHEXT is untested there).

Student-first audit: learning keeps the offline work and its history; agency says what came in and leaves submit to the student; wellbeing sends nothing and names the next step on every refusal; privacy reads the student's own folder and writes only their workspace and state; fairness works in every harness through the tool; friction is one command with the folder; failure checkpoints before any overwrite and leaves out a slice without stopping the others; recovery is `reach checkpoint restore`.

## Wait notice for long steps — 0.51.12

Before a step that takes more than a few seconds, the student's assistant tells them roughly how long to expect and what closing the app (or the chat) does, and rEach's own start-of-step messages say it too, so the student hears it when the assistant forgets. Found from the code: qualify (local steps up to 300 s each, the course server's run polled for about 20 s, then pending), submit (the send is bounded by the 25 s tool budget; the outbox is written before the send), update (detached background process, phases resume at the next session start), enroll (the sync after enrolling is a detached background `reach sync`), sync (steps are independent and the outbox persists), sidecar import (checks and qualifies each slice), export import (detached, an interrupted job resumes at the next session start), storage compaction (detached; an interrupted run is reported as failed and loses nothing), the setup probe (about 20 s), the live wait (at most 45 s) and the relocation of rEach's files. Carried by the tool descriptions, `Reach::Guardrails::WAIT_RULE` (slice, course root and extracurricular rules files), the LEAN and QUALIFY directive bodies and eight messages in `locales/en-US.yml`; specified as STD-WAIT-NOTICE in `specs/app.yml`. No new directive and no new alias.

Build ✅ (branch wait-notice, 0.52.11, not pushed) · Deploy 🔵 (not released; reaches an install with the next update and a rules file when rEach next rewrites it) · Blocker: Human (the instructor approves the ship). Verified from the worktree: `ruby tools/policy.rb check` ok, the rendered rules and `tools/list` carry the new text, `reach policy` reports 13 directives. The agent-control baseline and the wire digest are unchanged. Not verified: a live student session, and the real duration of a first-time qualify on a slow computer.

Submit wording: nothing is saved for sending until the yes; after it the outbox entry is written before the send and retried only by `reach sync`; a refusal is shelved and reported by `rejected_notices` (shown by `reach sync` and `reach status` in a terminal and, since 0.52.13, returned by the `reach_sync` and `reach_status` tools); a submit hold keeps the entry queued without a message; so the note says only the receipt means it was received.

Since 0.52.11: the submit note says work that arrives after the due time is marked late (the course server stamps the receipt time and the late flag on arrival), and the compaction note says the detached background run normally carries on if the app closes and, if stopped early, is marked failed at the next session so the student can compact again.

Student-first audit: learning is untouched, the notice only tells the student about a wait; agency tells the student what is happening, how long, and what closing does, in plain words; wellbeing adds no pressure, the wording is calm and blames no one; privacy adds no data and no output beyond text; fairness gives the same note in every harness and for every computer, and says "it can take a while" where the time is unknown; friction adds one or two sentences only before a step that already makes the student wait; failure is now less likely, since a student who knows closing the app stops a step can stay and not lose a try or a submission; recovery states how to carry on (sync again, run qualify again, import again).

## Submit refusals reach the student — 0.52.13

A submission waiting in the outbox is now settled by what Teach answers, not by the absence of an error. Teach answers a refused submission 200 with state `rejected`, and a repeat of an already ingested submission with the stored state, so the states on the submissions route are `ingested`, `rejected`, and on a repeat `received`, `grading`, `graded`, `grade_failed`, `validated`, `orphaned`. `ingested` and the repeat states that follow it are delivered (the receipt is stored), `received` stays queued, and `rejected` or any state rEach does not know is shelved in `outbox/rejected` and reported once as M-SUBMIT-REJECTED-LATER, by `reach sync`, `reach status` and now by the `reach_sync` and `reach_status` tools too, in `text` with `relay_verbatim` true. When the refusal is `not_qualified` and rEach records the slice as Qualified for exactly the current files, the text says rEach and the course server disagree about that check, that nothing is wrong with what the student did, names the qualification id for a `technical_issue` hand, lists the scenarios that passed on the starting copy as a detail for the instructors, and never repeats "run reach qualify" (M-SUBMIT-DISAGREE). Desk issues iss_82eaf112435366c0be60, iss_a6f2164045d4bf11ba36, iss_510d3c5dbccd057b13c0; specified as STD-SUBMIT-REFUSALS in `specs/app.yml` and the `submission.refusals` entry of `reach.spec.yml`.

Build ✅ (branch submit-refusals, 0.52.13, not pushed) · Deploy 🔵 (not released; reaches an install with the next update) · Blocker: Human (the instructor approves the ship). Verified against a scratch install and a stub course server: each state above, the shelved entry and the notice through `reach sync`, `reach status` and both MCP tools. Not verified: a live Teach, a live student session, and whether the session-start context should also carry the notice (it needs a new agent-control channel).

Student-first audit: learning is untouched; agency tells the student at once that a submission was not accepted and why, instead of leaving it silent; wellbeing says nothing is wrong with what they did when the fault is the two systems disagreeing; privacy adds only a qualification id to a hand the student agrees to; fairness gives the same text in every harness; friction removes a loop between Qualified and refused; failure no longer drops a queued submission quietly; recovery names the next step, a hand to the instructors, or submitting again.

## No soak before promotion — 0.52.14

The G-SOAK gates are gone from rEach's polispec policy, by the instructor's decision of 2026-10-14 and until further notice: a sha no longer has to have run healthy on test for 24 hours before `polispec promote reach --to stable` or `--to canary`. Every other gate (G-GATE, G-WIRE-PROD, G-RCHECK, G-RDOCTOR, G-POLICY and G-TESTED) and the freezes still hold both hops. polispec reads the policy from stable, so it takes effect at the first stable promotion that carries 0.52.14; that promotion still needs the soak or `--waive-soak`. `LATEST_SOAK_HOURS` in `tools/stable_promote.rb`, the 24 hours before a published stable tag is eligible for GitHub Latest, is a separate clock and is unchanged. Restoring the soak is two lines in `specs/polispec/policy.yml`.

Build ✅ Built on main (0.52.14) · Deploy 🔵 Pending · Blocker: Human (stable promotion). Verified with `polispec validate policy`, `tools/policy.rb check`, and `polispec agents render`, which re-rendered `.agents/directives/envs.md` without G-SOAK.

## Assignment context in every new chat — 0.54.3

Each new chat, in Claude Code, Codex or any other harness, starts from where the student really is. rEach keeps a record of every chat (`state/threads.json`) and works out the assignment and its phase from the student's saved work, not from any one chat. At the start of the chat it tells the agent the assignment and phase, what changed since the last chat (assignment or phase moved, new results, course material changed), which directives the phase needs, and which course files to read into the chat for that assignment, as tagged in the course's release manifest. Reads are recorded by path, and the prompt gate keeps reminding until every file is read; after a compaction they are read again.

Build ✅ Built on main (0.54.3; 0.54.4 makes threads.json owner-only and checks course file paths and titles before they reach the agent) · Deploy 🔵 (not released; the tags reach students only after AIvoryTower 0.26.0 tags the manifests and the instructor exports and packs with Teach 0.98.2; until then the title fallback applies) · Blocker: Human (course export and pack, promotions). Verified in scratch state with a fabricated enrolment and a scratch-key reference blob: an unenrolled hello was byte-identical to origin/main and wrote no record; an enrolled hello named only the A2-tagged file (a review-only file was held back in the start phase) and the start-phase directives; a second chat named the first and reported assignment, phase, result and material changes; the gate reminded until `reach reference show` (CLI and MCP) recorded the read, and again after a compaction; the kill switch removed every line. Not verified: a real harness session, a real Teach blob, phases past start in a real slice.

Student-first audit: (1) learning yes, the agent reads the instructor's own assignment material before helping; (2) agency yes, nothing is decided for the student and nothing new is asked of them; (3) wellbeing n/a, the crisis path is unchanged; (4) privacy yes, only paths and times are kept, locally; (5) fairness yes, every harness gets the same lines, with session ids where the harness exposes them; (6) friction yes, the student sees nothing, the agent does the reading; (7) failure yes, every step is wrapped and a failure only drops the lines; (8) recovery yes, `REACH_ASSIGNMENT_CONTEXT=0` and deleting `threads.json` reset it.

## Honest enforcement of course directives — 0.54.7

`reach policy` reports a course directive native whenever code enforces it. `Reach::BehaviorPolicy.course_rule` now maps each enforce label to the guard the public tier names for it: `gate:read` to the read gate, `check:*` and `hook:shape` to `reach check`, `ledger` to the ledger, `hook:login` to the login gate and `hook:part` to the submit guard. Any other label stays advisory. The persona states that the privacy answer is always allowed, matching Teach 0.101.5's OPAQUE and G-INTEGRITY-1, which also fixes FUSE, PORTS and FOCUS.

Build ✅ Built on main (0.54.7) · Deploy 🔵 Pending · Blocker: Human (promote Teach and rEach). Verified by rendering Teach 0.101.5's 36 directive rows through rEach's table and course policy: 11 native and 25 advisory rules, every native binding resolves to a real method, FOCUS shows `⚙ none`, and the new G-INTEGRITY-1 exception renders. `tools/policy.rb check`, the persona check, `rplugin check`, install and doctor all came back clean.

## Weighted passes, pattern ledger, probe and fault records — 0.56.0

Before a plan, the scenarios or the code are qualified, the agent writes several candidates from different lenses and rEach scores them from evidence only (instructor API use, ledger matches, the scenarios, the port probe), installs the best and records why. A ledger of generic faulty-work patterns, extendable by a course package, flags known faults at check time with a remedy. A probe flags scenarios that would still pass if a required port answered something else. Every failed qualification leaves a scrubbed fault record that is sent to Teach in rate-limited batches. Specified as `STD-WEIGHTED-PASSES`, `STD-PATTERN-LEDGER` and `STD-QUALIFY-FAULTS` in `specs/app.yml`.

Build ✅ (0.56.0 was pushed on the weighted-passes branch, then landed on main at 7e18206 and is carried by 0.56.1 to 0.56.11; not promoted) · Deploy 🔵 (not released; the patterns package and the fault route need the Teach side, and each mode defaults to advise so nothing refuses until the course enforces) · Blocker: Human (Teach slices, wire re-pin, promotions). Verified in a scratch home with a scratch workspace, invented graded names and a fake client: reference builds match no ledger entry, a faulty workspace reports its patterns, candidates are scored, hard-zeroed and picked, qualify refuses uncounted under enforce, and fault records are written, chained and batched. Not verified: Ruby 2.6, a live Teach, a live student session, platform smoke.

Student-first audit: (1) learning yes, the passes make the agent weigh alternatives and each remedy says what to change; (2) agency yes, the pick and the reasons are shown and modes are advise by default; (3) wellbeing n/a; (4) privacy yes, fault records are scrubbed of paths, secrets and identity, hidden checks are left out, they are disclosed in PRIVACY.md, and `REACH_QUALIFY_FAULTS_DISABLE=1` stops the record and the send (the mode settings do not); (5) fairness yes, the same ledger and scoring for every student; (6) friction yes, refusals are uncounted so a student does not lose a try for a process gap; (7) failure yes, every hook is wrapped and an offline send keeps the file; (8) recovery yes, the remedies name the next step and the records can be rebuilt by running qualify again.

## Weighted passes follow-ups — 0.56.1

The port-faking pattern now matches only a fixed fake of a required port that is asserted back; a symbolic link added after scoring can no longer be installed by a pick; fault records drop home-relative and Windows paths; PRIVACY.md discloses the fault record and `REACH_QUALIFY_FAULTS_DISABLE=1` turns it off.

Build ✅ 0.56.1 was built on the weighted-passes branch and landed on main at a61f92a; 0.56.2 to 0.56.11 follow below, and every one is on main, not promoted · Deploy 🔵 Pending · Blocker: Human (Teach re-pin of the wire, promotions). Verified in a scratch home and workspace: a fixed fake asserted back is matched, a lambda fake, an optional-port fake and a transformed fake are not; a link added after scoring makes the pick stale and is not copied; error lines with an absolute path, a home-relative path and a drive-letter path, each through a folder named like a person, keep no path while a workspace-relative path survives; the switch writes and sends nothing. Not verified: Ruby 2.6, a live Teach.

Student-first audit: privacy improves, the record is disclosed and can be turned off; friction improves, a compliant scenario is no longer ruled out; the other six answers are unchanged from 0.56.0.

Patch lines (all on main, not promoted; each verified in a scratch home and workspace, none on a live Teach or Ruby 2.6):
- 0.56.2: the home-path mask is built by concatenating two parts instead of one interpolated string (a refactor); no behaviour change.
- 0.56.3: the path scrub no longer depends on the characters in folder names; wire revision 2026-10-21c lists the `faked_port_echo` kind; the PRIVACY.md bullet lists the remaining non-personal fields.
- 0.56.4: `REACH_ENV_REPORT_DISABLE=1` blanks the environment fields of the fault record (wire revision 2026-10-21d); scenario names go through the scrub.
- 0.56.5: a pick saves the existing scenarios, step files and plan in its checkpoint, and a restore brings them back byte-identical; fault records are written and sent only with an identity scrubber and are scrubbed again before every send.
- 0.56.6: the scrub also drops `../` escapes and `file://` addresses; pattern-match file names are de-identified; checkpoint extras are restored only for the plan and the qualify folders.
- 0.56.7: PRIVACY.md names the cutout, slice and assignment; course-supplied patterns run under a 2-second budget each, and a pattern that stalls is skipped with a `pattern_timeout` warning while the run continues.
- 0.56.8: a pick and a checkpoint restore refuse to touch `qualify` or `.reach` folders that are links and delete nothing; fault-record locations are normalised and dropped for hidden findings; the specs (wire revision 2026-10-21e) say an error line or step text can quote one failing line.
- 0.56.9: a pick checks every target path of the winning candidate for links and refuses before writing or deleting anything.
- 0.56.10: a stored fault record is blanked again at send time when `REACH_ENV_REPORT_DISABLE=1` is set by then; PRIVACY.md lists every field of the record.
- 0.56.11: the path scrub consumes any character up to the last folder separator on the line, so apostrophes, quotes and brackets in folder names leave nothing behind.
- 0.60.2: the three fixes parked on the weighted-passes branch as 0.56.12 land on main: the fault record's home-folder replacement matches whole path segments only; every course-pattern kind honours its 2-second budget; PRIVACY.md lists the probe rows; sent fault records are deleted from the assignment folder while the id chain carries on. Built on main, not promoted. Verified in a scratch home and workspace, not on a live Teach or Ruby 2.6.

## Self-update and Windows qualification repair — 0.56.16

Build: ✅ implemented and verified on fixtures. Hosted run 39526045138 passed all five OS legs; the subsequent startup correction passed an isolated cache-copy scheduling exercise. Deploy: 🔵 not released to students. A full remote qualification roundtrip and real harness CLI refresh remain unverified. No new rStack wire is introduced: scheduling and update state use the existing plugin-owned paths, and qualification uses the existing versioned Teach API.

Student-first audit:

1. Learning: qualification still requires the course server’s actual checks.
2. Agency and honesty: unavailable local checks report their cause and never claim a pass.
3. Wellbeing and safety: existing support and distress handling are unchanged.
4. Privacy and dignity: this change adds no collected or transmitted student data.
5. Fairness and access: Windows avoids native gem compilation and can continue to remote qualification.
6. Friction: background updates cover missing hooks; unavailable local tools do not end qualification.
7. Failure: work is retained, and an unavailable server stays pending rather than passing.
8. Recovery: existing runtime reinstall and update rollback paths remain available.

Promotion smoke isolation — 0.56.17: the fixture runner clears the inherited CODEX_SANDBOX_NETWORK_DISABLED hint for its child commands, so a health check launched by Codex can contact the fixture. This changes no application networking or Polispec gate. Build: implemented; promotion health verification pending. Deploy: not released to students.

## Guided learner presentation — 0.58.0

**Build: 🟡 Partial. Deploy: 🔵 Built, not enabled in the student stable release. Blocker: Access — native harness observation; Human — stable promotion.**

The compiled Polispec guided-learner catalog supplies six canonical policies: no code disclosure, no student terminal handoffs (including setup), no implementation disclosures, released-assignment scope, plain-language coaching, and essential transparency. rEach injects their context and applies explicit-pattern checks through its own adapter, with no Polispec or rStack runtime dependency. Claude Code MessageDisplay buffers whole assistant messages and replaces violating text on screen; its host still fails open on hook errors or timeouts, and original transcripts, verbose mode, and tool output remain outside the display filter. Claude Code and Codex Stop can request a bounded correction after a reply; other harnesses receive advisory context. Pattern checks do not establish complete semantic enforcement, and generated hook configuration is not proof that an installed harness executes it. `reach hook coverage` reports these limits.

Student-first audit: Learning — yes, preserves assignment reasoning and removes technical distraction. Agency and honesty — yes, business decisions and essential disclosures remain explicit. Wellbeing and safety — yes, crisis support and instructor help remain available without penalties. Privacy and dignity — yes, no external classifier or raw rejected text in audit events. Fairness and access — yes with disclosed native coverage differences; every supported harness receives guidance. Friction — yes, the agent handles technical work and setup failure offers instructor help. Failure — yes, presentation controls do not change work, grades, or consent requirements. Recovery — yes, bounded correction and existing checkpoint and release rollback paths.

Wiring: no new service, network call, corpus, schedule, or direct rStack binding. Policy compilation is a build-time Polispec CLI contract. Native end-to-end enforcement remains unverified.

Verification for this candidate: policy validation and catalog drift check pass; package generation is current; source package check and refreshed local installation doctor report zero findings. Direct isolated hook events exercised whole-message buffering, split terminal handoffs, ordinary business and privacy replies, malformed events, bounded correction, and stalled stdin. Independent review findings were corrected and rechecked. Native harness execution and student stable delivery remain unverified. No new tests were written.

Rollout: 0.58.0 is on main and test (7b0211b); all promotion gates and test health passed. Local install check and doctor have zero findings. Student stable is unchanged. The release gate used an existing operator lease and still reports operational backup/alarm findings and two entropy hits on nonsecret generated policy data; these are not reported as clean.

## Panel preview — 0.59.0

**Build: ✅ Shipped. Deploy: 🟢 Live on stable since v0.59.2 (published release, 2026-10-22). Blocker: Engineering — a panel kit carries the practice screen only when Grokit holds a current recording for its module.**

`reach preview` and the reach_preview tool (`STD-PREVIEW`, `lib/reach/preview.rb`) show the panel slice a student is building in their own browser, the way qualify's browser sees it. The slice's qualify run directory is assembled as qualify does, and `lib/reach/kit/preview_server.rb` serves Grokit's own practice app with the course's recorded practice data on 127.0.0.1 in the background, under the kit Ruby. The slice's owned `.svelte` files are read from the workspace on every load, so a saved change shows on refresh. rEach opens the student's default browser and returns the address. The preview stops after 30 idle minutes, on `reach preview stop`, or when another slice is previewed. `--screenshot` (`lib/reach/kit/preview_shot.rb`) saves a PNG with the console errors and failed requests the browser saw, so the agent can look at a rendering problem itself. A backend slice, or a panel kit without the practice screen, is refused in plain words. Origin: a student's agent reported a "local preview failure" on the A2 records panel (fixed in 0.58.1); Sven asked for a realistic way to render the work.

Student-first audit: Learning — yes, the student sees what their decisions produced, in practice data, without reading code. Agency and honesty — yes, the message says it is practice data and not the graded run, and a preview is never a qualification. Wellbeing and safety — yes, nothing is sent and no attempt is spent. Privacy and dignity — yes, it answers only this computer's own address and Host, and reads only the slice's own panel files. Fairness and access — yes, it uses the browser qualify already installs; where the practice screen is missing it says so instead of failing.

Wiring: no new service, network call, corpus or rStack binding. It reuses qualify's run directory, kit gems and Chrome, and emits one `command` debug event per start.

Verification on 2026-10-21, isolated rEach home, real Chrome, a records.a2s1 panel workspace built from Grokit v0.10.1's own qualify kit with a student's real panel file: start in 14.6 s with the state file at 0600; `/records` 200 and a foreign Host 403; an edit to the owned file served on the next load; a second start reused the server; the screenshot found the panel, wrote the PNG and reported the one failing call (`records/examples` 500 on that older Grokit, which qualify would hit too); stop ended the server; a stale state whose pid belonged to an unrelated process left that process alive; a backend slice and a panel without the practice screen were refused with their messages; with a 35 s idle limit the server exited by itself after 57 s; through the CLI the command is listed in help and is locked until enrollment, like qualify. After the release audit: the keyed address answered 303 with an HttpOnly, SameSite=Strict cookie, then 200 with it, and 403 without it, with a wrong key or from a foreign Host (live sources too); the opener refused an address with a user part; the log is 0600.

## Pattern warnings no longer block submit — 0.59.1

**Build: ✅ Shipped. Deploy: 🟢 Live on stable since v0.59.2 (published release, 2026-10-22).**

Two fixes to the pattern ledger (W-QUAL-PATTERN-1, STD-CHECK-BEFORE-SUBMIT). P-HARDCODED-EXPECTED now treats a value as stated when the operation schema in `api/slice-api.json` or `contract/README.md` states it as a whole token, so a module that returns its contract's labels is not flagged. `reach submit` now follows `qualify.ledger.mode` for CK-PATTERN findings: under advise, the default, they are shown and never refuse; under enforce only a block match counts toward the check gate.

Student-first audit: Agency and honesty — yes, a student whose work passed every graded case can submit it, and pattern warnings are still shown to them. Learning — yes, a value the student really hardcoded is still flagged.

Wiring: none. No new service, call, file or binding.

Verification on 2026-10-22, from a student's module and Grokit 32c036a's policy.a2s1 slice API, with scenarios that assert the three statuses:
- On 0.59.0, P-HARDCODED-EXPECTED matched lines 11, 14 and 16, as the student reported. The submit preconditions then refused with M-SUBMIT-FIX-FIRST and next with M-SUBMIT-BLOCKED-CHECK.
- On 0.59.1 there were no matches, and both attempts passed.
- An invented hardcoded value that no contract states is still matched. So is a hardcoded `30` when the contract only mentions `2030`, because contract values count only as whole tokens.
- A block pattern (P-PORT-STANDIN) refuses submit under enforce, then raises the hand, and does not refuse under advise.

## Candidate passes work on a fresh module — 0.59.2

**Build: ✅ Shipped. Deploy: 🟢 Live on stable at v0.59.2 (published release, 2026-10-22).**

Fixes to the candidate passes (W-QUAL-PASSES-1) and the shell gate:
- A scenarios candidate is judged on its local run only once the module is no longer the starting copy. The check now ignores rEach's own mark line and the README, so an untouched module counts as the starting copy again.
- A local_pass hard zero names the failing scenarios, the step and the error.
- The gate lets the agent create the candidate folders the packet names.
- A read-only `sed` with a regex address is no longer taken for a path outside the slice. A script with `r`, `w` or `e` is still checked as before, in every kind of space.

Student-first audit: Agency and honesty — yes, the passes stop ruling out every candidate for a reason that has nothing to do with the student's work, and the agent can now see and explain why a candidate failed. Integrity — the vault, keys, files outside the slice and in-place edits stay refused.

Wiring: none. No new service, call, file or binding.

Verification on 2026-10-22:
- Starting copy: from a student's stamped module and the packaged Grokit stub, `code_is_starting_copy?` answered false on 0.59.1, which is the bug. On 0.59.2 it answers true, and false once the module is edited.
- Gate: driving `Reach::Gate.shell` on a scratch slice, `mkdir .reach/passes/<point>/<n>` and regex-address `sed` reads are allowed. The point folder, folder 9, unknown points, `sed -i`, `sed -f` with a file outside, scripts with `r` or `w` to an outside file (in a slice and in the extracurricular folder), and vault reads are still refused.
- Diagnostics: a cucumber JSON report rendered through `Suite.report_rows` gives the scenario, step and error in the reason.
- Not run: a full `reach passes score` with the kit's gems.

## Rolling cutoff for owed assignments — 0.60.0

**Build: ✅ Shipped. Deploy: 🟢 Live on stable since v0.60.1 (published release, 2026-10-22), with Teach 0.107.0 on stable. Blocker: —. Teach's minimum accepted rEach version (0.60.1) is checked only at enrollment, so an install enrolled on an older rEach keeps describing owed work as late until it updates itself from the stable release; Teach does not mark that work late either way.**

Teach 0.107.0 may add `rolling_until` to an entry of `status.late_assignments` (wire revision 2026-10-22a) when the instructor lets students who have not submitted an assignment submit it, not late, until a cutoff. Inside that window rEach treats the assignment as open work: no late notice at session start, on prompts or in reach status, no `late_work` hand, and no "marked late" wording in the submit ask. reach status and the greeting name the cutoff. Entries without `rolling_until` behave as before, and after the cutoff Teach drops the entry, so the work reads as late again.

Student-first audit: Agency and honesty — yes, a student the instructor has excused from the deadline is no longer told their work is late. Integrity — unchanged: Teach still decides lateness on arrival, and an on-record slice still cannot be submitted again after the due time.

Wiring: none. One optional field read from the existing status payload.

Verification on 2026-10-22, against a scratch Reach home with a hand-built status cache (A1 with `rolling_until`, A2 without):
- Inside the window A1 is not late, has no notice and spawns no hand on a write. A2 is late, with today's notice and a `late_work` hand.
- After the cutoff A1 is late again.
- The status and greeting lines show the rolling text for A1 and the unchanged late text for A2.
- Not run: against a live Teach 0.107.0.

## Injected directives as polispec surfaces — 0.62.0

Every rule rEach puts in an agent's context has one canonical directive. Every other place a rule appears is rendered from its directive and checked for drift and for restatement. These places are the persona, the skills, the Antigravity rules, the agent-control framing, the wrapper text, the workspace rules files, and this repository's `AGENTS.md`.

Course rules come from Teach's compiled course policy (`course_policy.json`, wire revision 2026-10-22c), and QUALIFY and CODEFILE carry the engineering ones the course used to restate. Grokit's 70 copied cutout guardrails are gone.

Every session sees every row, and a directive's full text arrives once, when its condition first applies. Harnesses without hooks get the full rules file (`harness.rules_file`, default `auto`).

**Build: ✅ On main (0.62.0, Polispec 0.37.4, after 0.61.0). Deploy: 🔵 Pending. Blocker: Human — the Teach course-policy slice must be deployed and pinned to wire 2026-10-22c first, then the promotions (`polispec promote reach --to test`, then the operator's `--to stable`), and later Teach's minimum accepted rEach version raised to 0.62.0 to retire `directives.yml`.**

Verified in a scratch home with Teach's rendered package:

- A package with `course_policy.json` gives 15 course rows and the cutout overlay. A legacy package gives the same set minus RECEIPT and AIPOLICY.
- A simulated write injects each matching body once per session.
- `auto` picks the stub only after a harness's hooks have run.
- A one-byte persona edit fails both `tools/policy.rb check` and the runtime check.
- `tools/policy.rb build` and `check` pass with the installed Polispec, and `rplugin check` reports 0 findings.

Student-first audit:

1. Learning: yes. The same rules reach every harness.
2. Agency: yes. The privacy summary stays always allowed, and the student is told what the agent follows.
3. Wellbeing: yes. The crisis rule stays first in every rules file and in FOCUS, duplicated on purpose.
4. Privacy: yes. Course bodies travel as hashes and are fetched only through the authenticated route, and the session record holds opcodes only.
5. Fairness: yes. A harness without hooks gets the full text instead of less.
6. Friction: improves. Where hooks work, the stub is about 6 KB instead of 27 KB.
7. Failure: safe. An old package, or a failed body fetch, falls back to the rows.
8. Recovery: yes. `harness.rules_file` switches the form, and the files are rewritten at the next launch.

## Uninstall — 0.63.0

A student, or the agent working for them in Claude Code, Codex, Antigravity or Hermes, removes rEach from the computer with one command, `reach uninstall` (`UNINSTALL.md`, skill `reach-uninstall`). It deletes rEach's own folders (`~/reach-work/.reach-home` and the legacy `~/.reach`), the background update job, rEach's entries in the four apps, rEach's edits to Codex's settings file, and the files rEach generated inside the work folders (hook, MCP and rules files), and it makes the files rEach locked read-only editable again. It never touches the student's work: `deliverables`, `extracurricular`, older course folders, anything the student wrote, and the `.reach` folder inside each assignment slice (the plan, receipts and kept copies) stay as they are. A generated file the student changed is edited or left and listed, never deleted.

The student confirms with rEach's own question, which names what goes, what stays, the unsent items that will be lost and whether the course server will be told. Their typed yes is recorded like every other rEach consent. A copy of the receipts and grade records is saved to `~/Downloads/rEach-receipts-<date>` first, and nothing is deleted if that copy fails. The extra copies of work files that rEach keeps outside `reach-work` stay unless the student asks for them to go. With the recorded yes, rEach also tells the course server that this copy is gone (`W-API-INSTALL-WITHDRAW`, wire revision 2026-10-22d), once, and finishes the removal whatever the answer. A standalone script, `scripts/reach-uninstall`, does the same when rEach will not start, and `plan` shows what it would remove without changing anything.

**Build: ✅ On main (0.63.0, 36ab6c8). Deploy: 🔵 On test with 0.63.1 (a9053ee, 2026-10-22), with Teach 0.107.5 on its test; not on stable. Blocker: Human — the operator's `polispec promote teach --to stable` first (until the live course server serves the withdrawal route, rEach says it could not tell the course server and removes itself anyway), then `polispec promote reach --to stable`.**

Verified on 2026-10-22 on Linux, only in scratch homes, with stub `claude`, `codex`, `agy`, `hermes` and `systemctl`, and never against the real install:
- Plan changes nothing on disk. Apply without a yes exits 3 and removes nothing. A second apply reports that rEach is not installed.
- With a scratch course server running the real Teach code over loopback HTTP: the first run prints the question, the recorded yes makes the second run send one signed request, Teach answers 200 and marks that install withdrawn, and keeps the student and roster rows. The home folder is fully gone afterwards. Work files are byte-identical (sha256) apart from the generated `.mcp.json`, the slice's `.reach` folder is untouched, and a locked file and its folder are writable again.
- Refusals: a home path that is the work folder, the user folder, a folder named `.reach` holding unrelated files, or one that holds `deliverables`; a symlink home is unlinked and its target untouched; the kill switch exits 2.
- A receipts-copy failure leaves both homes in place and exits 1. A rEach-generated file the student changed is edited or left and listed.
- A course server answer of revoked, forbidden, not found, rate limited or server error, a closed port and offline each finish the uninstall and say the server was not told, with at most one retry.
- Codex settings: restored byte for byte from the baseline in LF and CRLF-with-BOM files, student changes kept, a form the scanner rejects is left untouched and listed.
- The `claude` and `codex` removal commands match those programs' own help output. `rplugin check` and `tools/policy.rb check` report 0 findings.
- Not run: Windows (registry, task scheduler, user PATH, deferred removal), macOS (LaunchAgent), real Antigravity or Hermes (`hermes profile delete` is unverified), a real Codex or Claude plugin removal, and a live course server. The Windows user PATH is rewritten only when no entry in it uses a % variable; otherwise rEach lists its own entries under "left for you" and leaves the list alone. The Hermes configuration is rewritten without its comments, with a backup beside it.

Wiring: one signed request to the course server through the shared client (token bucket, breaker, timeouts, one jittered retry, `REACH_OFFLINE`), skipped by `--no-teach` and `REACH_UNINSTALL_TELL_TEACH=0`; no other port, library or rStack path. `REACH_UNINSTALL_KILL_SWITCH=1` stops the verb and the script.

Student-first audit:

1. Learning: n/a. Nothing in the course path changes, and the student's plan, receipts and files stay.
2. Agency and honesty: yes. The question names what goes and what stays in plain words, only the student's own typed yes counts, and `--yes` is refused while enrolled.
3. Wellbeing and safety: yes. No pressure or alarm is added; the closing text says what to do next.
4. Privacy and dignity: yes. The receipts copy holds no key, vault or transcript, and the server is told only that this install is gone.
5. Fairness and access: yes. The same question and result on every app and computer; Windows and macOS are unverified here and say so.
6. Friction: yes. One command and one yes; the receipts copy and the server notice need no extra step.
7. Failure: safe. Nothing is deleted if the receipts copy fails, every refusal is listed, and a server that cannot be reached never blocks the removal. The one loss is unsent items, named in the question.
8. Recovery: yes. The student installs rEach again and enrolls again with no instructor step; their work, plan and receipts are still there and the kept extra copies let a later install find them.

## Cutout message block — 0.66.0

**Build: ✅ Built in 0.66.0. Deploy: 🟡 On test at v0.66.0 (prm_15dbc91500460af49681); not on stable. Students must not be told about the block until Sven moves Teach's Grokit root to Grokit 0.12.0 and the practice set is rebuilt with Dovetail 0.5.0.**

A panel slice's owned cutout `.svelte` may carry one Dovetail 0.5.0 message block: `messages('<cutout_id>', {...})` in a `<script module lang="ts">`, with strict JSON, at most 40 keys per locale, values of at most 200 characters, en-US required and other locales falling back to en-US. `reach check` reports a bad block as CK-MESSAGES, and P-I18N-INVENTED counts the block's keys as known (STD-CUTOUT-MESSAGES). The owned files and the wire do not change.

Verified on 2026-10-28 with sixteen scratch samples (good, `context="module"`, a "#123" label, and one per problem code): each bad sample gives exactly its CK-MESSAGES code and the good ones give none. A scratch workspace's P-I18N-INVENTED flags only the invented key. Grokit's real `ExtractIdeaTitle.svelte`, with and without a block, gives no finding. Teach's and Dovetail's copies of the parser are identical apart from the module name. Not run: Ruby 2.6 (the code was checked by reading it), and the platform smoke.

Student-first audit:

1. Learning: yes. The student writes the words their panel shows instead of bending the design to the shared list.
2. Agency and honesty: yes. The wording sits in a file the student owns, and a bad block is named with its fix.
3. Wellbeing and safety: n/a. Nothing about distress, deadlines or messages to students changes.
4. Privacy and dignity: yes. The block holds interface labels only, and nothing new is collected.
5. Fairness and access: yes. The same block and limits apply on every computer and AI app, and other locales fall back to en-US.
6. Friction: yes. There is no new owned file and no requalification, and CK-MESSAGES says what to fix.
7. Failure: yes, with an ordering condition. A cutout with a block fails to load in a practice app built with an older Dovetail, so the announcement waits for the rebuild. A student who writes no block is unaffected.
8. Recovery: yes. Deleting or correcting the block restores the earlier behaviour.
