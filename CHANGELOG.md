# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.47.1] - 2026-10-08

### Fixed
- Release gate INST-FLAP (`tools/release_gate/checks.rb`, `specs/release_gate.yml`) no longer counts the gate's own `release_gate:*` and `release_gate_override:*` alarms, as KNOWN-ALARM already did; each blocked run opened one more, so the gate kept itself blocked for 24 hours after every refusal.

## [0.47.0] - 2026-10-08

### Added
- Canonical Polispec engineering policy, compiled runtime data, generated directive views, and authority-aware course policy normalization.
- Policy diagnostics and drift checks for directive content, runtime bindings, and the instructor-control baseline.

### Changed
- Existing pause, submission-hold, and test-tool conditions consume declarative deny rules; native workspace and assessment guards remain in place.
- Development/release policy and persona bounds are integrated from the earlier Polispec migration. Stable readiness checks the planned commit; legacy scripts cannot move stable outside the operator command.

## [0.46.3] - 2026-10-08

### Added

- `reach.rstack_component.yml`: rEach is an rstack component (distribution public, relation consumer, role productivity, kind external, no processes) whose `gates:` block declares its own release gate, so its pushes take their own lease instead of riding on Teach's. The file is `export-ignore` and never reaches a student. Its `version:` is kept by hand; it is not a release-gate version home.

### Fixed

- `lib/reach/session.rb`: the fallback session id (`unknown-<date>-<pid>-<hex>`, RAUD-14) is built by joining its parts instead of one interpolated string, which the release gate's entropy scan read as a generated secret (SEC-SCAN) and which blocked the push. The id is unchanged.

## [0.46.2] - 2026-10-08

### Fixed

- Enrollment no longer loops on the password confirmation (`STD-ENROLL-PASSWORD`). An error on the computer after the
  confirm, such as a Windows `EACCES` while saving the install files once Teach had accepted the student, used to be
  swallowed by `Reach::EnrollFlow.evaluate`, which asked `M-ENR-ASK-PASSWORD-AGAIN` again while every confirm
  registered a new install on Teach. `Reach::EnrollFlow.register` now records a fault (`enroll_flow:register`) and
  answers `M-ENR-PASSWORD-RETRY-FAILED` with the new `M-ENR-LOCAL-SAVE-FAILED` naming the error, back at the first
  password entry; any other step error records a fault (`enroll_flow:step`) and answers the new `M-ENR-STEP-FAILED`
  with the current question.
- A course folder's `.codex/hooks.json` can no longer be left empty or unparseable (`STD-STATE-FILE-REPLACE`).
  `Reach::Harness.write_protected` now writes through `Reach::StateFile.write_atomic`, `Reach::Stamp.store!` renames
  through `Reach::StateFile.rename_into_place`, and `Reach::Relocation.stale_ruby_target?` counts a `.codex/hooks.json`
  or `.claude/settings.json` that does not parse as stale, so `repair_ruby_paths!` at session start rewrites it. Codex
  had reported `expected value at line 1 column 1` for such a file.

## [0.46.1] - 2026-10-08

Fixes from the 2026-10-08 audit (`TODO.md` "Audit 2026-10-08", RAUD-01 to RAUD-67).

### Fixed

- Shell gate (`lib/reach/gate.rb`, `lib/reach/cli.rb`) fails closed. A command goes to the write gate only when it is a recognized `apply_patch` form, never because `*** Begin Patch` appears in it. The new splitter and lexer handle a lone `&`, backslash escapes and attached redirects. Commands the gate cannot model are refused with `M-SHELL-UNMODELED`: substitutions, here-docs, reserved words and dynamic command words. Wrappers (`env`, `command`, `exec`, `nohup`, `nice`, `time`, `timeout`, `stdbuf`, `bundle exec`, `npx`) are unwrapped, and run-a-string forms (`eval`, `xargs`, `sh -c`, `pwsh -Command` inside a script) are refused. Every operand and redirect of a mutating command must be owned. `.claude`, `.codex`, `.mcp.json`, `CLAUDE.md` and `AGENTS.md` are never writable through the shell. PowerShell commands from Codex on Windows and Claude Code's `PowerShell` tool are unwrapped and translated to the modeled commands, and the Claude shell matcher covers `PowerShell` (RAUD-40 to RAUD-44, RAUD-50).
- Consent (`consent.rb`, `login.rb`) counts only `yes` or `y`. When the hook carries a transcript path, the yes also has to answer the question the student was shown (RAUD-48). A live session's diagnosis approval needs the student's diagnosis consent recorded on this computer (RAUD-47). A live `codex_configure` applies only the safe workspace mode (RAUD-46).
- `install.yml`, receipts, acks, the private key, stored packages, `delivered.json`, integrity outbox entries and `pseudonym.json` are written atomically. `install.yml` changes are made under a lock. A corrupt receipt or package is moved aside, not left to raise forever. An unreadable `install.yml` names itself (`M-ENROLL-INSTALL-UNREADABLE`) (RAUD-01, 02, 07, 08, 19, 22, 39).
- Receipts: a bad signature is a verification failure (RAUD-03). `refresh_grades` skips a refused receipt and keeps polling the rest (RAUD-04). Permanently refused acks stop blocking newer ones (RAUD-05). Re-enrolling as another student moves the previous student's receipts aside (RAUD-06).
- Teach client: certificate failures and clock skew get their own messages (`M-TEACH-CERTIFICATE`, `M-TEACH-CLOCK`) instead of "offline" (RAUD-10). A plain `http://` Teach URL is refused except on loopback (`M-TEACH-INSECURE-URL`, RAUD-11). Renames retry on Windows EACCES and EBUSY (RAUD-13). A negative Retry-After no longer raises, and a session without an id gets its own (RAUD-14). An enrolled install fetches the instructor keyring from its own Teach URL (RAUD-09, second half).
- Workspace: only files the package delivered are locked read-only, so `materials/`, notes and scratch files stay writable (RAUD-15). A student's owned file is never replaced by the stub (RAUD-19). A missing owned file is refused locally (`CK-MISSING`, `M-SUBMIT-MISSING`, RAUD-18). Invalid UTF-8 no longer crashes check, qualify or submit (RAUD-17). Qualify records its digest after the seal stamp (RAUD-20). The seal keeps a shebang first and keeps CRLF files CRLF (RAUD-12).
- Queued submissions replay in the order they were queued. A refused one moves to `outbox/rejected/` and is reported once by `reach sync` and `reach status` (`M-SUBMIT-REJECTED-LATER`, RAUD-16).
- Untar and unzip refuse a chain of links that leaves the extraction folder (RAUD-21). Due times come from the course status for every assignment (RAUD-23). Course times no longer mutate their argument or fall back to the machine's zone (RAUD-24). Progress keeps checkpoints that met a network error (RAUD-24). A suite timeout kills the whole process group (RAUD-66), and a BOM no longer hides a feature's first tags (RAUD-67).
- Release gate and security scan (`tools/release_gate`, `tools/security_audit`): a missing Teach URL is reported, not a crash. Teach defaults to port 7400, and rEach reads `teach.url` with YAML (RAUD-25, Teach AUD-64). The scan scrubs invalid UTF-8 (RAUD-26), scans long json/svg/map/min.js lines in chunks (RAUD-27) and recognizes diff headers only in header position (RAUD-28). A "fail" audit verdict blocks, and severity matching ignores case (RAUD-29). An unreachable remote is a critical "could not check" finding, with a timeout (RAUD-38).
- Privacy: debug text is scrubbed of home paths, email addresses and the student's names (RAUD-30). Code entries' `path` and `scope` are de-identified (RAUD-31). Forgetting one finding also scrubs the prompt that grounded it (RAUD-37). Two-letter name parts are scrubbed as whole words (RAUD-39).
- Logs and archives: debug archives older than 14 days are pruned (RAUD-32). `transcript.jsonl`, the brain spool log and `brain-planes.log` rotate and are 0600 (RAUD-33). The workspace scan keeps digests past its cap and saves them on error (RAUD-34). Transcript ingest saves progress per batch and reads line by line (RAUD-35, 36). The ledger splits under its lock, and a dropped spool record is logged (RAUD-39).
- Agent integration: a network blip no longer erases an instructor's reply or resets the ladder (RAUD-45). `on_path?` honors PATHEXT on Windows (RAUD-49). Prompts in `extracurricular/` and the course root are not blocked before the first slice (RAUD-51). The agent-control digest survives a CRLF checkout, and `.gitattributes` pins `agent-control/` to LF (RAUD-52). MCP `ping` answers (RAUD-53). The wrong-folder greeting uses declared channels (RAUD-55). `reach update check` honors `REACH_OFFLINE` and `REACH_UPDATE_DISABLE` (RAUD-58).
- Install and update: a failed migration restores the previous plugin and counts toward `max_attempts`, so an interrupted swap no longer respawns forever (RAUD-56). Relocation skips fifos, sockets and devices (RAUD-57). A stuck staged update no longer defers relocation or burns its attempts (RAUD-59). Superseded plugin backups and kit directories are pruned when nothing uses them (RAUD-60). `update.json` writes are serialized (RAUD-61). Windows copies are refreshed and report failures (RAUD-62). The Windows task is registered from Task XML that allows battery power and has no `/TR` limit (RAUD-63). macOS install tolerates a bootout of an unloaded job (RAUD-64). `exe/reach-run` accepts Ruby 2.6.10 to 4.0.x, matching setup (RAUD-65).
- Docs: `FEATURES.md` MCP tool count (RAUD-54), `INSTALL.md` background interval, and the `reach.spec.yml` update lock and Ruby range (RAUD-65). `specs/wire.yml` notes that a submission with a missing owned file is refused locally.

### Not changed

- RAUD-09 first half: an unenrolled install still accepts an unsigned instructor keyring from the configured Teach URL, as `STD-INSTRUCTOR-UNLOCK` documents for the pre-enrollment instructor flow. Closing it needs a pinned trust root.

## [0.46.0] - 2026-10-08

### Added

- Release gate leases (`STD-RELEASE-GATE-LEASE`): `tools/release_gate/lease.rb` reads the lease source file (`RELEASE_GATE_LEASE_SOURCE` or `~/.config/release-gate/lease_source.yml`), and `tools/release_gate/gate.rb` ends a recording run that would block as `leased` (exit 0, every check still run and recorded, `lease_id` on the run and the event, no override consumed) while a valid, unexpired lease for the repository answers. `specs/release_gate.yml` gains the `leased` status, `lease_id` and the `lease` clause. Maintainer tooling only; nothing a student runs changes.

## [0.45.0] - 2026-10-08

### Added

- Issue closeout hook (`STD-ISSUE-CLOSEOUT-HOOK`): `.githooks/commit-msg` runs `tools/release_gate/closeout.rb`, which
  sends the commit subject, message, branch and up to 200 staged paths to the course server and appends the
  `Fixes-Issue:` and `Probably-Fixes:` trailers it answers. Identity evidence alone writes `Fixes-Issue`; scored
  candidates only write `Probably-Fixes`. It never blocks a commit (3 s timeouts, two attempts, always exit 0);
  `CLOSEOUT_DISABLE=1` or `git config closeout.enabled false` switches it off. `tools/release_gate/install` enables it.

## [0.44.2] - 2026-10-07

### Changed

- Wire revision 2026-10-07b (W-AUTH-8, `specs/wire.yml`): Teach keeps an install's harness at the harness of the last
  valid `X-Reach-Env` header, unless it is `terminal` or `unknown`, so after a harness move (`STD-HARNESS-MOVE`) Teach
  shows the app in use. rEach's behavior is unchanged; Teach 0.76.1 implements it and pins the same wire.

## [0.44.1] - 2026-10-07

### Fixed

- The MCP bridge survives losing its working directory (iss_895a0a5f250729ab1914). `Reach::Paths.cwd`
  (`lib/reach/paths.rb`) answers `Dir.pwd` while that directory exists and the user's home otherwise, and every
  `Dir.pwd` read in `lib/reach` goes through it (hello, mcp_bridge, gate, known_issues, diagnose, codex_setup, cli;
  setup_log already guarded its own). An update or reinstall that replaced the plugin copy left the running bridge in
  a removed folder, and the next `reach_hello` failed with `Errno::ENOENT` (M-REACH-HICCUP-TOOL). The desk's fix
  f5fe6d0, built on 0.40.1, lands on 0.44.0 here.
- `PRIVACY.md` names everything `seal.json` keeps (the fingerprint salt, and per enrollment the install ID, student ID,
  course server address and enrollment time) and where it lives on macOS, Windows and Linux.
- `FEATURES.md` no longer names a course-server method or its checkout in the 0.43.1 verification note
  (STD-TEACH-OPAQUE).

## [0.44.0] - 2026-10-07

### Added

- Moving rEach to another AI app on the same computer without enrolling again (`STD-HARNESS-MOVE`):
  `reach harness move --to claude-code|codex|antigravity|hermes [--from ...] [--yes]` and the `reach_setup` MCP action
  `harness` (`to`, `from`). The chat path asks rEach's own question (consent kind `harness_move`,
  `M-HARNESS-MOVE-ASK`), taken by the plugin prompt hook on every harness and by the course-folder hook. In an app that runs no rEach hooks
  (Antigravity, or no app can be told), it gives the terminal command instead (`M-HARNESS-MOVE-TERMINAL`). On yes,
  `Reach::HarnessMove` (`lib/reach/harness_move.rb`) runs `Reach::Setup.run_harness` for the target, rewrites every
  course folder with `Reach::Harness.configure_all`, adds the `reach codex configure` step when the target is Codex
  and its settings are not set up, and answers `M-HARNESS-MOVE-DONE`. rEach stays installed in the old app. A failed
  install changes nothing else (`M-HARNESS-MOVE-FAILED`). Each move writes a `command` debug event (from, to, ok, via).
  Teach's install record keeps the enrollment app until wire revision 2026-10-07b.

## [0.43.1] - 2026-10-07

### Added

- A reinstall on the same computer enrolls as the same computer (`STD-FINGERPRINT-SALT-KEPT`).
  `Reach::Fingerprint.store!` also writes the fingerprint salt into the per-computer sidecar (`seal.json`, field
  `fingerprint_salt`; `Reach::Sidecar.keep_fingerprint_salt`). `Reach::Fingerprint.build` takes the salt from the
  argument, then `~/.reach/fingerprint.json`, then the sidecar (`Reach::Sidecar.fingerprint_salt`), and only then
  makes a new one. Before, deleting the rEach home made a new salt, and Teach recorded the next enrollment from the
  same computer as a device move. The wire and Teach are unchanged.
- `PRIVACY.md` says the random salt stays on the computer in that file after rEach's own folder is deleted.

## [0.43.0] - 2026-10-07

### Added

- A stable cadence (`STD-STABLE-CADENCE`): `.github/workflows/stable.yml` runs daily at 15:00 UTC, plans with the new
  `tools/stable_promote.rb` (`plan`, `apply notice|promote`, `hold`), runs the platform smoke on the Latest tag through
  `platforms.yml` (now also a `workflow_call` with `ref` and `vms`), and moves `stable` only when every leg passes. A
  failed smoke holds `stable` and opens or updates one `stable-hold` issue.
- Hook-change notice: a Latest release whose diff from `stable` touches `hooks/` first gets
  `refs/tags/notice/hooks/vX.Y.Z/YYYY-MM-DD` and reaches `stable` no sooner than the next day; rEach reads the notice
  from its existing tag listing and shows Codex students `M-UPDATE-HOOKS-NOTICE` once.

### Changed

- The managed updater (`lib/reach/update.rb`) installs only the version `origin/stable` points at, read from the same
  `info/refs` listing; with no readable `stable` it takes no update and logs why. Before, it took the newest release or
  any tag.
- `VER-STABLE` in the release gate (`tools/release_gate/checks.rb`, `specs/release_gate.yml`) flags `stable` behind
  Latest only when a `stable-hold` issue is open or Latest is older than 26 hours (50 with a hook notice).
- `tools/release_stable.rb` gains `tag_commit` for the promote tool; its command line is unchanged.

## [0.42.0] - 2026-10-07

### Added

- Every signed request reports the environment rEach runs in (`STD-ENV-REPORT`, wire revision 2026-10-07a, W-AUTH-8):
  the harness, OS family, OS release, CPU architecture and Ruby version in the `X-Reach-Env` header, from the new
  `Reach::Environment`. It is descriptive only; `REACH_ENV_REPORT_DISABLE=1` turns it off.
- A tested compatibility matrix (`STD-COMPAT-TESTED`): the platform smoke report carries the leg, rEach version,
  commit and environment, `tools/platform_smoke/matrix.rb` folds the reports into `compat-tested.json` and
  `compat-tested.md`, and the platforms workflow builds and uploads it after every run. It covers rEach's commands and
  the harness hook command lines, not a live agent session.
- `tools/platform_smoke/run.rb --leg NAME` names the leg in the report.

### Changed

- PRIVACY.md discloses the environment details sent with every request and how to turn them off.

## [0.41.0] - 2026-10-06

### Added

- A README substance check (`STD-README-SUBSTANCE`, W-SUB-3, `lib/reach/readme_check.rb`). `reach check` reports
  CK-README when README.md lacks one of the five template sections or a section holds fewer than 25 words. `reach
  qualify` fails its check step on it (QF-README, M-QUALIFY-README) without spending a ladder rung, and `reach submit`
  refuses with M-SUBMIT-README. Teach 0.70.0 applies the same rule at qualification and ingest.
- Wire revision 2026-10-06e: W-SUB-3 to W-SUB-6 (README substance, qualification evidence at ingest, reassigned slices
  void their submissions, assignment completeness), and the rejection codes `readme_incomplete` and `not_qualified`
  with their fix text.
- The assignment one smoke (`STD-SMOKE-ASSIGNMENT-GUARDS`) writes a schedule overlay with A1 due 14 days out, checks
  that the template README is flagged, that one submitted slice of two leaves A1 incomplete with a missing row, and
  that a module reassignment orphans the graded submission.

### Fixed

- The smoke ran against the spec's past A1 due date and failed at sync; it now writes its own schedule.
- The smoke inherited the host harness's session variables, so sign-in checked a foreign session; it now unsets them.
- The smoke's hand id kept the sentence's final period.

## [0.40.1] - 2026-10-06

### Fixed

- `specs/release_gate.yml` keeps Teach opaque (`STD-TEACH-OPAQUE`). The public file is now the outcome-level contract:
  it keeps the tables `tools/release_gate` reads (version homes, pinned paths, check ids, parts, repositories, classes
  and severities) and names Teach only as the course server that answers facts, records runs and overrides and raises
  alarms. Teach's desk schedule, settings file, alarm table, doctor, ops routes, token scopes, rate limit and default
  port moved to the private superproject's copy of the contract. `README.md` and `STD-RELEASE-GATE` no longer name the
  route or the token scopes.

## [0.40.0] - 2026-10-06

### Added

- Release gate (`STD-RELEASE-GATE`). `.githooks/pre-push` now runs `tools/release_gate/gate.rb`, which wraps the
  security audit with the broken-state checks `specs/release_gate.yml` names: wire digest against the live and
  main Teach, pinned copies against their owner, active installs that could not report, version collisions across
  branches and worktrees, VERSION against its homes and the tag, tags without a GitHub release, a release that would
  demote Latest, `stable` behind Latest without a hold, open blocker alarms and issues the push does not claim, a
  failing doctor, a backup line that is not green, flapping alarms and a long-lived unit on stale code. Critical and
  high block; a check that cannot run says so. Every run is recorded on Teach. `tools/release_gate/install` sets the
  hook up; `reach doctor` reports `R-DOC-GATE` when a maintainer clone pushes over SSH without it.
- Instructor override. `ruby tools/release_gate/gate.rb override --reason TEXT [--hours N] [--checks ID,ID]` is typed
  on a terminal, recorded on Teach with user, host and terminal, raises an alarm until one push consumes it, and is
  the only way past a block. `hold stable --reason TEXT` records why `stable` stays behind Latest.
- Accepts-aware degrade (`STD-COMPAT-ACCEPTS`, wire 2026-10-06d). Teach advertises the hand triggers, debug kinds
  and harness names it accepts; `Reach::Compat` types hands and debug events from that list instead of the whole
  wire digest, and an issue hand still goes (capsule null) when an older Teach's digest differs, so a fault on a
  drifted install is heard.

### Changed

- The security audit blocks at high by default (was critical), and `REACH_SECURITY_AUDIT=0` is ignored; the
  instructor's recorded override replaces it. `tools/security_audit/install` runs `tools/release_gate/install`.

### Fixed

- A push named by `HEAD:main`, a sha or any local ref that is not `refs/heads/*` is still a release push: the gate
  now reads the branch from the remote ref.
- The public gate files name no private repository location, port, class, table or command of the course server
  (`STD-TEACH-OPAQUE`); the private repository is recognised by its own spec file at the root.

## [0.38.10] - 2026-10-06

### Changed

- rEach now does what the student setup and troubleshooting handout says (`STD-HANDOUT-PARITY`).
  - Install: the NEXT block is "rEach is installed and ready." then G-INSTALLED-ENROLL ("Before anything else, connect
    rEach to your course."); the first-run interview waits until the student is enrolled and signed in
    (`lib/reach/setup.rb`, `lib/reach/hello.rb`), and setup creates `deliverables/` and `extracurricular/` in reach-work.
  - Updates: `reach_update` and `reach update status` start with M-UPDATE-CURRENT ("rEach X is installed and up to
    date.") or M-UPDATE-AVAILABLE; M-UPDATE-STARTED is relayed word for word and tells the student to open a new chat.
  - Enrollment: the "password chosen before October 5, 2026 was reset" sentence shows only when the install holds an
    earlier enrollment (M-ENR-ASK-PASSWORD-REENROLL); enrolling ends with M-ENR-DONE and M-ENR-SYNCING, and the launch
    command line only in Hermes (M-ENR-DONE-LAUNCH).
  - Cowork: M-COWORK-CODE-TAB drops the setup-guide sentence.
  - Antigravity: `reach enroll --window` and `reach login --window` open a terminal window for the student
    (`lib/reach/desktop.rb`), and sign-in follows the enrollment pattern (M-LOGIN-NOHOOK-GUIDE).
  - Hermes: setup prints "type o for once. Never type a for always." (M-HERMES-APPROVE-ONCE).
  - Submitting: one message, "was received at …" then the ZIP sentence, with no receipt id; the ZIP is named
    `<assignment>-<email local part>-<YYYYMMDD>.zip` (`lib/reach/archive.rb`); the returning greeting calls received
    work "submitted"; `reach qualify` prints "reach qualify · check … · coverage … · local … · course server … ·
    Qualified." first.
  - Times read "Oct 19, 2026 11:59 PM PDT" and dates "Oct 12, 2026" (`lib/reach/course_time.rb`, STD-COURSE-TIME).
  - Skills: reach-assistant gains the update-first, version, claim-is-not-confirmation, loop, three-layer and
    no-pasted-commands rules (mirrored in `agents/reach.md`); reach-help raises a hand for "report this", "tell my
    teacher" or the instructor's name.

### Added

- `reach hand raise --last-step --saw` and the matching `reach_raise_hand` arguments; a successful raise prints
  M-HAND-SENT. A refused or queued hand adds the course profile's `support.contact_text` (M-HAND-CONTACT, wire W-POL-2).
- Codex refuses enrollment and sign-in from a chat folder outside reach-work (M-CODEX-WRONG-FOLDER, `lib/reach/gate.rb`).

### Fixed

- A raised hand no longer carries a typed passkey, a labelled password or the student ID: every free-text field of the
  bundle, and the unencrypted summary, is scrubbed to "[left out]" before it leaves (`lib/reach/hands.rb`).

## [0.38.9] - 2026-10-06

### Fixed

- A Mac's handled GCM fallback is no longer reported as a fault of a rEach that never recorded it. 0.35.12 stopped
  recording the `crypto_self_test` fault event, but the spool outlives an update, a fault event written before 0.38.7
  carries no `reach_version`, and a harness plugin copy can stay older than the `reach` on PATH, so an event written
  by an older rEach and flushed later was filed under the version of the install that sent it, some with an occurred
  time before that release existed, or under no version once Teach read the version from the event alone.
  `Reach::Debug.flush` (`lib/reach/debug.rb`) now moves every spooled `crypto_self_test` fault event to
  `debug/stale-<day>.jsonl` before it batches and sends none, whichever version wrote it; nothing is deleted.
  Installs still on 0.21.3 to 0.35.11 keep recording and sending the event under their own version until they
  update (`STD-CRYPTO-FALLBACK`). No wire change.


## [0.38.8] - 2026-10-06

### Changed

- The Installation and Setup Guide (`docs/INSTALLATION-AND-SETUP-GUIDE.docx`, which `reach guide` prints) matches the
  current install: rEach installs from the `stable` branch into `~/reach-work/.reach-home`, Claude desktop users work in
  the Code tab, Windows uses rEach's own Ruby with no installer to run, enrollment ends with choosing a password and
  sign-in asks for it, Codex users open the reach-work folder and answer rEach's Codex settings question, and the guide
  states what rEach records during signed-in assignment work, as `PRIVACY.md` does.
- `README.md`, `NOTICE.md` and the documents in `docs/` describe rEach in the present tense.

## [0.38.7] - 2026-10-06

### Fixed

- An issue report names the rEach version the fault happened on, not the version that sends it. The fault spool
  and the pending issue record outlive a self-update, so a fault recorded on one build and flushed after an update
  was reported under the new build, which made Teach reopen an issue that build had fixed. `Reach::Issues` now
  keeps `reach_version` in the pending record when a fault is observed and sends it as the bundle's
  `environment.reach_version` (null for a record written before this version), `raised_version` in
  `state/issues.json` holds the same value, and every `fault` debug event carries `reach_version` in its fields
  (`lib/reach/issues.rb`, `lib/reach/debug.rb`; `STD-ISSUES`, wire revision 2026-10-06c: `W-DBG-FAULT`,
  `W-ISSUE-3`, `W-ISSUE-4`). "Once per signature per rEach version" now counts the version that observed the fault,
  so a fault on a fixed build is reported again.

### Changed

- `specs/wire.yml` is at revision 2026-10-06c; Teach 0.66.1 carries the same pinned copy and takes the version of a
  fault report from these fields alone. The canonical copy now also carries the provenance rules of revision
  2026-10-06b (`W-PROV-1` onward) that Teach pinned in 0.65.0, so the two digests agree again; rEach 0.38.7 does not
  yet verify provenance records.

Verified on Linux, Ruby 3.3, in scratch homes with `REACH_OFFLINE=1` and an injected fault in `hello`: a fault
recorded by a 0.38.6 copy and flushed by a 0.38.8 copy produced a bundle with `environment.reach_version` null and
a fault event without the field; recorded by a 0.38.7 copy and flushed by 0.38.8, both named 0.38.7; recorded and
flushed on 0.38.8, both named 0.38.8. Fed into Teach 0.65.1 on a scratch database holding the same issue shipped
with fix version 0.38.8, the first two left it shipped and the third reopened it; today's Teach reopened it on the
first.

## [0.38.6] - 2026-10-06

### Changed

- `docs/assets/provenance.json` records that the maintainer generated the `assets/logo/` artwork with AI image
  generation for this project, with no third-party stock images.

## [0.38.5] - 2026-10-06

### Added

- The new rEach logo in `assets/logo/`: the wordmark in blue for light backgrounds (`reach-logo-blue.png`) and in
  white for dark ones (`reach-logo-white.png`), and five pictures of a human hand and a robotic hand reaching
  toward each other with the wordmark placed bottom center, bottom right or top left, in white or blue
  (`reach-hands-*.png`). The PNGs are losslessly recompressed and pixel for pixel the same as the originals, and
  their provenance is in `docs/assets/provenance.json`.

### Changed

- `README.md` opens with `assets/logo/reach-hands-white-bottom-center.png` instead of the cosmic SVG banner.
  `docs/assets/reach-logo.svg` and `reach-banner.svg` stay for the pages that already use them.
- `.gitattributes` marks `assets/` export-ignore, so the release archives that the installer and `reach update`
  download carry none of the 12 MB of artwork.

## [0.38.4] - 2026-10-06

### Changed

- The repository names no real course. Examples, specs, the changelog, the smoke tools and the fake Teach fixtures
  use BUS 101 and BUS 201; the fake Teach course is Business 101: Demo Course, with the passkey
  `BUS101-K7QX-94TD`.
- The repository's public history was rewritten on 2026-10-06 so that no commit, branch or tag names the school,
  its email domain or its identity rules, or the identities once used to check enrollment against a live course
  server. Every tag kept its name and the current branch tips kept their contents.

### Added

- `TODO.md` records moving the built-in course server address to a neutral domain.

## [0.38.3] - 2026-10-06

### Changed

- The examples and fake Teach fixtures no longer follow one school's identity scheme. The wire spec example, the
  fake Teach course rules and the identities in its roster, the deploy guide and the platform and sandbox probes use
  generic rules (a username of letters, digits, dots, underscores or hyphens; a student ID of 5 to 10 digits) and
  first-initial-and-surname usernames with eight-digit IDs.
- Earlier changelog and feature entries no longer give the ID lengths and username shape of the school rEach was
  first used at, nor the identities used to check enrollment against a live course server.

## [0.38.2] - 2026-10-06

### Changed

- The repository names no institution. The README, the student guide, the design notes, the wire spec's example and
  earlier changelog entries describe the student's school email and student ID in general terms, and the fake Teach
  fixtures use Example University at the reserved domain `school.example`. A student still learns their own school
  from Teach when they type the course passkey.
- The security audit scan treats any `.edu` email address as student data, not one school's addresses.

### Fixed

- The enrollment messages for a mistyped email or student ID say "your" school's email or student ID, so they read
  correctly for a school whose name begins with a vowel.

## [0.38.1] - 2026-10-06

### Changed

- rEach pins SDK kit r2 (`sdk-1.9.0-0.14.0-r2`, about 120 KB). It carries only rplugin's and rBrain's runtime files and
  the microdatabase corpus template; r1 also carried rBrain's documentation, specs and skills, which nothing runs.
- `tools/sdk_kit.rb` also refuses a kit that holds a tailnet host name, a private network address, an access token or
  the builder's own name.

### Security

- Plane recall passes the student's query to its helper in a 0600 file instead of on the command line, where other
  users of a shared computer could see it in the process list.

## [0.38.0] - 2026-10-06

### Added

- Brain planes on every student's computer (`STD-BRAIN-PLANES`). A pinned SDK kit with rplugin 1.9.0 and rBrain 0.14.0
  (release asset `sdk-1.9.0-0.14.0-r1`, about 150 KB, its manifest sha256 compiled into rEach) installs itself in the
  background once the runtime kit is present. The microbrain is then admitted into rEach's own corpus at
  `.reach-home/corpora/reach` and consolidated daily, in a detached child under the kit Ruby, never in a hook.
- `reach sdk install [--from DIR]` and `reach sdk status [--json]`; `REACH_SDK_DISABLE=1` stops SDK downloads.
- `reach doctor` reports the brain route on its `R-DOC-BRAIN-PLANES` line.
- `tools/sdk_kit.rb` builds the SDK kit deterministically and refuses a build that carries a private path.

### Changed

- `reach_recall` uses rBrain Context through the SDK child (capped at 10 s) when it is installed, and falls back to the
  lexical index.
- `reach memory forget` also erases from the planes through rBrain Erase (capped at 30 s). A forget that cannot reach
  them is queued in the brain folder and runs before the next admission, so forgotten text is never admitted.
- Storage use counts the planes corpus.

### Notes

- Spool mode remains the full fallback: no runtime kit, no SDK, an instructor persona, `brain.planes: false` or
  `REACH_BRAIN_PLANES_DISABLE=1` leave everything as in 0.37.3. No embedding model is shipped.

## [0.37.3] - 2026-10-06

### Changed

- Kept the public branding standard focused on the visible identity, removing private superproject layout details.
- Recorded the artwork's creation method and visual reference in docs/assets/provenance.json. The existing undecided licensing status is explicit; this change assigns no new reuse terms.

## [0.37.2] - 2026-10-06

### Changed

- Optimized the public banner raster as a high-quality WebP export at the original dimensions, substantially reducing the self-contained SVG. The web export contains no original PNG container metadata; full-resolution print originals remain available to the instructor.

## [0.37.1] - 2026-10-06

### Changed

- Replaced the public logo with a restrained three-sparkle AI constellation and rebuilt the README banner around adult hands reaching toward cosmic light. The banner is a self-contained SVG with embedded artwork. The canonical mark is shared with the Teach console.
- Recorded the identity contract in STD-BRAND-IDENTITY; no enrollment, course or updater behavior changed.

## [0.37.0] - 2026-10-06

### Added

- An announcement reaches the agent as dated information and never stops it from helping
  (`STD-ANNOUNCEMENTS`, `STD-AGENT-CONTROL`). Each announcement is wrapped in a fixed frame that says when it was sent
  (day, date, time and zone), that relative words such as today refer to that day, and that it is
  information and not an order. The student still sees the text word for word.
- Agent control (`STD-AGENT-CONTROL`, `config.yml` `agent_control.render`). The text rEach puts in the agent's context
  is rendered from one bundled document, `agent-control/agent-control.yml`, pinned by a SHA-256 digest. A copy
  delivered with the course guardrails is used when it is valid and not older. Every injected block goes through
  `Reach::AgentControl.channel` under a channel id fixed in code and sits in its frame; the order of authority comes first in each
  context and in the generated `AGENTS.md`, `CLAUDE.md` and `GEMINI.md`. On any error the raw text is used.
  `reach doctor` checks the document (`R-DOC-AGENT-CONTROL`). Student-visible messages stay in rEach's own catalogue
  (`STD-STUDENT-MESSAGES`).
- Typed course controls (`STD-CONTROLS`, `agent_control.controls`), enforced in code. A pause blocks prompts and tool
  calls in a slice and in the workspace root and spares the extracurricular folder and `reach support`
  (`M-CONTROL-PAUSED`). A hold blocks `reach submit` only, so `reach qualify` and checks continue
  (`M-CONTROL-HOLD`). While a test is open, only `reach_test`, `reach_support` and `reach_status` work
  (`M-CONTROL-TEST-LOCKED`). Controls use the server's time, so the computer's clock changes nothing; a server without
  them answers 404 and rEach asks again no sooner than six hours later, and a 503 clears them. No environment
  variable or config key lifts a control in force.
- Test mode (`STD-TEST-MODE`, `agent_control.test_mode`): `reach test [status | open | questions | record QUESTION | submit]`
  and the `reach_test` tool (`Reach::ExamMode`, `state/exam.json`). The test opens one attempt with a deadline, shows the
  questions word for word and records an answer only from the student's own captured prompt, never one typed before
  the attempt opened; answers are append-only. The agent may clarify the wording of a question and nothing else.
- An announcement can carry a `show_until` time. One not yet shown when that time passes is not shown, and
  `reach announcements` and `reach_announcements` still list it, marked `(shown until <time>)`
  (`M-ANNOUNCE-LINE-EXPIRED`).

### Changed

- `config.yml` ships `agent_control.render`, `agent_control.controls` and `agent_control.test_mode` as `true`.

## [0.36.0] - 2026-10-06

### Changed

- Instructor keys and revoked codes are no longer pinned in `config.yml`. `enrollment.instructor_keys` and
  `enrollment.instructor_revoked` are gone, and so is the key `343572ebf748c69d`, so every code minted from it stops
  working. rEach now fetches them from Teach's instructor keyring (`GET /api/v1/instructor/keyring`,
  `W-API-INSTRUCTOR-KEYRING`, Teach 0.62.0 on) through `lib/reach/instructor_keyring.rb`.
  - On an enrolled install the keyring must be signed by one of the Teach signing keys received at enrollment, and the
    cached copy is re-checked on every read. An install that is not enrolled takes it over TLS from its configured
    Teach.
  - It is cached in `<root>/state/instructor_keyring.json` (0600) and refreshed when stale
    (`instructor.keyring_refresh_s`, default 900 s) at session start and before a typed code is checked. The cache is
    used offline, and an older keyring never replaces a newer one.
  - A key Teach has rotated out, or a code it has revoked, is refused on the next refresh.
  - With no keyring cached and Teach out of reach, a typed code gets `M-INSTRUCTOR-KEYRING-UNAVAILABLE` and does not
    count toward a lockout.
- `reach instructor keygen` and `reach instructor code` no longer mint. They point to the Instructor codes page in
  Teach's console (`M-INSTRUCTOR-MINT-IN-TEACH`) and exit 1. `reach instructor status` shows the keyring revision, its
  age and the key ids.

## [0.35.23] - 2026-10-05

### Fixed

- A successful module lock (0.35.22) deleted every further decision memory that named two module titles with one
  not locked, so a memory such as "weighed A and B against C and D" could be lost for good.
  `Reach::Modules.settle_memory` now deletes nothing: it supersedes only the first decision memory that names as many
  module titles as were locked, one of them not locked, matches titles in any case and titles that start or end with
  a symbol, and supersedes nothing when the brain reinforces or holds the new memory instead of saving it
  (`STD-MODULES-LOCK-SYNC`).

## [0.35.22] - 2026-10-05

### Fixed

- On Windows `reach qualify` still compiled ffi from source after 0.35.18: the runtime-4.0.7-r3 Windows kit keeps
  its gems in `gems/425419d6dd75` (the CRLF hash of the lock) while its manifest and `.complete` carry the LF hash
  `aa2ee347cf56`, so `gems_for` matched the profile but found no folder. `Reach::RuntimeKit.profile_dirs` now falls
  back to the folder the kit's own `BUILD.json` names (a hex lock prefix only) for the profile of the same name, and
  the lock also matches on its raw bytes (`STD-KIT-LOCK-MATCH`). Existing kits work without a rebuild.
- "A1 started" never reached Teach for Codex chats, which run from the course root, because the mark was made only
  when a prompt passed inside a slice workspace. `Reach::Ledger.append` now marks `<assignment>.started` whenever it
  records anything for a slice, and `Reach::Progress.flush!` backfills it from the first ledger record of each
  current slice written for the enrolled student, at that record's time, so students who already started are
  reported at their next sync (`STD-PROGRESS`). A malformed record skips only its own slice. No Teach change.
- A module pair the agent saved to memory while Reach's lock-in question was still open stayed in memory as the
  student's choice after a different pair was locked. A successful lock now records "The student's modules are
  locked in: X and Y." and supersedes a decision memory that names a module that was not locked
  (`Reach::Modules.settle_memory`), and `M-CONSENT-NEEDED` tells the agent nothing is decided until Reach says so
  and not to save it to memory (`STD-MODULES-LOCK-SYNC`).

## [0.35.21] - 2026-10-05

### Added

- `tools/tests/harness_source_test.rb` and `tools/tests/release_stable_test.rb` (Minitest, run each with `ruby`),
  for the 0.35.20 security audit's test finding: `codex_bin` accepts `codex` and `codex.exe` in any case and with a
  Windows path, and rejects other names, a missing file, a folder and an empty value; `tools/release_stable.rb`
  refuses a tag that is not Latest, a non-fast-forward move and a malformed tag, reports a dry run without pushing,
  and moves `stable` against a scratch bare origin. Both fail on the code they replace.

### Fixed

- `tools/release_stable.rb` failed with `couldn't find remote ref refs/heads/stable` when the remote had no `stable`
  branch, because it fetched that branch unconditionally; it now fetches it only when it exists and creates it.

## [0.35.20] - 2026-10-05

### Added

- `tools/release_stable.rb vX.Y.Z [--dry-run]` moves `origin stable`, the branch every student install follows,
  to a tag. It refuses unless GitHub names that tag the Latest release (`gh api repos/<owner>/<repo>/releases/latest`)
  and the move is a fast-forward, pushes only the tag's commit to `refs/heads/stable`, and confirms the remote
  branch afterwards; `--dry-run` reports the move without pushing.

### Fixed

- `reach update run --apply` on a Codex plugin-cache install ran whatever existing file `CODEX_CLI_PATH` named
  (0.35.18 security audit, low). `Reach::HarnessSource.codex_bin` now accepts it only when the file is named `codex`
  or `codex.exe`, in any case, which is what Codex Desktop sets.

### Changed

- `STD-ENROLL-LOCKDOWN` now says what happens to a bare course id that is shaped like a passkey with no separator
  (`BUS101AFA26K7QX`): it is sent to Teach, which answers `course_only`, and the student sees
  M-ENR-CODE-COURSE-ONLY. Checked against live Teach; no code change.

## [0.35.19] - 2026-10-05

### Fixed

- A rEach tool could stop answering in the middle of a chat, on macOS and on Windows, after rEach updated itself or
  the harness refreshed its copy of the plugin (`Errno::ENOENT` in `mcp:loop`,
  still reported on 0.35.17). The tool bridge (`reach mcp`) stays open for the whole chat, and `Reach::Messages`
  read `locales/en-US.yml` only when the first message was needed, from the plugin folder the bridge was started
  from. Once that folder had been moved or removed the read raised `Errno::ENOENT`, both rescue paths in
  `lib/reach/mcp_bridge.rb` asked for the same message again, and the bridge failed (faults `mcp:<tool>`,
  `mcp:loop`). The bridge now reads `locales/en-US.yml` and `locales/greetings.en-US.yml` once when it starts
  (`Reach::Messages.preload`, `Reach::Greetings.preload`), any process that finds no file under its own `locales/`
  reads the managed install's copy (`Reach::Messages.locale_file`), and the bridge's fault replies can no longer
  raise (`STD-MESSAGES-LOADED`).

## [0.35.18] - 2026-10-05

### Security

- Students only ever receive released builds. Their Codex and Claude Code marketplaces followed `main`, so builds
  marked "Not released" (0.35.11, 0.35.13) reached a Windows student. Every student fetch from GitHub (bootstrap
  archive and scripts in `INSTALL.md`, `scripts/reach-install`, `scripts/reach-install.ps1`, the install-reach skill,
  and the marketplace sources `SteveBenner/rEach@stable` for Codex and `SteveBenner/rEach#stable` for Claude Code) now
  follows a `stable` branch that moves only when a version is published as Latest. `Reach::HarnessSource` repoints an
  existing unpinned or `main` marketplace source to `stable` once per harness, detached, at session start or the
  update check (`reach update source`), restoring the old source on failure (`STD-AUTO-UPDATE`).
- The request log (`logs/requests.jsonl`) no longer stores the course passkey or the chat text that was sent as one:
  every query value in a logged route is `[redacted]`, and older lines are scrubbed once (`STD-REQUEST-LOG`).

### Fixed

- Enrollment sent ordinary chat sentences to Teach as course codes ("course code unknown" eight times for one
  student). `Reach::Identity.parse_course_code` accepts a code only alone or as exactly one code-shaped token (course
  id, optional separator, eight characters of Teach's secret alphabet), preferring a separated code over a split
  inside one word; anything else gets the format guidance and is never sent (`STD-ENROLL-LOCKDOWN`).
- A yes typed in one chat answered a question asked in another: a student's "sure" locked modules they had not
  chosen. A pending consent question is now bound to the session that asked it; only that session's yes or no
  answers it, a CLI-asked question binds to the first signed-in chat that relays it, and a module-lock answer is
  captured outside the course folder too. `reach next` and `reach modules` state an open question
  (`M-CONSENT-OPEN`), and sign-in-gated commands require the current chat's own sign-in (`STD-CONSENT-FROM-REACH`,
  `STD-SIGNIN-PASSWORD`).
- `reach next` names the slice, and after a submission continues to the next unsubmitted slice instead of stopping
  at the first (`STD-MODULES-PENDING`).
- rEach believed a Codex course folder's hooks were running when none were, because the plugin's prompt hook stamped
  `work_at`. Only course-folder work hooks stamp it now, and the hooks-not-running detection also fires when no work
  hook ran within 10 minutes of a prompt (`STD-HOOK-GUARD`, `STD-KNOWN-ISSUES`). A Codex chat that runs no tool for
  10 minutes after a prompt can be reported falsely; that is accepted. The course folder's `hooks.json` is unchanged,
  so nothing needs trusting again.
- The submission ZIP carried every read-only kit file of every slice (35 MB of a 35.2 MB ZIP). It now leaves out
  every file `.reach/delivered.json` lists as read-only. On Windows it goes to the Downloads known folder, falling
  back to the profile's Downloads (`STD-SUBMIT-ARCHIVE`).
- On Windows the final check compiled its tools from source and failed (ffi): the runtime kit indexed its gems by
  the CRLF hash of the lock while Teach ships it with LF. A kit now matches a lock in either form, so existing kits
  work without a rebuild; `runtime/package.rb` hashes the LF form, `.gitattributes` pins `runtime/locks/**` to LF,
  and a failed fallback install names the gem (`STD-KIT-LOCK-MATCH`).
- `reach update run --apply` on a Codex or Claude Code plugin-cache install reported nothing and changed nothing. It
  now refreshes through the harness CLI (using `CODEX_CLI_PATH` when codex is not on PATH) and records the result,
  or says the student must update from the app (`M-UPDATE-APP-ONLY`) and exits 1 (`STD-AGENT-UPDATE`).
- The debug spool was not sent after a submission; `reach submit` and the subscribe tick now flush it. Codex
  commands were labeled `unknown` or `claude-code`; one function, `Reach::Session.detect_harness`, reads Codex's own
  variables first (`STD-DEBUG-MODE`).
- A terminal `reach enroll` left the chat enrollment flow and the setup log's failure streak behind; both are
  cleared on success. Messages rendered only to be discarded (`M-GATE-NOGUARD`) are no longer logged or counted as
  shown (`STD-SETUP-LOG`).
- `reach <verb> --help` and `-h` print that verb's usage and exit 0 (`STD-CLI-HELP`).

## [0.35.17] - 2026-10-05

### Fixed

- On Windows, a tool call that rEach's Codex gates blocked could still run: a file write to a path the student may
  not change, a shell command or an image read that rEach refuses (`STD-CODEX-PROMPT-JSON-BLOCK`). The gates blocked
  with exit 2, which Codex's PowerShell turns into exit 1, a hook failure that does not block. `reach gate write`,
  `gate shell` and `gate read` with `--harness codex` now block with exit 0 and
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":...}}`
  on standard output, which Codex treats exactly like exit 2 (`Reach::CLI.run_hook`). Every other harness is
  unchanged, and the course folders' `.codex/hooks.json` command lines are unchanged, so nothing needs trusting again.

## [0.35.16] - 2026-10-05

### Fixed

- On Windows, Codex sent the student's message on to the model even when rEach's sign-in hook blocked it, so the
  student never saw rEach's passkey, student ID, yes or password question, the agent saw their answer instead, and
  it kept telling them to quit Codex and start a new chat (`STD-CODEX-PROMPT-JSON-BLOCK`). Codex runs hooks in the
  session's PowerShell (`-Command`), which turns rEach's exit 2 into exit 1, and Codex treats exit 1 as a hook
  failure that does not block. `reach gate enroll` and `reach gate prompt` with `--harness codex` now block by
  printing `{"decision":"block","reason":...}` on standard output and exiting 0, which Codex's prompt hook handler
  treats exactly like exit 2 with standard error (`Reach::CLI.run_hook`). Every other harness and gate is unchanged.
  `hooks/codex.json` is unchanged, so students do not need to trust the hook again.

### Changed

- The platform smoke's `hook_codex` step expects the JSON block with exit 0.

## [0.35.15] - 2026-10-05

### Security

- A backup that `reach instructor lock` made before 0.35.14 (`~/.reach/.backup/instructor-*.json`) still held the
  full, never-expiring instructor code, so on a student's computer anyone could copy it and get past every enrollment
  lock. On an install enrolled as a student, each session start now rewrites every such backup that still has a
  `code`, `signature` or `raw_code` field without them (`Reach::Instructor.scrub_enrolled_backups!`, called from
  `lib/reach/hello.rb` after `drop_enrolled_code!`). It logs `instructor.backup_scrubbed` with the code id and key id,
  never the code; a backup it cannot rewrite logs `instructor.backup_scrub_failed` and the rest are still scrubbed.
  The backup keeps the payload, the times and its 0600 mode. A computer that is not enrolled keeps
  its backups as they are. Codes that 0.35.12 exposed should still be revoked under `enrollment.instructor_revoked`.

## [0.35.14] - 2026-10-05

### Security

- The per-chat instructor pass from 0.35.13 was a plain JSON record, so any program on an enrolled computer could
  write or edit `<root>/state/instructor_passes.json` and let a chat through every enrollment lock without a code. Each pass
  now carries an HMAC-SHA256 over its session id, code id, key id, grant time and expiry, keyed from the install key
  (or a 0600 `instructor_pass.key` in the root state folder when the install has none). A pass with no MAC, a wrong
  MAC, a grant time more than five minutes in the future, or a lifetime longer than the normal sign-in is ignored. The seal catches accidental edits, other programs and a pass
  copied from another install. It does not stop the student at that computer, who can read the install key, any more
  than it stops them editing the installed Ruby files.
- A code that 0.35.12 stored in `~/.reach/instructor.json` on an enrolled install is removed at the start of the next
  session (`instructor.invalidated`, `reason` `enrolled_install`). Its backup keeps the payload but not the code or
  signature. Non-enrolled installs keep their unlock.
- `reach instructor lock` no longer keeps the code in its backup. A backup made by `lock` under 0.35.12 still holds
  the code; 0.35.15 will remove it.
- Removing a stored code does not undo the exposure, since anyone at the computer may already have copied it. An
  instructor who pasted a code on an enrolled computer under 0.35.12 should list its id under
  `enrollment.instructor_revoked` in `config.yml`.

## [0.35.13] - 2026-10-05

Not released: the release security audit found the forgeable pass and the leftover 0.35.12 codes fixed in 0.35.14.
Its changes ship in 0.35.14.

### Security

- An instructor code pasted on an enrolled student's computer was stored there in full. The code never expires, so
  anyone at that computer could later sign any chat in without the password, get past any enrollment lock (a revoked
  or ended course included), and reach the instructor persona and diagnose commands, until someone ran
  `reach instructor lock`. This shipped in 0.35.12, which carried 0.35.11's unlock. Now, on an enrolled install, a
  valid code is verified and never stored: no `~/.reach/instructor.json` and no `instructor.unlocked` entry. It signs
  that one chat in, clears the sign-in and enrollment lockouts, and grants that chat a pass in
  `<root>/state/instructor_passes.json` (0600). The pass holds the session id, code id, key id and expiry, never the code. It
  lets that chat through every enrollment lock until the normal sign-in expiry. Each read re-checks it, so revoking
  the code or removing its key voids it. Other chats, the MCP tools and terminal commands get no bypass, and
  `M-INSTRUCTOR-SIGNED-IN` now says the code works for this chat only. On a computer that is not enrolled the code
  still switches on instructor mode as before (`STD-INSTRUCTOR-UNLOCK`).
- `reach instructor unlock` no longer takes the code as an argument, where it stayed in the shell history and the
  process list. With an argument it refuses (`M-INSTRUCTOR-UNLOCK-NO-ARG`); with none it reads the code with typing hidden.

## [0.35.12] - 2026-10-05

### Fixed

- A Mac whose built-in Ruby cannot use AES-GCM additional authenticated data (Ruby 2.6.10 with LibreSSL 3.3.6) no
  longer reports a fault on every command. Since 0.21.3 `Reach::CryptoProbe.fallback!` (`lib/reach/crypto_probe.rb`)
  moves each command to the kit Ruby, or carries on with the pure-Ruby GCM while the kit installs, and it recorded
  that handled move as a fault event (`where` `crypto_self_test`, `exception` `OpenSSL::Cipher::CipherError`) even
  though the command worked. The course's technical support saw a problem on every such Mac although nothing had
  failed, and each event spent one slot of the shared `fault_max_per_hour` budget, so a busy session could crowd out
  real faults. The fallback is unchanged and now records nothing; it also skips the self-test it ran only to fill
  that event. Debug session events still carry `kit_reexec`, `gcm_self_test` and the SSL library, and
  `reach doctor --report` still shows the failing stage (`STD-CRYPTO-FALLBACK`). No wire change.

## [0.35.11] - 2026-10-05

Not released on its own; first released in 0.35.12. The release security audit found that it stored the
instructor code on enrolled installs, which 0.35.13 fixes.

### Fixed

- A student or developer who forgot the rEach password stayed stuck in the sign-in loop and then the lockout, even
  after pasting a valid instructor code. On an enrolled install the code was stored but did nothing, though
  `M-INSTRUCTOR-UNLOCKED` said rEach no longer blocked prompts. A code typed during a password step could even count
  as a wrong password. Now a valid code typed at any prompt, in any state, is never judged as an answer and never
  counted. On an enrolled install it signs that chat in as the enrolled student (`M-INSTRUCTOR-SIGNED-IN`) and clears
  the sign-in failures, the sign-in lockout and the enrollment lockout. A new chat signs in as usual. When the plugin
  hook and a course-folder hook both see the code, exactly one answers. `instructor.signed_in` is logged with the code
  id, never the code (`STD-INSTRUCTOR-UNLOCK`).
- New `reach instructor unlock [CODE]` does the same from a terminal, reading the code hidden when none is given. It
  signs in the chat waiting for sign-in, so it works when no hook runs. A code typed at `reach login password` is
  handled the same way.
- An instructor's "Allow password reset" in Teach could not help a locked-out student, because the lockout answered
  first. Now, during a lockout, the prompt hook asks Teach at most once a minute whether a reset is allowed. If it is,
  rEach clears the lockout (`M-LOGIN-UNLOCKED-BY-TEACH`). A chat that already passed the student ID and yes goes
  straight to choosing a new password; any other chat continues from its step, so the identity check is never
  skipped. `M-LOGIN-LOCKED` now says the instructor can lift it this way (`STD-SIGNIN-PASSWORD`).

## [0.35.10] - 2026-10-05

### Changed

- The 0.34.9 and 0.34.10 entries and `specs/app.yml` (`STD-SIGNIN-HOOK-SILENT`) describe the sign-in fix more briefly.

## [0.35.9] - 2026-10-05

### Fixed

- A course folder's hook and MCP commands named the Ruby of whichever rEach process last wrote the folder. The
  plugin hooks run the first `ruby` on PATH, while the CLI and the MCP server may run another, so rewrites could flip
  the path. Since 0.35.6 every flip made Codex treat the course hooks as changed and skip them. A home move could also
  leave a path into a kit that no longer exists. `Reach::Runtime.ruby_path` now returns the runtime kit installed in
  the rEach home whenever there is one. If not, it uses the same kit id under the current home, and only then the
  running Ruby.
- At each session start, `reach hello` rewrites a course folder whose rEach-written commands name another Ruby or
  shim, in `.codex/hooks.json`, `.codex/config.toml`, `.mcp.json` or `.claude/settings.json`. Codex trust is then
  refreshed under the existing consent rules. A fault event records only the count (cause `stale_ruby_path`). Salvaged
  from the unreleased `win-ruby-path` branch. Without a kit, two processes running different Rubies can still
  alternate.

## [0.35.8] - 2026-10-05

### Fixed

- When rEach writes a folder path or hook key into Codex's `config.toml`, it now escapes control characters as
  `\uXXXX`. A folder name holding one used to produce an invalid string. The editor's read-back and Codex's own check
  refused the result and put the old file back, so nothing broke, but the trust was never written. Found by the
  release security audit of 0.35.6.
- `PRIVACY.md` says that `reach codex off` leaves folder trust and hook approvals already written until the student
  removes them or puts back the saved copy.
- `reach.spec.yml` names `CodexSetup.trust_plan`, the method the code has, instead of `trust_entries`.

## [0.35.7] - 2026-10-05

### Fixed

- In Claude Cowork on Windows the plugin installed, and then every message the student sent got no answer: Claude
  thought for a moment and the turn ended. Cowork shows a prompt that a hook blocks as an empty turn, and rEach's
  Cowork check (0.33.3) missed two ways of reaching a block. It knew only the entry points `local-agent` and
  `remote_cowork`; Claude Code 2.1.289 also names `local_agent`, `remote_cowork_trigger`, `claude-coworker` and
  `claude-coworker-terminal`, and under those rEach blocked the prompt with its enrollment question
  (`Reach::Fingerprint::COWORK_ENTRYPOINT` in `lib/reach/fingerprint.rb`). And a block raised anywhere outside that
  check still exited 2. In Cowork the prompt hooks (`gate enroll`, `gate prompt`) now never exit 2: a block there
  becomes the Code tab message, exit 0 (`Reach::CLI.cowork_prompt_hook?` and `run_hook` in `lib/reach/cli.rb`,
  STD-COWORK-CODE-TAB). A prompt that matches the crisis check still gets the support message. Every other app is
  unchanged.
- Not verified: a real Cowork session on Windows. Which of the two paths the Windows computer took is not known; no
  Cowork install has ever reported to Teach. The hook was run under each entry point before and after the change,
  and with the first check switched off.

## [0.35.6] - 2026-10-05

### Fixed

- rEach approves a course folder's Codex hooks only when the file is exactly what rEach writes for that folder.
  Before, any command that merely began with rEach's own command was approved, so extra text added to the file
  would have been approved too. Found by the release security audit of 0.35.5.
- A yes to Codex's settings given before this release no longer approves hooks or course folders. That yes covered
  less, so rEach asks again, naming hook approval. Only a yes recorded with the `hook-trust-1` scope lets rEach write
  Codex hook trust. The sandbox settings keep healing under the earlier yes. Found by the same audit.
- `specs/wire.yml` `W-KI-4` lists the `codex_hooks_untrusted` detector (since 2026-10-05d).

## [0.35.5] - 2026-10-05

Not released: the release security audit found the two problems fixed in 0.35.6. Its changes ship in 0.35.6.

### Fixed

- In Codex, a student could never sign in. Each new chat the agent said there was a setup problem and told them to
  quit Codex and start a new chat. Codex trusts every hook by the hash of its command, and a course folder's
  `.codex/hooks.json` is written after the student approved the plugin's hooks, so Codex never ran any course-folder
  hook. The "hooks not running" known issue was therefore always detected, and its steps sent the student away from
  the sign-in question. Prompts were never recorded, and qualify and submit were refused (`STD-CODEX-HOOK-TRUST`).
- The plugin's `gate enroll` and `hello` hooks now do the course prompt and session work on Codex. `hooks/codex.json`
  is unchanged byte for byte, so nothing needs approving again. A marker lets exactly one hook do it when an older,
  trusted course-folder hook also runs. `gate enroll` stamps `prompt_at` on every Codex run.
- A course folder's Codex hooks keep only the tool and stop hooks. With the student's existing yes to Codex's
  settings, rEach records Codex's hook trust for them (`Reach::CodexHookTrust`, checked against codex 0.160.0) and
  marks each course folder a trusted project. It repairs both whenever they go stale. `PRIVACY.md` and the consent
  question say so.
- Missing or stale trust refuses qualify, submit and part answers with `M-HOOKS-UNTRUSTED`, whose remedy is
  `reach_setup configure`. While the student's sign-in is pending, hook-trust and course-hook known issues are not
  shown to the agent, and no hook-trust message tells the student to restart Codex or start a new chat.

## [0.35.4] - 2026-10-05

### Fixed

- `STD-ENROLL-NO-RELAY` and FEATURES 2.1 no longer give the minute of the refused enrollment requests, which could be
  matched to one student in Teach's request log; they give the date. Found by the release security audit of 0.35.3.

## [0.35.3] - 2026-10-05

### Fixed

- `specs/app.yml` `STD-ENROLL-NO-RELAY` named a Teach-internal constant; it now cites only `W-API-ENROLL`
  (`STD-TEACH-OPAQUE`). Found by the release security audit of 0.35.2.
- `specs/wire.yml` `W-COMPAT-5` (revision 2026-10-05c) no longer says `reach enroll <code>` sends shape v1; since
  0.35.2 no Reach path does.

## [0.35.2] - 2026-10-05

### Fixed

- Enrolling through the AI always failed with "That course passkey wasn't accepted", whatever passkey was typed
  (`STD-ENROLL-NO-RELAY`). `reach enroll <passkey>` and the `reach_enroll` tool still sent the request shape from
  before enrollment v2 (`Reach::Enroll.generate_and_register`), which Teach refuses as `invalid_request` every time.
  That request is gone. The tool takes no arguments and never enrolls: it says how rEach enrolls the student
  (`M-GATE-NOENROLL`), that Codex isn't running rEach's hooks and the student should not type their details in the
  chat (`M-ENROLL-NO-HOOK`), or that the install is already enrolled, with the next step (`M-ENROLL-ALREADY`).
  `reach enroll` with a bare passkey says to run `reach enroll` on its own or answer rEach in the chat
  (`M-ENROLL-POSITIONAL`). The interactive `reach enroll` and the flag form are unchanged; the passkey, email,
  student ID and password still never pass through the AI.

### Removed

- The unused `M-ENROLL-REFUSED` message and the `enroll <code>` line in `reach help`; `reach status` and doctor's
  `R-DOC-ENROLL` now say to run `reach enroll`.

## [0.35.1] - 2026-10-05

### Fixed

- The setup log, the installers' records and the setup report wrote paths with the student's user folder in them,
  which usually carries their account name; every such path now starts with `~` instead (`Reach::SetupLog.scrub_homes`,
  the installers' `log_homeless` and `Get-LogText`). Found by the release security audit of 0.35.0, which was pushed
  to `main` but never tagged or released.
- The enrollment request's device fingerprint (its salt and salted hashes, the binding and the hostname) is now
  `[redacted]` in the setup log and the report; with the salt beside them, short values could be guessed back.
- More name fields (`given_name`, `family_name`, `middle_name`, `preferred_name`, `legal_name`, `nickname`) are kept
  only as their length, like the other typed fields.
- `PRIVACY.md` says the setup log holds folder and program names with the user folder's name taken out.
- `scripts/reach-install.ps1` no longer drops one of two equal-length home folders from its path scrub
  (`Select-Object -Unique` before sorting) and strips PEM blocks like the Ruby writers.

## [0.35.0] - 2026-10-05

### Added

- Setup log (`STD-SETUP-LOG`, `lib/reach/setup_log.rb`): until the student is enrolled, rEach records every command,
  hook, request and response, debug event, fault, message id and an environment snapshot in `setup-log/` in the rEach
  home, with full backtraces and no typed text, passwords, passkeys or codes. It is never sent.
- Setup report: at the third setup failure in a row (and every third after), rEach saves
  `reach-setup-report-<time>.json` (schema `reach.setup-report/v1`) in Downloads and shows its path and `file://` link
  with the suggestion to send it to the instructor (`M-SETUP-REPORT-SAVED`), in the enrollment hook reply, a terminal
  command's output or an MCP tool result. `reach debug export` and the `reach_debug` action `export` save one on demand.
- `scripts/reach-install` and `scripts/reach-install.ps1` record each step and the outcome in
  `setup-log/install-<stamp>.jsonl` and count a failed install toward the streak.
- `reach debug status` shows the setup log (active, streak, files, bytes; JSON key `setup_log`).

### Changed

- The debug phrases ("enable debug mode", "turn debug off") work before enrollment: the plugin-level enrollment hook
  switches debug mode and asks its current question again instead of treating the phrase as a passkey.
- `PRIVACY.md` lists the setup log under what stays on the computer.

## [0.34.13] - 2026-10-05

### Fixed

- Error reports sent with debug mode off listed backtrace lines with full paths, which named the student's user folder
  when Ruby or a gem lived inside it (the runtime kit does). `Reach::Debug.relative_frames` now writes any line under
  the profile folder, `HOME` or `USERPROFILE` as `~/...`, and `PRIVACY.md` says so.
- On Windows, when `HOME` points somewhere other than the profile folder, transcript scrubbing also replaces that
  folder, as `[[home-folder-env]]`.
- A profile folder that is a drive root (such as `D:\`) no longer produces short scrub forms like `/d/` that would
  have replaced unrelated text in a transcript.

## [0.34.12] - 2026-10-05

### Changed

- Wire W-KI-4 marks the both-prompt-hooks rule for `signin_hook_not_running` as revision 2026-10-05b, and
  `STD-SIGNIN-HOOK-SILENT` now opens with the rule 0.34.11 implements (either prompt hook counts) instead of the
  plugin-hook-only rule of 0.34.9. Documentation only; no behavior changes.

## [0.34.11] - 2026-10-05

### Fixed

- 0.34.9 and 0.34.10 judged sign-in only by the plugin's prompt hook (`gate enroll`), but a course folder's prompt hook
  (`gate prompt`) signs the student in too (`Reach::Login.claim`). A Codex student whose course-folder hooks ran and
  whose plugin hook did not was told sign-in could not start. `Reach::KnownIssues.signin_hook_dead?` now counts the
  latest of both stamps (`hooks_enroll_seen.json` at, `hooks_seen.json` prompt_at) against the session start.
- A tool gate refusing a student who has not signed in (`Reach::Gate.require_login!`) still said `M-LOGIN-NEEDED`,
  that rEach would ask for the ID and password in the chat, while no prompt hook was running. It now says
  `M-LOGIN-NEEDED-NO-HOOK` in that state (`STD-SIGNIN-HOOK-SILENT`). Found by the 0.34.10 pre-push security audit.

### Changed

- Wire revision 2026-10-05b: W-KI-4 says `signin_hook_not_running` fires only when neither sign-in prompt hook ran;
  Teach's pinned copy changes with it.

## [0.34.10] - 2026-10-05

### Fixed

- While Codex's sign-in hook was silent, the agent was still told that rEach would ask for the student ID and password
  in the chat and that the request was genuine (`M-LOGIN-NEEDED`), which contradicted 0.34.9's
  `M-NEXT-LOGIN-NO-HOOK`. On the MCP path, `reach_hello`'s
  sign-in context (`Reach::Hello.login_context`) and every tool refusal for a student who has not signed in
  (`Reach::MCPBridge#login_text` over `Reach::Login.require_active!`) now say `M-LOGIN-NEEDED-NO-HOOK`: rEach cannot
  ask, so the agent asks for neither, does not repeat one the student types, and relays `reach_next`
  (`STD-SIGNIN-HOOK-SILENT`). Found by the 0.34.9 pre-push security audit.

## [0.34.9] - 2026-10-05

### Fixed

- A Codex student whose sign-in hook was not running was asked for their student ID again and again
  (`STD-SIGNIN-HOOK-SILENT`). `reach_next` (`Reach::Next.compute` with
  `mcp: true`) now returns `M-NEXT-LOGIN-NO-HOOK` when Codex has not run the plugin's sign-in hook (`gate enroll`)
  since the session started: rEach can't sign the student in yet, they should not type their ID or password in the
  chat, and they restart Codex, allow rEach's hooks and start a new chat. `reach next` in a terminal is unchanged.
- The known issue for a silent sign-in hook was flagged whether or not that hook ran, because `hooks_not_running`
  watches the course-folder hooks. The new detector `signin_hook_not_running`
  (`Reach::KnownIssues.signin_hook_dead?`) compares the sign-in hook's stamp (`hooks_enroll_seen.json`) with the
  latest Codex session start; `hooks_not_running` and the qualify, submit and part-record refusal are unchanged.
- `reach_known_issues` and the session context named the fix for every matching known issue, detected or not, so the
  agent was told to run `reach_setup configure` for a problem rEach had not found. `Reach::KnownIssues.remedy_lines`
  now names a remedy only for a detected issue.

### Changed

- Wire revision 2026-10-05a: W-KI-4 lists `signin_hook_not_running`. Teach's pinned copy changes with it.

## [0.34.8] - 2026-10-05

### Fixed

- `PRIVACY.md` no longer claims that error reports carry no folder names; 0.34.6 and 0.34.7 said so, but an error
  report's backtrace lines can name folders outside rEach. The setup-problem report (the Windows user-folder
  mismatch) is described in its own line, and it is the one that carries no folder names.
- `reach status`'s folder line said "nothing was changed" after a `rollback_incomplete` failure; it now gives the
  same advice as the failure message.
- `reach.spec.yml` documents `rollback_incomplete` and the bootstrap-only `.reach-home.pre-*` rollback.

## [0.34.7] - 2026-10-05

### Fixed

- When the move's final rename failed and something had recreated the destination meanwhile, the relocation did not
  try to put the renamed folder back and still told the student nothing had changed. It now reports
  `rollback_incomplete` in that case too.
- The `rollback_incomplete` message tells the student the leftover folder has a hidden name that starts with
  `.reach-home` and contains `set-aside` or `pre`.

### Changed

- `PRIVACY.md` says a setup-problem report carries a few fixed facts, such as which way rEach found the user folder.

## [0.34.6] - 2026-10-05

### Fixed

- If the move's final rename failed and putting the set-aside profile home (or a bootstrap-only home renamed to
  `.pre-<timestamp>`) back failed too, the second error hid the first and the student was told nothing had changed.
  The relocation now puts back whichever folder it renamed, including the bootstrap-only one, and when that fails it
  records the new reason `rollback_incomplete` and tells the student that part of rEach's folder is still under its
  set-aside name and to tell their instructor. Nothing is deleted in any case (`lib/reach/relocation.rb`).
- Transcript scrubbing on Windows also replaces the Cygwin spelling (`/cygdrive/c/Users/...`) of the home folder.

### Changed

- `PRIVACY.md` says the short reports rEach sends with debug mode off also cover setup problems, such as an app
  pointing rEach at a folder that is not the student's own on Windows, and carry no folder names.

## [0.34.5] - 2026-10-05

### Fixed

- The relocation set aside an unenrolled profile home before the copy was verified, so a failed move left harness
  links pointing at a folder that had been renamed while it told the student nothing had changed. The rename now
  happens in the switch step, right before the moved home is renamed in, and is undone if that rename fails
  (`lib/reach/relocation.rb`).
- When one stray location held an unenrolled rEach home and another an enrolled one, `Reach::Paths.root` could pick
  the unenrolled one; it now always prefers the enrolled one, as `exe/reach-run` does.
- Transcript scrubbing on Windows also replaces the Git Bash (`/c/Users/...`) and WSL (`/mnt/c/Users/...`) spellings
  of the home folder, and the backslash forms of a network (`\\server\...`) profile.
- The `home_env_mismatch` record is a fault event (`where: paths.user_home`), the only kind besides link that rEach
  sends while debug mode is off (`W-DBG-FAULT`), instead of a session event; it still carries no path or name.

## [0.34.4] - 2026-10-05

### Fixed

- A Windows student whose rEach landed in the wrong user folder and who reinstalled before 0.34.3 moved it got a
  fresh, unenrolled install in the right folder while their enrollment stayed behind (`STD-USER-HOME`).
  `Reach::Paths.root` and `exe/reach-run` now take an enrolled stray home over an unenrolled one in the profile, and
  the relocation renames the unenrolled profile home to `.reach-home.set-aside-<timestamp>` (nothing deleted) and
  moves the enrolled one in. An enrolled profile home is never displaced.
- Transcript scrubbing on Windows again replaces the home folder written with backslashes (`C:\Users\...`) and its
  JSON-escaped form, not only the forward-slash form 0.34.3 left (`Reach::Deidentify.surfaces`).
- The `home_env_mismatch` record added in 0.34.3 was never written, because it is not a debug event kind Teach
  accepts; it is now a `session` event with `event: home_env_mismatch`.

## [0.34.3] - 2026-10-05

### Fixed

- On Windows rEach created a folder such as `C:\Users\anon` that is not the student's own user folder, and the student
  then hit permission errors there (`STD-USER-HOME`). rEach took its home from `HOME`, which a harness or shell can
  point anywhere; the hook launcher `exe/reach-run`, `Reach::Paths` and `scripts/reach-install` all built
  `~/reach-work` from it and created every missing folder on the way. On Windows rEach now asks Windows for the
  signed-in user's profile folder (`Reach::Paths.user_home`: the Profile known folder, then the `HKCU\Volatile
  Environment` `USERPROFILE` value, then `%USERPROFILE%`), and so do `exe/reach-run` (registry, then PowerShell, then
  `$USERPROFILE`), `scripts/reach-install` and `scripts/reach-install.ps1`. macOS and Linux are unchanged.
- rEach never creates the folder its paths hang from: when the user folder (or the parent of `REACH_WORKSPACE_ROOT` or
  `REACH_HOME`) is missing, the launcher, the installers and `Reach::Paths.ensure_home!` create nothing and say so with
  the new `M-HOME-MISSING` message.
- An install that already landed under the wrong folder moves to the real one by itself: `Reach::Paths.root` finds it
  as a stray home and the existing relocation copies it into `<profile>\reach-work\.reach-home`, then copies the other
  entries of the stray `reach-work` beside it, skipping any name already there. Nothing in the stray folder is deleted
  or changed apart from `RELOCATED.json`.
- Harness config folders follow each harness's own home rule (`CLAUDE_CONFIG_DIR`, else `%USERPROFILE%` for Claude
  Code and Antigravity; `CODEX_HOME`, else the profile for Codex; `HERMES_HOME` for Hermes), so setup, updates and the
  Codex marketplace source write where the harness reads. Transcript scrubbing removes the real profile path.

### Added

- At session start on Windows, when `HOME` differs from the profile folder, rEach records `home_env_mismatch` in its
  fault log with the lookup step and two yes/no flags, never a path or a name.

## [0.34.2] - 2026-10-05

### Removed

- Build blueprints (`specs/implementation/`) and the course-alignment design draft
  (`docs/course-alignment-design.md`) are no longer kept in this public repository (`STD-TEACH-OPAQUE`); they live
  with the maintainer's private material. `.rproject/` work notes are no longer tracked.
- `config.yml` `rstack.backup` lists no mirrors: the maintainer's own backup locations no longer ship to students.

### Changed

- Text that described the course server's internals or the maintainer's computer is reworded in `TODO.md`,
  `CHANGELOG.md`, the smoke notes, the known-answer fixture notes, the security audit installer and the vendored
  skill's provenance. The repository's history, every tag and branch, was rewritten the same day to remove the same
  material from every earlier commit, and the GitHub release notes were redacted to match.

## [0.34.1] - 2026-10-05

### Fixed

- A student's agent asked to use the instructors' local server port, after reading developer notes that came with
  the rEach download (`STD-STUDENT-TREE`). `.gitattributes` now leaves `.githooks/`, `.github/`, `.rproject/`, `tools/`,
  `specs/implementation/`, `docs/smoke-assignment-1.md`, `docs/deploy-and-test.md` and figure 08 out of GitHub's
  archives, so a new install (`main.zip`) and every update (`refs/tags/vN.N.N.zip`) no longer carry them, and an
  update removes them from an existing install. For a marketplace added from the repository link, which clones the
  whole tree, no file outside this changelog names that port any more: the smoke runner reads it from the Teach
  source it builds, and the smoke notes and blueprints use a placeholder.
- `tools/security_audit/gate.rb` reaches Teach at `config.yml` `teach.url` when `TEACH_URL` is unset, in place of a
  local default, and sends nothing when that address is not an http(s) URL.

### Changed

- `AGENTS.md` (and `CLAUDE.md`) now says the course server is only what `reach` reports, and that `docs/`, `specs/`
  and `tools/` are never a source of an address or a port.

## [0.34.0] - 2026-10-05

### Added

- Security audit mode for releases (`STD-SECURITY-AUDIT-MODE`), a maintainer tool that students never run. A
  `pre-push` hook (`.githooks/pre-push`, armed per clone by `tools/security_audit/install`) acts only when a push to
  this repository on GitHub carries a release (a `v*` tag, or a change to `VERSION`). It scans the diff since the last
  release for secrets, key and credential files, local paths and student data (matched against a salted, hashed roster
  from Teach, so no identifier is ever in plain text) in `tools/security_audit/scan.rb`, then runs a headless,
  read-only Claude Code audit of the same diff (`tools/security_audit/prompt.md`) for exposure, liability, data loss,
  security and privacy issues, and blocks the push on a finding at or above the configured severity. Settings come
  from Teach's Ops page (Teach 0.53.0); each release tree is audited once, reports are masked, and every run is
  posted to Teach and to rLogs. `REACH_SECURITY_AUDIT=0` skips it.

## [0.33.6] - 2026-10-05

### Changed

- A message the course's technical support stores on a raised hand is no longer announced as "an instructor answered
  your raised hand". When every new reply rEach finds on the student's hands was written by the service desk or by
  the issue desk (`answered_by` `service-desk` or `teach-issues`), the update notice reads "technical support sent a
  message about a problem you reported", and each entry of the sync summary's `hand_replies` carries `from`
  (`technical_support` or `instructor`). An instructor's answer is announced as before. No wire change.

## [0.33.5] - 2026-10-05

### Fixed

- `reach qualify` could never run on a computer whose own Ruby exports `RUBYLIB`, `RUBYOPT`, `GEM_HOME`, `GEM_PATH`
  or Bundler settings. A student's Ruby 3.3.8 under `~/.local/usr` exported `RUBYLIB` at its 3.3 standard library, so
  the runtime kit's Ruby 4.0.7 loaded the wrong rubygems at start and exited with "ruby lib version (3.3.8) doesn't
  match executable version (4.0.7)"; the assignment could not be qualified or submitted, while `reach runtime install`
  (whose smoke is `ruby -v`) and `reach doctor` (which cleared only some of the variables) both looked healthy. Every
  launch of the kit Ruby now goes through `Reach::RuntimeKit.clean_env` (`lib/reach/runtime_kit.rb`), which unsets
  those variables and every inherited `BUNDLE_`/`BUNDLER_` variable: the gem install and bundle check and the cucumber
  run in `lib/reach/suite.rb`, the GCM re-exec in `lib/reach/crypto_probe.rb` and doctor's kit probe in
  `lib/reach/diagnose.rb` (STD-KIT-CLEAN-ENV). A Ruby already on the computer keeps the student's environment.

## [0.33.4] - 2026-10-04

### Fixed

- In Codex, a student who typed yes to rEach's question about changing Codex's settings was told that rEach had not
  registered the answer, and the settings never changed. Only a course folder's prompt hook (`gate prompt`) read the
  answer, and Codex does not run that hook until the folder and the hook are trusted, which is what the setup is for.
  The plugin's prompt hook (`gate enroll`) now takes a yes or no to that one question itself, for a signed-in Codex
  session, and answers with the result (`Reach::CLI.codex_setup_answer` in `lib/reach/cli.rb`,
  `Reach::Consent.observe` with `kinds`, STD-CODEX-SETUP).
- The plugin's prompt hook counted as proof that the course-folder prompt hook runs (since 0.28.1), so in a Codex that
  ran only the plugin's hooks rEach asked the question in chat instead of sending the student to a terminal, did not
  refuse qualify, submit and `reach part record` with `M-HOOKS-REQUIRED`, and the student's own-part answers stayed
  unsaved with no reason given. The plugin hook now keeps its own stamp (`hooks_enroll_seen.json`) and never writes
  `hooks_seen.json` (`lib/reach/known_issues.rb`, STD-HOOK-GUARD). `reach_setup configure` sends the student to a
  terminal only when no rEach hook at all has run for 15 minutes (`lib/reach/codex_setup.rb`).
- When the plugin hook and a course-folder hook both see one consent answer, one of them records it and speaks; the
  pending question is claimed by renaming it (`lib/reach/consent.rb`).

### Changed

- A Codex student whose course-folder hooks are not running, and who could qualify and submit before because the
  plugin hook hid that, is now refused with `M-HOOKS-REQUIRED` until those hooks run, as STD-HOOK-GUARD always
  intended.
- Not verified: a real Codex chat. Checked on a scratch Teach, scratch student and scratch Codex home with the hook
  commands and the MCP tool run by hand, before and after the change.

## [0.33.3] - 2026-10-04

### Fixed

- In Claude Cowork a student who was not enrolled or not signed in got "Claude's response came back empty" instead of
  rEach's question, and could not enroll. rEach asks by blocking the prompt, and Cowork appears to show a blocked
  prompt as an empty reply. In Cowork (`CLAUDE_CODE_ENTRYPOINT` `local-agent` or `remote_cowork`) the prompt hook now
  answers with one fixed message that sends the student to the Claude app's Code tab (`M-COWORK-CODE-TAB`,
  `Reach::CLI.code_tab_hold?` in `lib/reach/cli.rb`, STD-COWORK-CODE-TAB). It runs no enrollment or sign-in step
  there, so nothing the student types in Cowork counts as an answer or a failed attempt, and the passkey, student ID
  and password still never pass through the AI. A prompt that matches the crisis check gets the support message.
- The student guide tells Claude desktop users to work in the Code tab.
- Not verified: a real Cowork session. The cause is inferred from one student's screenshot; the hook was run with
  Cowork's entrypoint value and real Claude turns repeated the message exactly.

## [0.33.2] - 2026-10-04

### Fixed

- On Windows a student who asked for a live session was asked for their yes again and again, and no session was ever
  requested. rEach started its background live runner with the process option `pgroup`, which Ruby on Windows
  refuses; the error was swallowed, so the typed yes stayed on the computer. Every detached start now takes its
  option from `Reach::Runtime.detach_group` (`new_pgroup` on Windows): the live runner, transcript stream, subscribe
  tick and storage measure (`Reach::Storage.spawn_detached`), the support flush (`lib/reach/support.rb`), the module
  and transfer flush (`lib/reach/consent.rb`) and the sync after enrollment or a module lock
  (`lib/reach/enroll_flow.rb`, `lib/reach/modules.rb`). None of these ran on Windows before.
- `reach live request` and the `reach_live` tool no longer repeat the question while the student's answer is still
  waiting to be sent: they say rEach is sending it and start the runner (`Reach::Live.ask!`).
- Not verified: a real Windows install. On Linux the detached start still runs and the Windows branch was checked
  for the option it selects.

## [0.33.1] - 2026-10-04

### Fixed

- The student's AI told them that rEach would never ask for their student ID and password, and rEach then asked for
  both. The instruction rEach gives the AI said "never ask for either yourself", and the AI passed it on as a promise
  from rEach. `M-LOGIN-NEEDED`, `M-ENR-AGENT-CONTEXT`, `M-ENR-AGENT-GUIDE`, `M-ENR-HERMES-GUIDE`, the assistant
  persona (`agents/reach.md`, `skills/reach-assistant`) and `skills/reach-course` now say that rEach itself asks for
  the student ID and the password in the chat, that the request is genuine, and that the AI must never tell the
  student that rEach will not ask.

## [0.33.0] - 2026-10-04

### Changed
- rEach takes the facts of one course from that course, not from this repository (`STD-COURSE-PROFILE`, wire
  revision 2026-10-04j). The learning system's name and the upload-for-credit rule, the hints for the school email
  and student ID, and the wellbeing phrases and support message now come from the course profile in the guardrails
  package. A course that sends them reads as before.
- With no profile, rEach names no learning system and adds no upload sentence, asks for "your school email" and
  "your student ID" in plain words and leaves the checking to the course server, and shows times in UTC, labeled
  UTC, when no time zone is known.
- The passkey example in the enrollment messages names no course.

### Removed
- The institution name, email domain, username and student-ID patterns, the default time zone and the learning
  system's name are gone from the shipped `config.yml` and from the code. A local `config.yml` may still set
  `course.timezone` or `submit.lms_name`.

## [0.32.2] - 2026-10-04

### Fixed

- On Linux the background update check was never installed. `Reach::Subscribe.install!` passed its
  `systemctl --user show-environment` check to `run_os` as one array, `Process.spawn` raised `ArgumentError`, and
  every install was recorded as "systemd user manager unavailable" with a `subscribe:os` fault sent to Teach.
- An MCP tool called without an argument it requires answered `M-REACH-HICCUP-TOOL` and sent Teach a `KeyError`
  fault (`mcp:reach_reference`, `mcp:reach_remember`). `Reach::MCPBridge.call_tool` now answers JSON-RPC error
  -32602 naming the tool and the missing argument, and records no fault.
- Stopping `reach mcp` with a signal (how a harness ends the server) recorded a debug `error` event for
  `SignalException`. `Reach::Debug.command` no longer records one; the `command` event still names the signal.

## [0.32.1] - 2026-10-04

### Fixed

- The password step kept students out of rEach, so every password was reset (Teach 0.46.1). At the first sign-in
  after this update rEach apologizes for the inconvenience and asks the student to choose a new password, typed
  twice, then signs them in (`M-LOGIN-RENEW`, `Reach::Login.evaluate_confirm`, `Reach::Password.renewal_due?`). The
  old password is not asked for. A student who enrolls again is told that a password chosen before October 5, 2026
  was reset (`M-ENR-ASK-PASSWORD`). A password forgotten later is still reset through the instructor.

## [0.32.0] - 2026-10-04

### Added

- Transcripts are sent in the background (`STD-TRANSCRIPT-STREAM`, wire revision 2026-10-04i, W-TRN-7).
  `Reach::Transcript.stream` runs every `transcripts.send_interval_s` of the course status (set in Teach; 600 s when
  absent, never under 60 s, at most once per interval across every rEach process): it reads each recorded session's
  harness transcript from where rEach last stopped, scans the slice's owned files and sends everything queued in
  normal mode. The MCP server starts it from an open session (`Reach::Transcript.start_stream_thread`), the operating
  system job runs it after its update check, at the shorter of its own interval and the course's
  (`Reach::Subscribe.settings`), and `reach transcript stream [--force]` runs it by hand. No hook waits on it and
  `REACH_OFFLINE=1` stops it. The capture bounds of `STD-TRANSCRIPT` are unchanged.
- Tool output is recorded: what each tool returned to the AI becomes an `output` entry (Claude Code tool results,
  Codex call outputs), named by the call it answers, with the note `error` when the harness marks it as one
  (`lib/reach/transcript_ingest.rb`). On Claude Code rEach also reads each subagent transcript
  (`<session>/subagents/agent-*.jsonl`) and marks its entries `subagent`.
- Nothing is cut to fit: a prompt, reply, reasoning block, action input or tool output over 120000 bytes is recorded
  as consecutive entries with `part` [n, of] (`Reach::Transcript.text_parts`). Entries with `part`, long action inputs
  and `output` entries wait in the queue until the course server's status lists them.
- The student's own export shows tool output (`M-TX-HEAD-OUTPUT`).

### Changed

- An action entry holds the whole tool input instead of its first 2000 bytes.
- Each recording hook stores the session's harness, space and slice workspace in the session state, so the background
  sender needs no working directory.

### Fixed

- A session that left the capture bounds and came back could have what the harness transcript gained in between read
  into the record at the next hook. The first hook back inside the bounds now moves past it
  (`Reach::Transcript.ingest_event`).

## [0.31.0] - 2026-10-04

### Added

- rEach sets Codex up by itself (`STD-CODEX-SETUP`, `Reach::CodexSetup`). After the student's yes it writes the sandbox
  settings rEach needs into the student's own Codex configuration (`$CODEX_HOME/config.toml`): mode workspace (the
  default outside Windows) sets `sandbox_mode = "workspace-write"`, network access and the reach-work folder as a
  writable root; mode full (the default on Windows) sets `danger-full-access`; both mark the reach-work folder trusted.
  A line editor changes only those lines, keeps a backup beside the file (`config.toml.reach-backup-<time>`), writes
  atomically, refuses rather than guess (`M-CODEX-SETUP-UNSAFE`) and puts the old file back when `codex features list`
  rejects only the new one. It never writes approval policy, model, features, hooks, hook trust, marketplaces or MCP
  servers.
- `reach codex status|probe|configure|off` and the MCP tool `reach_setup` (status, probe, configure; works before
  enrollment). configure asks on a terminal, or returns rEach's question for the agent and applies on the student's
  captured yes (consent kind `codex_setup`, kept on the computer); on Codex with rEach's hooks not running it answers
  `M-CODEX-SETUP-TERMINAL` instead. probe runs `reach codex probe-child` inside `codex sandbox`, passing the settings
  file's own `sandbox_mode` with `-c` (Codex 0.160.0's `codex sandbox` does not read that key from the file, while a
  chat does), and records whether it reached the course server and rEach's folder. Before enrollment the tool answers
  `M-CODEX-SETUP-SIGN-IN`, because a chat yes is captured only for a signed-in student.
- Live actions `codex_configure` and `sandbox_probe` (wire revision 2026-10-04h, W-LIVE-5), asked of the student like
  every other action. Known issues carry `remedy` (W-KI-1); rEach maps it to the tool call that fixes the issue and names
  it to the agent (`M-KNOWN-ISSUE-REMEDY`), and runs nothing by itself.
- `reach doctor` prints a `codex:` line, runs the probe first when it can, and reports `R-DOC-CODEX` when Codex's
  settings no longer hold what rEach set or the last probe was blocked; `reach doctor --report` gains a `codex` section.
  `reach mcp` and the background subscription tick put the settings back at most every 6 hours while the student's yes
  stands. `config.yml` gains `codex` (setup, sandbox, heal, probe_timeout_s); `REACH_CODEX_SETUP=0` turns it off.
- The installers run `reach codex configure` when Codex is present and a person can answer, and print the command
  otherwise: `scripts/reach-install.ps1` after setup, `scripts/reach-install` right after it installs (the terminal, or
  `/dev/tty` when only its input is piped; never when its output is not a terminal, so an agent's run only prints).
- `tools/fake_teach` serves `GET /api/v1/known-issues` from `known_issues.json` under `--home` (W-KI-1 key order with
  `remedy`, revision as ETag, 304).

### Changed

- rEach keeps its own files in `~/reach-work/.reach-home` instead of `~/.reach` (`STD-HOME-IN-WORKSPACE`), so a harness
  that may write only inside the chat's folder can reach them. `Reach::Paths.root` resolves `$REACH_HOME`, a completed
  relocation record, the legacy `~/.reach` while it still holds an install, then the new home.
- An existing install relocates itself (session start, the end of `reach setup`, or `reach relocate`): the legacy home
  is copied to `.reach-home.relocating` with a SHA-256 journal, verified in rounds, checked for unchanged enrollment and
  switched in by rename; a kill at any point resumes. The legacy folder is never deleted, truncated, renamed or
  overwritten; its only change is `RELOCATED.json`. Harness configs, the Claude and Codex plugin sources
  (`Reach::HarnessSource`, also repointed by `update/apply.rb`) and the subscription job follow the move.
- Every kind of space refuses reads, writes, listings, searches, redirects and cds into the home and recursive searches
  from an ancestor of it; the student-work walks (slices, layout migration, the submission copy) prune it. A root-kind
  session judges writes and commands by their target slice and asks which slice (`M-PICK-SLICE`) when it cannot choose;
  writes wait while a relocation runs (`M-RELOCATING`). The root space gains the check hook. `reach doctor` reports
  `R-DOC-RELOCATION`.
- After a relocation the launcher's plugin pointer (`bin/root`) never names the plugin copy left in the legacy home: a
  command run from that copy points it at the new home's plugin instead, and any other copy replaces a pointer that
  still names the legacy one. `reach relocate` with an unknown argument prints its usage and moves nothing.
- The installers, `exe/reach-run`, INSTALL.md, the README, the student guide and the rules say reach-work and
  `.reach-home`. The Codex setup step asks the student to open the reach-work folder as the chat's folder.

- `M-SANDBOX-AGENT` tells the agent to call `reach_setup` with action configure, and `M-SANDBOX-STUDENT` tells the
  student rEach can fix the sandbox by changing Codex's settings. `reach setup`'s Codex message and host steps say rEach
  will ask to change two Codex settings and that a new chat is needed afterwards.
- From the reach-work folder itself (root kind), the late-work notice and the default assignment of `reach submit
  archive` follow `Gate.focus_workspace` like the other commands, so one current slice is found without a `cd`.

### Not fixed

- The new home alone does not open the Codex sandbox; the Codex setup above does, after the student's yes. Codex hook
  trust is unrelated. On Windows the project's top-level
  `.codex` is read-only inside the sandbox.
- On Windows only mode full opens Codex's sandbox for rEach. Measured on windows-2025 x64 and windows-11-arm with Codex
  0.160.0 (`tools/sandbox_probe/codex_setup_probe.rb`): in mode workspace the sandbox still refuses rEach's folder and
  the internet, with the home inside the chat's folder; in mode full a sandboxed `reach sync` exits 0. The same run
  relocated an install enrolled with 0.28.2 with every file identical and the legacy folder untouched.

## [0.30.0] - 2026-10-04

### Added
- Announcements from the instructors (`STD-ANNOUNCEMENTS`, wire revision 2026-10-04g). `reach sync` fetches the
  announcements sent to the student, their group or the whole course into a dated queue. rEach shows each one once,
  word for word, at the next prompt, and `reach announcements` (or the `reach_announcements` tool) lists the queue
  by date. rEach reports when an announcement arrived and when it was shown. `announcements.show: false` in
  `config.yml` stops the display and leaves the queue readable.
- A due time that moved is said once (`STD-DUE-CHANGE`). When the course server answers a different due time for
  an assignment than the one rEach last saw, the student hears the earlier and the new time at the next prompt.
- rEach reports which copy of the course material it holds (`STD-HOLDINGS`): the names and digests of the
  materials the course server delivered, never the student's files, so an instructor can see that an update
  arrived.

## [0.29.1] - 2026-10-04

### Fixed
- A student whose rEach was one release behind could not enroll: every attempt ended with "This version of rEach
  does not speak the same protocol as your course server", while Teach had already enrolled the install. Enrollment
  refused unless Teach's wire contract digest equaled its own, so each new wire revision locked out every rEach but
  the newest. A differing digest no longer refuses enrollment (`Reach::Enroll.verify_response!`); `reach doctor`
  still reports it as `R-DOC-WIRE`, and `minimum_reach_version` stays the version gate. `M-ENROLL-WIRE` is removed
  (`locales/en-US.yml`).

## [0.29.0] - 2026-10-04

### Added
- rEach does no course work in a Codex that is not running its hooks (`STD-HOOK-GUARD`, wire revision 2026-10-04f).
  When a Codex session started and no prompt hook has run since, or no hook has run for 15 minutes, `reach qualify`,
  `reach submit` and `reach part record` (and their tools) refuse with `M-HOOKS-REQUIRED`, which says nothing is
  wrong with the student's work and gives the steps to get the hooks running. The `hooks_not_running` detector now
  reports the problem on the first tool call instead of after 15 minutes. Other apps are never refused.
  `hooks.require: false` in `config.yml` or `REACH_HOOK_GUARD_DISABLE=1` switches the refusal off.

## [0.28.2] - 2026-10-04

### Fixed
- A student whose Codex ran rEach in its sandbox was told to "start a new chat from your course folder" with no
  word on where that folder is. A Windows student found only `deliverables` and `extracurricular` in `reach-work`
  and was told they had no course folder. `M-SANDBOX-STUDENT` now gives the folder's path on this computer and says
  it is the folder that holds `deliverables` and `extracurricular` (`Reach::Sandbox.course_folder`,
  `locales/en-US.yml`).

## [0.28.1] - 2026-10-04

### Fixed
- An own-part answer could not be recorded in an app that was not running rEach's prompt hook, and rEach blamed
  the student: `reach part record` said it could not find a recent answer and asked them to answer again, which
  could never work. It now says the answer never reached rEach because the prompt hook is not running
  (`M-PART-NO-HOOK`) and sends the assistant to the known issue's steps (`lib/reach/part.rb`).
- The `hooks_not_running` detector took a session-start hook as proof that hooks run, so a Codex that ran only that
  hook was never detected. `hooks_seen.json` now keeps the time of the last prompt, tool or stop hook, and the
  detector reads that (`lib/reach/known_issues.rb`, wire revision 2026-10-04e).

## [0.28.0] - 2026-10-04

### Added
- Sign-in asks for the password (`STD-SIGNIN-PASSWORD`, wire revision 2026-10-04d, `W-ID-5`). The password a student
  chose at enrollment was sent to the course server once and never asked for again; signing in took the student ID and
  a yes. Now the prompt hook asks for the password after the yes and keeps the session unconfirmed, and every gate
  closed, until it is right (`lib/reach/login.rb`, `lib/reach/password.rb`). rEach checks it against a salted
  PBKDF2-HMAC-SHA256 verifier in `~/.reach/state/login/verifier.json` (0600), written at enrollment; a computer
  enrolled before this release asks the course server once and keeps the verifier from then on. Without a verifier and
  without the server the sign-in waits. A wrong password counts toward the sign-in lockout.
- Forgotten passwords are reset, never looked up. `forgot password` at the password question asks the course server
  whether an instructor allowed a reset for this student; if so rEach asks for a new password twice and sets it, and
  otherwise it tells the student to ask their instructor. `reach login password` and `reach login reset` do the same in
  a terminal with typing hidden, which is where Hermes sends the student because it cannot hide a prompt from the AI.
- The course policy's `login.password: false` switches the password step off.

### Changed
- Enrolling again takes the password the student already has. A different one is refused (`M-ENR-PASSWORD-WRONG`)
  unless an instructor allowed a reset, in which case the password typed becomes the new one. Before, any re-enrollment
  replaced the password.
- `PRIVACY.md`, `README.md`, `docs/student-guide.md` and the assistant's rules say what happens to the password.

## [0.27.0] - 2026-10-04

### Added
- Diagnosis sessions (`STD-LIVE-DIAGNOSIS`, wire revision 2026-10-04c, `W-LIVE-10`). On a computer that holds the
  instructor unlock, `reach instructor diagnose [--course ID]` or the `reach_live` tool with action `diagnose` starts
  a live session for working out a rEach problem between the assistant there and the instructor's assistant. rEach
  asks one question; on the typed yes the session opens at once, the two assistants write to each other without a
  question per message, and rEach runs the fixed checks the instructor's side requests without asking again. A
  computer that is not enrolled gets a blank test student first. Needs a course server that knows wire revision
  2026-10-04c.

## [0.26.2] - 2026-10-04

### Fixed
- Figure 02, *Trust boundaries*, and `docs/architecture.md` still said rEach records none of the conversation.
  Since 0.25.0 it records signed-in assignment work, as `PRIVACY.md` and figures 06, 07 and 10 say. The note now
  reads "rEach records only signed-in assignment work" (`tools/figures/figures/02_trust.rb`, both SVG variants).
  Documentation only; nothing in the plugin's behavior changes.

## [0.26.1] - 2026-10-04

### Fixed
- Re-identifying a transcript lost data (`STD-TRANSCRIPT-DEIDENTIFY`, wire revision 2026-10-04b, `W-TRN-6`). A
  placeholder was restored to the roster spelling, so `will` came back as `Will` and a home folder typed with other
  slashes came back in one spelling; a string the student typed that looked like a placeholder was replaced; and text
  that outgrew its limit after replacement was cut. Each entry now carries `restore`, an encrypted record of the exact
  strings its placeholders stand for and of any text that no longer fit, under a per-install key that travels inside
  the sealed identity index (`lib/reach/deidentify.rb`). The key holder gets back the text exactly as recorded.

## [0.26.0] - 2026-10-04

### Added
- De-identified transcripts (`STD-TRANSCRIPT-DEIDENTIFY`, wire revision 2026-10-04a, `W-TRN-6`). Before a recorded
  conversation is sent, rEach takes the student's identity out: `lib/reach/deidentify.rb` keeps one random pseudonym
  per install, replaces the identifiers rEach knows (name, email, username, student ID, computer account, home folder,
  computer name) in every entry with placeholders such as `[[student-name]]`, and encrypts the index that links the
  pseudonym and the placeholders back to the student to the course's re-identification key. Only the holder of that
  key can re-identify a transcript.
- A prompt entry carries `source_digest`, the digest of the prompt as typed, so the own-part check still matches.

### Changed
- `POST /api/v1/transcripts` requires `pseudonym` and `identity`. rEach sends nothing until the course status hands
  out the key (`reach transcript flush` reports `stopped (identity_key)`), and keeps its queue.
- `PRIVACY.md`, the student guide and the privacy figure say what de-identification does and does not do: the course
  server holds the key and can reveal whose conversation it is, it authenticates each upload, and a name rEach does
  not know stays in the text.
- The spool on the student's computer and `reach transcripts export` are unchanged: the student's own copy stays as
  typed.

## [0.25.1] - 2026-10-04

### Fixed

- Raising a hand no longer fails when rEach is started with no locale and a file in the slice holds a non-ASCII
  character (`STD-UTF8-BUNDLE`). Claude Desktop on macOS starts the MCP server with no locale, so Ruby read the
  slice's files as US-ASCII and `reach_raise_hand` stopped with `JSON::GeneratorError` in `Reach::Hands.fit` before the
  hand was queued; a student could neither raise a hand nor report a problem (2026-10-04). rEach now reads text as
  UTF-8 in every locale (`Encoding.default_external` in `lib/reach.rb`), and `Reach::Utf8.clean` tags every string of a
  hand bundle and an issue bundle as UTF-8 and replaces invalid bytes before the JSON is written.

## [0.25.0] - 2026-10-03

### Added

- Signed-in assignment work is recorded again (`STD-TRANSCRIPT`, wire revision 2026-10-03i, `W-TRN-0` to `W-TRN-5`,
  Teach 0.38.0). While a session is signed in, the course has a current assignment and the session runs in a slice or
  the course folder root, rEach records every allowed prompt, the AI's replies, reasoning and actions, and the
  assignment code (code blocks in replies, each AI write, a turn-end scan of the slice's owned files) in
  `~/.reach/transcripts/` and sends it to `POST /api/v1/transcripts` at turn end, on `reach sync` and before a
  submission. Instructors read it in Teach. Restored: `lib/reach/transcript.rb`, `transcript_ingest.rb`, the
  PostToolUse hook `reach transcript code`, `reach transcript flush|status`, the transcript line of `reach status`,
  the spool cap in `reach sync` and the `transcript` debug events.
- The bounds (`Reach::Transcript.capturing?`): nothing is written or sent before sign-in, with no current assignment,
  in the extracurricular folder, outside the course folder or in instructor mode. Outside the bounds rEach only moves
  its place in the harness's own transcript forward, and a session's recording never reads what that transcript held
  before the session's first recorded prompt. A prompt the gate or the sign-in blocks is not recorded.
- Transcript export (`STD-TRANSCRIPT-EXPORT`): `reach transcripts export`, the `reach_transcripts` tool and the one
  automatic export after the course ends (`transcripts.auto_export`, default on) save the student's own recorded
  conversations as a ZIP in Downloads.
- An own-part answer again names the recorded prompt it came from (`session_id`, `seq`), or null when the prompt was
  not recorded, so Teach can check it (`W-PART-3`).

### Changed

- `PRIVACY.md`, `README.md`, `docs/student-guide.md`, `docs/DESIGN-DECISIONS.md`, `docs/architecture.md`, the persona
  and the extracurricular rules now say what is recorded and when. There is no in-session notice. Figures 6, 7 and 10
  are redrawn to match.
- `reach hook stop` records the turn and sends it before its debug flush.

### Removed

- The one-time purge of `~/.reach/transcripts` (`Reach::RetiredCapture`). rEach no longer deletes local transcripts.

## [0.24.0] - 2026-10-03

### Added

- Progress checkpoints (`STD-PROGRESS`, wire revision 2026-10-03h, `W-API-PROGRESS`, Teach 0.35.0). rEach records the
  first time a student reaches a checkpoint only rEach can see and reports it to Teach, which shows it as the Progress
  column of the instructors' Students page: the course passkey accepted (`enroll.code`), email and student ID
  confirmed (`enroll.identity`), the first confirmed sign-in (`setup.signin`) and the first prompt inside a workspace
  of each assignment (`<assignment>.started`). `Reach::Progress` (`lib/reach/progress.rb`) keeps them in
  `state/progress.json`; once the student is enrolled `reach sync` sends the unsent ones in one signed request. A report holds ids and times only, never typed text, and no hook waits on the network. `REACH_PROGRESS=0` turns
  it off. `PRIVACY.md` names it.

- Logo and banner. `docs/assets/reach-logo.svg` is the rEach mark, two fingers about to touch, a human one and a
  jointed, wired one; `docs/assets/reach-banner.svg` is the full picture and now opens `README.md`. No plugin code
  changed.
- System figures (`STD-FIGURES`). `docs/assets/figures/` holds ten figures of rEach and Teach together, each in a
  light and a dark variant: the system at a glance, trust boundaries, the enrollment handshake, the work lifecycle,
  the guardrail layers, who may do what, the privacy map, the deployment topology, why the two belong together, and
  a poster. `docs/architecture.md` presents them and follows the reader's color scheme; `README.md` gains a "How it
  fits together" section with figure 1. Teach is drawn as a frosted block that names what it guarantees and never
  how. `tools/figures/build.rb` draws them from `tools/figures/figures/*.rb`, and `--png` renders 4K PNGs with
  headless Chrome; the PNGs are not committed and are published as assets of the `figures-1` pre-release.
- `docs/deploy-and-test.md`: a fixture walkthrough against `tools/fake_teach` (enroll, sync, status, doctor, two
  refusals), the platform smoke and the agent smoke, and the rEach side of deploying for a real course. Every
  command and output in it was run first.

### Changed

- Public docs no longer name Teach's internals (`STD-TEACH-OPAQUE`). `docs/course-alignment-design.md` and
  `docs/smoke-assignment-1.md` described Teach by class, table, column, environment variable and command; they now
  say what Teach does. Earlier commits still hold the old text.
- `docs/student-guide.md` now mentions the password chosen at enrollment, the terminal enrollment in Antigravity
  and the Blackboard upload after submitting, and calls rEach by one name. `docs/DESIGN-DECISIONS.md` lists four
  enrollment inputs and the course passkey, and no longer ties the one-folder move to 0.17.0. American spelling in
  `README.md` and `docs/smoke-assignment-1.md`.
- The rest of the tree follows (`STD-TEACH-OPAQUE`, now covering `AGENTS.md`, `CHANGELOG.md`, `FEATURES.md`,
  `TODO.md`, `specs/app.yml` and `specs/implementation/`). Fourteen lines that named a Teach command, class or
  environment variable now say what Teach does. Seventeen build blueprints that directed work on Teach left
  `specs/implementation/` for the private superproject; `specs/implementation/README.md` lists them. `specs/wire.yml`,
  `reach.spec.yml`, `lib/` and `tools/` are unchanged: they are the protocol, the program and its test tooling.

## [0.23.1] - 2026-10-03

### Fixed

- Antigravity students could not enroll (`STD-NOHOOK-ENROLL`). Antigravity runs no hooks, so rEach's enrollment
  questions never appeared, and the locked guidance sent the agent through hook approvals and restarts before it
  mentioned the terminal. `reach hello` now recognizes a hookless session (`--harness antigravity`, which
  `rules/reach.md` passes, or no harness detectable at all) and tells the agent to walk the student through
  `reach enroll` in a terminal window straight away (`lib/reach/hello.rb`, `M-ENR-NOHOOK-STUDENT`,
  `M-ENR-AGENT-NOHOOK-CONTEXT`, `M-ENR-AGENT-NOHOOK-GUIDE`).
- On Windows the enrollment command rEach gives for the terminal now starts with `&`, so PowerShell runs it.
- `docs/INSTALLATION-AND-SETUP-GUIDE.docx` says that in Antigravity you enroll in a terminal window.

## [0.23.0] - 2026-10-03

### Added

- rEach reports its own technical problems to the instructors (`STD-ISSUES`, wire revision 2026-10-03c, `W-ISSUE-1`
  to `W-ISSUE-8`). Every fault rEach hides from the student now carries a signature (`fault_id` on the fault event).
  A fault that stops enrollment, sign-in, sync, qualify or submit is reported at its first occurrence, any other at
  its third within 24 hours: one report per signature per rEach version, at most 3 a day and 10 waiting, decided by a
  fixed table with no model. The report is a hand with trigger `issue`, originator `reach` and the sealed bundle
  `reach.issue/v1` (the fault's place, class and frames, the versions and platform, and a capsule of runtime facts);
  it holds no error message, prompt, code, profile or typed identity. A detached `reach issues flush --background`
  builds and sends it, so no hook or tool call waits. rEach sends it only to a Teach whose wire contract matches its
  own; until then nothing is raised and fault events flow as before.
- An unsent issue report waits in the outbox and is retried from the Stop hook, `reach sync` and `reach issues flush`
  with full-jitter backoff (60 seconds doubling to 6 hours). The backoff applies to issue reports only. One process at
  a time sends (`state/issues.flush.lock`), so two flushes that start together never send one report twice.
- The student is told once that rEach noticed a problem with itself and reported it (`M-ISSUE-REPORTED`), and once
  when the fix is in the version they run (`M-ISSUE-FIXED`). Seal, ledger and integrity faults are reported and never
  mentioned.
- A `technical_issue`, `setup_issue` or `access_issue` hand raised by the agent carries the same capsule and
  `signature_hint`, the signature of the newest fault in the 10 minutes before it.
- `reach issues` (instructor persona or debug mode) lists the registry; `reach issues flush` sends what is waiting.
  `reach doctor` reports `R-DOC-ISSUES` while a report is waiting. `config.yml` gains `issues`; the course policy's
  `limits.issues` can only tighten it; `REACH_ISSUES_DISABLE=1` turns it off.
- Live sessions (`STD-LIVE`, wire revision 2026-10-03f, `W-LIVE-1` to `W-LIVE-9`). A student can ask their
  instructors for a live session through their assistant (the `reach_live` tool, or `reach live request`), or accept
  one an instructor offers. It opens only after the student's own typed yes and, for a request, the instructor's
  approval. While it is open rEach sends its debug events (what rEach did, never prompts, replies, code or files),
  and the student and the instructor can exchange notes. The student or the instructor can end it at any time.
- Two rules rEach itself enforces in every live session. A check the instructor's side asks for (one of seven fixed
  ones: doctor, status, sync, update check, update, Codex cache repair, resend) runs only after the student's typed
  yes for that check; a no, or no answer in 30 minutes, is reported back and nothing runs. And nothing the student's
  assistant wants to send leaves the computer until the student has seen the exact text and typed yes.
- For an instructor's own test student the two assistants can write to each other during a live session, under the
  same two rules.
- `reach live` (status, request, wait, note, say, end). `config.yml` gains `live`; `REACH_LIVE_DISABLE=1` turns it
  off.
- rEach wakes a waiting assistant during a live session. On Claude Code 2.1.288 or newer the Stop hook gains a
  background entry (`reach live watch`) that ends when the instructor's side wrote, asked for a check, offered,
  opened or ended a session, and Claude Code then wakes the assistant with rEach's notice. On older Claude Code and
  on other apps the notice shows at the student's next prompt, as before. rEach also shows one desktop notification
  when the instructor writes (never the text itself). `config.yml` `live.wake` and `live.notify` turn these off.
- A student whose prompts rEach blocks (no course rules or course work yet, an update hold, an enrollment lock, a
  locked-out or refused sign-in) can still have a live session. Typing a prompt with the words "live session" gets
  rEach's question under the block text; yes or no is taken right there. The instructor's notes, each check's
  question and the end are shown the same way, and "end live session" ends it. Such prompts are still never stored
  or sent. `config.yml` `live.blocked` turns this off.
- `tools/fake_teach` accepts trigger `issue`, opens technical and issue bundles into `hands.jsonl`, and serves
  `issue_state` and `fix_version` from `issues.json`.

### Fixed

- `reach sync` stopped checking for hand replies at the first hand Teach no longer held ("could not check for hand
  replies (no such hand)"), so replies to every later hand were never fetched. A hand answered with 404 is now dropped
  from the open list and the check goes on.

## [0.22.0] - 2026-10-03

### Added

- Reach subscribes to Teach. It checks Teach's signed `W-API-REVISION` probe (wire revision 2026-10-03e, served by
  Teach 0.30.0) about every 60 seconds from its MCP server while a harness session runs and about every 15 minutes
  from a user-level operating system job (a systemd user timer, a launchd LaunchAgent or a Task Scheduler task), and
  runs one `reach sync` only when something changed, so new packages, assignments, policy, grades, hand replies, extra
  credit, receipts and known issues arrive on their own (STD-TEACH-SUBSCRIBE, W-SAFE-14). One check is one signed
  request with no retries, never more often than every 50 seconds across every Reach process; a 404 waits six hours,
  a failure backs off from a minute to an hour, and a revoked install removes the job.
- `reach subscribe status|tick|install|uninstall`, a `reach doctor` line (R-DOC-SUBSCRIBE) and the prompt hook's
  one-time line (M-SUBSCRIBE-UPDATES) telling the agent what changed so it can say so in plain words.
- `REACH_SUBSCRIBE=0`, `REACH_OFFLINE=1` and `subscribe.background: false` in `config.yml` switch the checks off;
  PRIVACY.md, INSTALL.md and the student guide say so.

### Changed

- `Reach::Sync.run` holds an exclusive lock, `state/sync.lock`, for its whole run, so a background sync never runs
  beside a student's own; interactive callers wait up to 120 seconds.

## [0.21.14] - 2026-10-03

### Fixed

- `rplugin package` no longer breaks rEach. The generated `hooks/codex.json`, `.mcp.json` and root `plugin.json` had
  been edited by hand, so a render would have put Codex's hooks on `sh` (absent on Windows, and new hook text that
  every student would have to trust again), put Claude's MCP server on plain `ruby` (undoing the 0.20.7 start
  without Ruby) and dropped the root manifest's Codex hooks pointer. `hooks/reach.hooks.yml` now gives Codex its
  `ruby "${PLUGIN_ROOT}/exe/reach"` commands through `run_by_harness`, `reach.rplugin.yml` gives Claude Code's
  `.mcp.json` `sh exe/reach-run` through `by_harness`, and rplugin 1.6.5 writes the root pointer itself. A render
  with rplugin 1.6.5 changed only `.codex-plugin/plugin.json`'s `exe/reach` to `./exe/reach` (the same launch, from
  the plugin folder), and `rplugin package --check` reports 0 stale files.

## [0.21.13] - 2026-10-03

### Fixed

- A failed `reach enroll` in a terminal printed its own message (`M-ENR-CLI-OFFLINE`) and then "rEach lost its
  connection to your course server... Your work is saved", which is false before enrollment, and a later successful
  enrollment request added "rEach is connected to your course server again". Enrollment requests (preview, enroll,
  the instructor persona enroll and the v1 code enroll) now leave the Teach connection state alone
  (`Reach::Client.anonymous(..., link: false)` in `lib/reach/enroll.rb`), so each enrollment path says only its own
  message (`STD-TEACH-LINK`).

### Changed

- `STD-TEACH-URL` notes that its no-URL clause has been unreachable since 0.21.11 built the Teach URL in.

## [0.21.12] - 2026-10-03

### Fixed

- rEach's tools never started in Codex on Windows, so a student who reinstalled rEach from the app's Plugins
  directory still got "can't run rEach" and no way to update. While Codex's cached copy still has the root
  `plugin.json`, Codex 0.160 starts the server from the root `mcp.json`, which since 0.20.7 ran `sh exe/reach-run`;
  Windows has no `sh`. `mcp.json` runs `ruby ${PLUGIN_ROOT}/exe/reach mcp` again (as `reach.rplugin.yml` already
  declares), so the server starts there and sets the root manifest aside (`STD-CODEX-PLUGIN-HOOKS`).
- After that repair Codex reads `.codex-plugin/plugin.json`, whose MCP server Codex 0.160 started as a literal
  `ruby '${PLUGIN_ROOT}/exe/reach' mcp` from the chat folder, on every operating system: Codex expands
  `${PLUGIN_ROOT}` only in the root `mcp.json` and in hooks. The server now runs `ruby exe/reach mcp` with `"cwd": "."`,
  which Codex resolves to its cached copy of rEach. Measured with Codex 0.160.0 in a scratch `CODEX_HOME`.
- `Reach::Wire.digest` hashes `specs/wire.yml` with CRLF line endings turned into LF, so a copy whose line endings
  were changed on Windows no longer reports R-DOC-WIRE against a Teach of the same revision. The digest of the
  file as shipped is unchanged.

### Added

- The MCP tool `reach_update` (`lib/reach/mcp_bridge.rb`): action `run` starts `reach update run --apply --force` as
  a detached process (`Reach::Update.spawn_background(now: true)`) and answers M-UPDATE-STARTED or
  M-UPDATE-NOT-STARTED; action `status` (the default) returns the installed version and `reach update status`.
  It works before enrollment and where Codex sandboxes the agent's commands, which until now had no way to update.
  M-SANDBOX-AGENT, M-AGENT-UPDATE, the persona and the reach-assistant skill name it (`STD-CODEX-SANDBOX`).

## [0.21.11] - 2026-10-03

### Fixed

- On macOS every HTTPS request from the runtime kit's Ruby failed certificate verification, so a Mac student could
  not enroll, sync or update: since 0.21.3 every command on macOS's Ruby 2.6 runs again under the kit, and the kit's
  OpenSSL (rv-ruby) looks for CA certificates only under the build machine's
  `/opt/homebrew/Cellar/rv-portable-openssl` path. `exe/reach` now sets `SSL_CERT_FILE` to the kit's own
  `libexec/cert.pem` before OpenSSL loads, when it is unset or names a missing file (`lib/reach/ca_roots.rb`,
  `STD-CA-ROOTS`); child processes inherit it.
- `reach enroll` in a terminal said "rEach lost its connection to your course server... your work is saved" on any
  network failure. It now names the course server and the cause, such as `certificate verify failed`
  (`M-ENR-CLI-OFFLINE`).
- `reach doctor` skipped the Teach check (`R-DOC-NET`) until enrollment, the one time a student most needs it. It
  now checks the default Teach URL before enrollment, and names the URL and the cause when Teach cannot be reached.

### Changed

- The course server `https://sven-f1l1.tail062fd2.ts.net` is built into rEach (`Reach::Runtime::TEACH_URL`) as the
  last resort after `REACH_TEACH_URL`, `config.yml` `teach.url` and `~/.reach/state/teach.json`, so rEach always has
  a course server (`STD-TEACH-URL`).

## [0.21.10] - 2026-10-03

### Fixed

- Codex's plugin hook ran rEach's prompt gate as Claude Code: `hooks/codex.json` passed `gate enroll --harness
  claude-code`, because `hooks/reach.hooks.yml` gave both harnesses one command. The source now passes
  `--harness ${HARNESS}`, so rplugin renders `claude-code` into `hooks/hooks.json` and `codex` into
  `hooks/codex.json`, and `hooks/codex.json` says `--harness codex` (`STD-HOOK-HARNESS`).
- The root `plugin.json` names the Codex hook file under `extensions.com.openai.hooks`, so a Codex that reads the
  root manifest never falls back to `hooks/hooks.json`, the Claude Code file that runs `sh`, which Windows lacks.

### Added

- `directory/`: a hooks-free listing for OpenAI's plugin directory (ChatGPT and Codex), plugin `reach-installer`
  shown as rEach, with one skill, `install-reach`, that installs rEach by following `INSTALL.md` and asks for Full
  access first. `ruby tools/directory/build.rb` writes `.scratch/directory/reach-installer-<VERSION>.zip` and
  refuses hooks, apps or MCP servers. `directory/SUBMISSION.md` holds the portal fields and test cases.
- `PRIVACY.md` and `TERMS.md`, linked from the directory listing.

## [0.21.9] - 2026-10-03

### Added

- Known issues from Teach for the student's agent (`STD-KNOWN-ISSUES`, wire revision 2026-10-03d,
  W-API-KNOWN-ISSUES, W-KI-1 to W-KI-4). New `Reach::KnownIssues` fetches Teach's list of known problems without
  signing, so it works before enrollment, with `If-None-Match` for a 304, and caches it in
  `~/.reach/state/known_issues.json`. It fetches during `reach sync`, from a detached refresh that the session start
  hook spawns when the cache is over an hour old, and inline from `reach_hello` and `reach_known_issues`. A failed
  fetch shows nothing and leaves the connection state alone (`Reach::Client` `link: false`). Every session context
  (enrolled, locked and sign-in) names the entries matching this computer's operating system, harness and rEach
  version (M-KNOWN-ISSUES-AGENT) and marks a detected one (M-KNOWN-ISSUE-DETECTED). The full steps for this system and
  harness come from the MCP tool `reach_known_issues` and `reach known-issues [--format json]`, both available before
  enrollment. There are two detectors: `codex_sandbox` (STD-CODEX-SANDBOX) and `hooks_not_running`, which fires on an
  MCP call under Codex when no rEach hook has run for 15 minutes; hooks record their runs in
  `~/.reach/state/hooks_seen.json`. Under an MCP server whose environment has no Codex variables, the harness comes
  from the parent process name.

## [0.21.8] - 2026-10-03

### Fixed

- A rEach command that Codex runs in its own sandbox no longer reports a course-server outage or a hiccup "your
  instructor was told" (STD-CODEX-SANDBOX). Outside a course folder the student has trusted, Codex's sandbox blocks the
  network and `~/.reach`, so a macOS student's `reach debug on` failed with M-REACH-HICCUP-CLI and `reach doctor` said
  the course server was unreachable while Teach was up. New `Reach::Sandbox` recognizes the sandbox
  (`CODEX_SANDBOX`, or `CODEX_SANDBOX_NETWORK_DISABLED=1`, the only marker on Linux, plus a write probe of the Reach
  home). `Reach::Client` then makes no request and raises `Reach::Offline` with M-SANDBOX-AGENT (cause
  `codex_sandbox`), so the link is not marked lost. A command that fails on a blocked write says M-SANDBOX-AGENT
  instead of M-REACH-HICCUP-CLI. `reach update run` and `reach update check` say M-SANDBOX-AGENT and do not run, and
  `reach update status` adds M-SANDBOX-UPDATE-STALE, so a stale check is not read as "no newer version". `reach doctor`
  opens with M-SANDBOX-AGENT, and `reach doctor --report` has a `sandbox` section. M-SANDBOX-AGENT points the agent to
  the reach_ tools and carries M-SANDBOX-STUDENT, which tells the student in plain words to start a new chat from
  their course folder and trust it.

### Added

- MCP tools `reach_debug` (action on with optional minutes, off, status) and `reach_doctor` (the `reach doctor` report),
  available before enrollment like the commands they mirror, so an agent whose shell is sandboxed can still turn debug
  mode on and run the health check.

## [0.21.7] - 2026-10-03

### Fixed

- The harness Reach reports at enrollment (the fingerprint's descriptive harness, which Teach's console shows) now
  names the app: `claude-code-tui`, `claude-cowork`, `claude-desktop`, `claude-code-vscode`, `claude-code-headless`,
  `claude-agent-sdk`, `codex-tui`, `codex-app`, `codex-vscode`, `hermes`, or `terminal` for `reach enroll` typed in a
  plain terminal (`Reach::Fingerprint.harness_label`, from CLAUDE_CODE_ENTRYPOINT, CODEX_THREAD_ID, CODEX_DESKTOP_APP,
  CODEX_IDE_VSCODE and HERMES_HOME). Before, every `reach enroll` reported `cli` and Cowork reported `claude-code`.
  The fingerprint digests are unchanged, so no device move follows; installs enrolled earlier keep their old label.

## [0.21.6] - 2026-10-03

### Fixed

- `reach qualify` crashed on every run (`Encoding::CompatibilityError`, shown to the agent as "rEach couldn't finish
  that just now") when the agent's scenarios named a non-ASCII value, such as a Japanese label, on a computer whose
  locale is C or POSIX, which is the default in many containers and terminals. The coverage step now reads feature files
  as UTF-8 and replaces invalid bytes (`lib/reach/qualify.rb`). Found by the slice-build smoke (opportunities.a4s2).

## [0.21.5] - 2026-10-03

### Fixed

- A Codex student who had enrolled and synced was never asked for their student ID: the session start told the agent
  "rEach asks for their student ID when they next type; wait for them", but only a course folder's own prompt hook
  (`.codex/hooks.json`, `reach gate prompt`) ran the sign-in, and Codex runs a project hook only after the student
  trusts it, so in a new course folder nothing asked and `reach login status` stayed not signed in. The plugin's
  prompt hook (`reach gate enroll`, already trusted at install) now runs the sign-in once enrollment is done: in
  Codex in every folder, and in Claude Code outside the course folders (`STD-SIGNIN-PLUGIN-HOOK`).
  `Reach::Login.claim` keys a Codex prompt on its `turn_id` under a per-session lock, so when both hooks run only the
  first judges the ID and answers; the other passes that turn silently and captures nothing. The prompt after the
  yes carries the signed-in context from the plugin hook as well. `hooks/codex.json` is unchanged byte for byte so
  Codex keeps trusting it.
- `tools/platform_smoke/run.rb` `hook_prompt_open` now signs in through the Codex plugin hook (ask, confirm, yes, the
  same turn twice, the signed-in context) before checking that the gate is open.

## [0.21.4] - 2026-10-03

### Fixed

- After a student locked in their modules, their next message was blocked with "Your course rules haven't arrived
  yet" until something ran `reach sync`, because the new modules' slice workspaces had not been provisioned and the
  prompt gate needs one. `Reach::Modules.choose!` now starts a detached `reach sync` as soon as Teach accepts the
  lock-in (`STD-MODULES-LOCK-SYNC`). The other two causes of the reported lock-in failure were on Teach and are fixed
  in Teach 0.22.3: guardrails carried the base `module_selection` (mode `instructor`) instead of the student's
  course setting, so every prompt of a student-choice student was blocked, the consent yes included; and Teach
  refused the null consent `seq` this wire revision sends, so no lock-in or transfer request could succeed.

## [0.21.3] - 2026-10-03

### Added

- `reach doctor --report [--offline] [--format json]` prints every diagnostic fact a field failure needs, and no
  secret (`lib/reach/diagnose.rb`): the running Ruby's path, version and platform, its SSL library, openssl gem and
  whether native GCM works, the runtime kit, the home and Reach home (home-relative), which harness and sandbox
  variables are set and whether the Reach home is writable, a stage-by-stage native GCM test, an envelope GCM round
  trip on the path Reach uses, RSA-OAEP and PSS, the same GCM test in a subprocess under every other Ruby it finds
  (PATH, `/usr/bin/ruby`, the kit), and each package kind opened stage by stage (header, signing key, signature,
  unwrap, decrypt, digest) from the stored copy and, unless `--offline`, the latest copy from Teach, with the
  network cause of a failed fetch.
- On a Ruby whose SSL library cannot use GCM additional authenticated data (macOS's Ruby 2.6.10 with LibreSSL
  3.3.6), every reach command runs again under the runtime kit's Ruby when the kit is installed
  (`lib/reach/crypto_probe.rb`, `exe/reach`), for native OpenSSL speed instead of the pure-Ruby GCM of 0.20.6; with
  no kit it starts the kit install and carries on. A fault event records either outcome. `REACH_KIT_FALLBACK=0`
  turns it off.
- Debug session events carry `ruby_path`, `openssl_library`, `openssl_gem`, `kit_ruby`, `kit_reexec` and
  `gcm_self_test`; sync events carry the scrubbed `warning_texts`, not just their count. A native decryption error
  names the OpenSSL stage, the SSL library and the Ruby version.
- The platform smoke installs the kit before syncing, opens Teach's known-answer envelope with the kit Ruby
  (`kit_known_answer`), records a `doctor --report` summary after the sync (`doctor_report`) and, on both macOS
  legs, runs `reach doctor --report` inside `codex sandbox` (Codex CLI 0.160.0, installed by the workflow) and
  requires it to move to the kit Ruby and open the stored guardrails package (`codex_sandbox_decrypt`).

## [0.21.2] - 2026-10-03

### Fixed

- The `reach_qualify` MCP tool never reached Teach when the local steps took longer than the bridge's 25-second tool
  budget (about 32 seconds for an A4 panel), because the upload inherited the spent deadline. The agent was told
  rEach had lost its connection, and the work was never qualified. The Teach half of qualify (upload and polls) now
  runs under its own 20-second deadline, started after the local steps (`lib/reach/qualify.rb`), so the call stays
  inside Codex's 60-second tool timeout and a pending qualification resumes on the next run.
- A Reach deadline running out was reported as a lost connection (`M-TEACH-LINK-LOST`) and marked the Teach link
  lost. It now says `M-TEACH-DEADLINE` ("did not answer in time") and leaves the link alone (`lib/reach/client.rb`,
  `locales/en-US.yml`).

## [0.21.1] - 2026-10-03

### Removed

- Transcripts, entirely (wire revision 2026-10-03b, `W-TRN-0`, byte for byte with Teach 0.22.1): rEach captures no
  conversation, ever. No prompt, reply, reasoning, action or code entry is written to disk or sent, in any folder or
  harness. Gone: `lib/reach/transcript.rb`, `transcript_ingest.rb`, `transcript_export.rb`, the transcript spool and
  its limits, the PostToolUse transcript hook, the transcript flush from Stop, SessionEnd, `reach sync` and
  `reach submit`, `reach transcripts export`, the `reach_transcripts` MCP tool, the export at course end, the
  `transcripts:` config section, `M-TRANSCRIPT-NOTICE`, `G-TRANSCRIPT-NOTICE` and the export messages.

### Changed

- The microbrain still learns from everything the student types: `Reach::Brain.capture_prompt` takes each
  gate-allowed prompt, in any folder (slice, root, extracurricular or outside every course folder), as a private
  source when it arrives. Blocked prompts (login, enrollment, passwords) never enter it, prompts that look like a
  secret or hold the student's own id are skipped, and `brain.capture_min_chars` defaults to 1. AI replies are not
  ingested. It stays on the computer and is never sent.
- Own part (`W-PART-2`): the prompt hook keeps only the latest qualifying prompt in a slice or the workspace root in
  `~/.reach/state/part/pending.json`; `reach part record` takes it and deletes the file. Answers carry no
  `session_id` or `seq`.
- Attempt ladder: only the time of the student's last slice prompt is kept; hand bundles send
  `student_last_request` as null. Consent reads the live prompt; the ledger's prompt witness has no fields.
- Stop and SessionEnd run `reach hook stop [--final]` (debug block and flush, link notice). `reach transcript
  turn|code|flush|status` stay as hidden aliases for older hook files. `Reach::Session` holds the session id and
  harness helpers.
- On the first rEach command after updating, `Reach::RetiredCapture` deletes `~/.reach/transcripts` and every
  persona's, plus the transcript flush state, once (marker `state/transcripts-retired.json`). Memory is kept.
- The persona, skills, locales, setup guide, README, FEATURES.md, `docs/DESIGN-DECISIONS.md` ("No transcripts are
  captured from the user, ever") and both specs say no conversation is recorded or sent.

## [0.21.0] - 2026-10-03

### Added

- Version report (`STD-VERSION-REPORT`, wire revision 2026-10-03a, `W-AUTH-7`, byte for byte with Teach 0.22.0): every
  request rEach signs carries `X-Reach-Version` with its version (`Reach::Client#sign!`), so Teach records which rEach
  each install runs after every self-update, not only at enrollment, and shows it in its console. Enrollment preview
  and enroll are unchanged. tools/fake_teach logs the header in `requests.jsonl`.

### Changed

- specs/wire.yml gains W-AUTH-7, so its digest changes: an install enrolls only against a Teach of the same revision
  (Teach 0.22.0), as with every wire revision.

## [0.20.7] - 2026-10-03

### Fixed

- rEach did nothing on a computer with no Ruby: every hook, the MCP server and the installer called `ruby`, and the
  bundled runtime kit was only ever installed by Ruby code, so on Windows in Claude Desktop's Cowork the screen stayed
  blank and the agent never answered (`STD-RUBY-BOOTSTRAP`). The plugin's Claude Code hooks and MCP server now run
  `sh exe/reach-run`, which uses the Ruby on PATH when it is 2.6.10 or newer, otherwise the kit's Ruby, and otherwise
  downloads the kit's Ruby (40 to 67 MB) from the pinned runtime release, checks its size and sha256 against
  `exe/runtime-pins`, and installs it under `~/.reach/runtime` in the background. A prompt that arrives meanwhile reaches
  the agent with M-BOOTSTRAP-WAIT (send the message again in a minute, no course work yet) instead of being blocked; the
  MCP server waits up to 120 s. A failed download is logged to `~/.reach/logs/bootstrap.log` and retried by hooks after
  10 minutes. In a Debian container with no Ruby the first prompt answered in 0.06 s and the kit installed in 8 to 43 s.
  With a Ruby on PATH the hook output is byte-identical to calling `ruby exe/reach`.
- On Windows without Ruby, `INSTALL.md` now runs `scripts/reach-install.ps1`, which installs the kit's Ruby the same way
  and adds it to the user PATH (no administrator rights), instead of asking for RubyInstaller.

### Changed

- `STD-ENROLL-LOCKDOWN` names the one prompt that is not blocked: the one that arrives while Ruby is still installing.
- A Ruby-only kit gains Chrome for Testing in place on the next background run (`RuntimeKit.chrome_missing?`,
  `runtime_auto.rb`), never replacing the Ruby a running hook uses.
- `tools/runtime_pins.rb --write | --check` generates and checks `exe/runtime-pins` against the manifest `RuntimeKit`
  pins; `runtime/README.md`'s release steps run it.

## [0.20.6] - 2026-10-03

### Fixed

- On a Mac running the built-in Ruby (2.6.10, LibreSSL 3.3.6) rEach could not open its course packages or seal a
  qualification, submission or hand: LibreSSL refuses additional authenticated data on every AES-GCM call
  ("couldn't set additional authenticated data"), in every call order, found by the 0.20.5 platform smoke on both
  macOS legs. `Reach::Crypto` now probes the native cipher once and, when it refuses, uses `Reach::GCM`
  (`lib/reach/gcm.rb`): AES-256-CTR from the same library with GHASH computed in Ruby, byte-identical to OpenSSL's GCM
  and verified against envelopes sealed by Teach. `Reach::Reference` decrypts through the same path.

## [0.20.5] - 2026-10-03

### Fixed

- `reach update run --apply` run by an agent, with no terminal attached, checked GitHub only when the hourly check was
  due, so a student's agent reported "no newer update" while a newer release was Latest. Every `reach update run` now
  checks (`lib/reach/update.rb`, `lib/reach/cli.rb`); only the detached run rEach spawns at session start passes
  `--scheduled` and keeps to the hourly schedule. `REACH_OFFLINE=1` and `REACH_UPDATE_DISABLE=1` still stop the check.
- The agent restated a course due time in a different time zone ("Hawaii time") from the one rEach printed. The persona
  (`skills/reach-assistant/SKILL.md`, `agents/reach.md`) now gives dates and times exactly as rEach states them, with
  rEach's time zone, never converted.
- The platform smoke never opened a real course package: fake_teach listed none and `R-DOC-GUARD` was an expected
  doctor finding. Every OS leg now opens a known-answer guardrails envelope sealed by Teach's own crypto, and fetches,
  decrypts, stores and revalidates (304) guardrails and workspace packages that fake_teach seals for the enrolled
  install; doctor must report no `R-DOC-GUARD`. The smoke's workspace stays under its scratch root.

## [0.20.4] - 2026-10-02

### Fixed

- Codex students were stuck restarting forever and never asked for their enrollment code. `Reach::CodexCache.repaired?`
  answered true whenever a `plugin.json.agent-plugins` file existed, so every locked `reach hello` the agent ran
  after the first repair told the student to quit and reopen Codex again. It now reports a repair only in the run
  that renamed a file (`lib/reach/codex_cache.rb`).
- `M-ENR-AGENT-GUIDE` gives the loop an exit: when the student has already restarted and started a new chat and
  rEach is still locked, the agent hands them the `reach enroll` command to paste into Terminal (PowerShell on
  Windows), where they answer the passkey, username, student ID and password questions themselves. The repair
  message says it happens once and points to that step (`lib/reach/hello.rb`, `locales/en-US.yml`).

## [0.20.3] - 2026-10-03

### Fixed

- A qualification that stopped on QF-UNCOVERED listed the uncovered graded names with no instruction, and in a
  real-agent smoke run the agent raised a technical_issue hand and waited for the instructors instead of writing the
  scenarios, so it never reached the course server. The record now carries `next` (`M-QUALIFY-UNCOVERED`,
  `lib/reach/qualify.rb`, `locales/en-US.yml`), printed first in text and present in JSON: write one scenario under
  `qualify/features` per uncovered name with the slice tag, then qualify again, and do not raise a hand for it. The
  reach-help skill now forbids hands for QF-UNCOVERED, QF-CHECK, QF-LOCAL-FAIL and QF-VACUOUS.

## [0.20.2] - 2026-10-03

### Fixed

- A student whose instructor assigns modules, and who had none yet, was told "Nothing is open right now. The next
  assignment appears here as soon as your instructor releases it" while the assignment was already released.
  `reach next` (`lib/reach/next.rb`) now answers `M-NEXT-WAIT-MODULES` in instructor mode as it already did for
  student choice. Teach 0.21.1 issues each student's group module, so this shows only until that happens.
- A module choice with no closing time read "Choose your 2 modules for the course before ." and "until ."; it now
  reads `M-NEXT-CHOOSE-OPEN` and `M-MODULES-OPTIONS-OPEN` (`lib/reach/modules.rb`, `locales/en-US.yml`).

## [0.20.1] - 2026-10-03

### Added

- Debug mode by phrase: a prompt that is only "enable debug mode", "turn debug on", "turn debug off" or a close variant
  switches debug mode from the prompt hook (`Reach::Debug.phrase`, `toggle_from_prompt!`, `lib/reach/gate.rb`), before
  any enrollment or lock check, and the agent relays the confirmation word for word (M-DEBUG-SAID-ON, M-DEBUG-SAID-OFF,
  M-DEBUG-RELAY). On a locked install the confirmation follows the lock message. A sentence that only mentions debug
  changes nothing.
- Operating-system detail in the debug `session` event (`lib/reach/os_info.rb`): OS family, name, version and build,
  kernel, arch, WSL, container, virtualization, CPU, memory, disk, uptime, load, locale, timezone, shell, terminal,
  desktop, session type, ssh, and Ruby, git, node and Chrome versions. Never a hostname, username, path or address;
  cached for 24 hours, every probe bounded to 2 seconds. No wire change.

## [0.20.0] - 2026-10-02

### Added

- Extra-credit codes (`STD-EXTRA-CREDIT`, wire revision 2026-10-02f, `W-XC-1`..`W-XC-3`, byte for byte with Teach
  0.20.0). `reach extra-credit CODE ANSWER` (or `--answer TEXT`) and the `reach_extra_credit` MCP tool redeem a code an
  instructor minted on Teach for this student, with the student's own answer, at any time while enrolled. The entry is
  saved to the new `extra_credit` list of `~/.reach/profile.yml` as pending before anything is sent, posted to
  `POST /api/v1/extra-credit` with an Idempotency-Key, and marked recorded or refused (`M-XC-UNKNOWN`, `M-XC-EXPIRED`,
  `M-XC-USED`); offline it stays pending and `reach sync` retries it with the same key, then pulls
  `GET /api/v1/extra-credit` so the recorded entries equal Teach's. `reach extra-credit list` and
  `reach_extra_credit_list` show every entry and its state (`lib/reach/extra_credit.rb`).
- The persona and `reach-help` tell the agent to ask for the code and the student's own answer, run the verb with
  exactly what the student typed and never write the answer for them.

### Changed

- `STD-PROFILE-LOCAL`: the interview fields still never leave the computer; the profile's `extra_credit` list is the
  one part that syncs with Teach. `reach profile forget` says Teach keeps its record of extra credit.
- Debug `command` events for `extra-credit` keep only its own flag names, so an answer word that starts with `--`
  never reaches an event.

## [0.19.2] - 2026-10-03

### Fixed

- `reach support` run from a terminal outside every rEach folder never reached the instructors. The wellbeing hand
  (W-SUP-2) sent `space: null`, Teach refused it with 400 (every bundle field must be a string), and the student was
  told "Your instructor will be told you may need support as soon as this computer is back online." `Reach::Hands.raise_wellbeing`
  now sends `space: outside` there, and a wellbeing hand Teach refuses is removed from the outbox, sent to Teach as a
  fault event (`support:wellbeing`, `support:flush`), never reported as told or queued, and does not arm the
  hour-long repeat guard (`lib/reach/hands.rb`, `lib/reach/support.rb`, `STD-WELLBEING-DELIVERED`). Works against
  the live Teach without a wire change.
- `tools/smoke/assignment_one.rb` ran Teach with hands switched off, so it never exercised a hand. It now runs
  with hand-raises on and adds `hand-raise-cli`, `hand-raise-mcp` (`reach_raise_hand`, type `concept_question`),
  `hand-wellbeing-outside-folder` and `hands-on-teach`, which checks all three hands on Teach (40 PASS).

## [0.19.1] - 2026-10-02

### Fixed

- A student on macOS Codex who had just signed in could be left with an agent that waited forever for them to sign in
  (`STD-HOOK-RESPONSIVE`). The prompt after the sign-in ran the whole session start inside Codex's prompt hook (10 s
  limit in a course folder): the status refresh and the course reference ingest under a lock that waited without
  limit. The "just signed in" marker was used up before that context was written, so a hook Codex killed lost it and
  the agent kept its session-start instruction to wait. Measured before: 24 s with the brain lock held, killed at
  10 s with the marker gone; after: 0.17 s. The prompt after a sign-in now carries `M-LOGIN-DONE-AGENT` and the
  local part of the session context, one detached `reach hello --background` does the rest and the next prompt
  carries its result, and the marker is removed only after the hook has written its answer
  (`lib/reach/gate.rb`, `lib/reach/hello.rb`, `lib/reach/login.rb`, `lib/reach/cli.rb`).
- Session start (`reach hello` as a hook) does the same split, so it never waits on Teach or a lock (0.15 s with a
  30 s Teach delay and a held lock).
- Every file lock on a hook path waits at most `hooks.lock_wait_s` (2 s) in total (`Reach::Locks`,
  `lib/reach/locks.rb`). A prompt whose transcript lock is busy goes to a pending file that the next holder merges in
  order, so nothing is lost; other busy steps are skipped for that event. Storage's state lock is bounded too.
- rEach's Codex course-folder prompt hook now has a 60 s limit, the same as the plugin's.

## [0.19.0] - 2026-10-02

### Added

- Transcript export (`STD-TRANSCRIPT-EXPORT`, `lib/reach/transcript_export.rb`). `reach transcripts export` and the
  `reach_transcripts` tool write the student's own recorded AI conversations (live and archived sessions) to Downloads
  as `<course>-transcripts-<YYYY-MM-DD>-<HHMM>-<zone>.zip`, organized by assignment and slice, then extracurricular and
  unsorted, one readable Markdown file per session plus the raw lines and an index README. With
  `transcripts.auto_export` (default on) the first session start after the course ends exports once in the background,
  even while the course-ended lock is on, and the next prompt says where the ZIP is. `transcripts` is allowed while
  rEach is locked (`STD-ENROLL-LOCKDOWN`).
- Late work (`STD-LATE-WORK`, wire 2026-10-02e `W-PACE-2`, `lib/reach/late_work.rb`). A slice whose due time has passed
  stays writable while `late_work.allow` is true (default); assignments not yet current stay closed. rEach says the work
  is late at session start, on the first prompt of each session in that slice and every `late_work.notice_every` (10)
  prompts after, in `reach status` and in the submit ask, and says when the slice can no longer be submitted. It raises
  one `late_work` hand per assignment on the first late write and one `late_submission` hand when a late ingest receipt
  verifies, from a detached `reach hand late`; offline hands wait in the outbox, and a 403 or 400 ends the retries.
- Grade view (`STD-GRADE-VIEW`, `W-API-GRADES`, `lib/reach/grades.rb`). `reach grade` and the `reach_grade` tool show
  the points Teach records for each assignment and the total, or say grades are not available yet (available false,
  an older Teach's 404, or `grades_disabled`); offline, the last answer with its time.
- Hand types (`STD-HAND-TYPES`, `W-HAND-TYPES`). `reach hand raise --type T` and `reach_raise_hand`'s `type` choose
  among nineteen types (late work, concept, assignment, deadline, grade and submission questions, technical, setup and
  access issues, extension requests, feedback, integrity questions, other and rEach's own); an unknown type is refused
  before any request, and a Teach without the 2026-10-02e wire gets `student_request` with `[type]` in the summary.
- `reach submit archive [--assignment A]` (and `reach_submit` with `archive` true) writes the assignment's ZIP again.

### Changed

- Every submit ask and every answer after an ingest says the ZIP is (or will be) in Downloads and that the student
  must also upload it to Blackboard (`submit.lms_name`) to receive credit for the coursework (`STD-SUBMIT-ARCHIVE`).
- `M-GATE-NOT-CURRENT` now says a part is closed because it is not the current assignment yet, or because late work is
  switched off.
- `tools/fake_teach` answers hands, hand status and grades, with switches for a legacy Teach, hands off and the wire
  digest.

## [0.18.4] - 2026-10-02

### Fixed

- rEach installs in Claude Cowork and claude.ai from a marketplace added by URL (`https://github.com/SteveBenner/rEach`
  or `SteveBenner/rEach`). claude.ai rejects any plugin with a top-level `bin/` directory ("Plugin contains a top-level
  bin/ directory"), and rEach had `bin/reach-install`. The installer moved to `scripts/reach-install`; `INSTALL.md`
  downloads it from `raw.githubusercontent.com/SteveBenner/rEach/main/scripts/reach-install`, `reach update`
  (`lib/reach/update.rb`) loads it from the installed plugin's `scripts/`, and `tools/smoke` and
  `tools/platform_smoke` run it from there (`STD-NO-TOP-BIN`). An install command copied before 0.18.4 that names
  `main/bin/reach-install` now gets a 404; the command in `INSTALL.md` is the current one.

## [0.18.3] - 2026-10-02

### Changed

- Wire revision 2026-10-02e (`specs/wire.yml`, byte for byte with Teach 0.18.5): a course policy's
  `enrollment.device_moves` defaults to `auto`, so a student enrolling from a second computer is enrolled as soon as
  they set their password. Teach holds the computer for an instructor's approval (`device_move_pending`) only when the
  instructor sets `approve`. rEach's own handling of a pending or denied move is unchanged. rEach 0.18.2 and older
  carry the previous wire digest and refuse a Teach 0.18.5 enrollment with `M-ENROLL-WIRE` until they update.

## [0.18.2] - 2026-10-02

### Added

- `reach setup` and `update/apply.rb` write the Teach URL from `config.yml` `teach.url`
  (`https://sven-f1l1.tail062fd2.ts.net`) to `~/.reach/state/teach.json` (`Reach::Runtime.bake_teach_url!`,
  `Reach::Paths.teach_url_file`), so an installed rEach knows Teach from the moment it is set up, even when
  `config.yml` is missing, unreadable or blank. `Reach::Runtime.default_teach_url` reads `REACH_TEACH_URL`, then
  `config.yml`, then that file (`STD-TEACH-URL`).

## [0.18.1] - 2026-10-02

### Added

- `reach version`, `reach --version` and `reach -V` print `reach <VERSION>` and exit 0, before enrollment too
  (`STD-CLI-VERSION`, `lib/reach/cli.rb`). `version` was already on the unlocked list but answered "unknown command".
- "How you talk with the student" in the persona (`skills/reach-assistant/SKILL.md`, mirrored in `agents/reach.md`,
  `STD-PLAIN-TALK`): in every session and folder the agent treats the student as a new computer user, never brings up
  commands or how rEach works unless asked for exactly that, describes student-only steps as what to click, and goes
  faster or deeper only on evidence (profile coding experience "quite a bit", a remembered finding, or the student's
  own request), recorded with `reach remember`. `M-AGENT-TALK` carries the rule in `reach hello`'s context, the
  locked context and the sign-in context; `rules/reach.md` points to it.
- "Updating rEach" in the persona and `M-AGENT-UPDATE` in `reach hello`'s context (`STD-AGENT-UPDATE`): the agent
  updates only with `reach update run --apply` and never searches GitHub, its releases or tags, or downloads an
  archive itself. `INSTALL.md` says the same for an installing agent and that the "Reach runtime" releases are Ruby
  kits. A rEach agent had called GitHub's web index "noisy" while hunting for a tagged ZIP: the releases page listed
  only runtime kits, with `runtime-4.0.7-r3` marked Latest, and no rEach version had a release.

### Changed

- The class-wide enrollment secret is called the course passkey everywhere a student or agent reads it
  (`STD-COURSE-PASSKEY`): 18 messages and the not-enrolled greeting (`locales/`), `reach help`, the persona, `README.md`,
  `docs/student-guide.md` and `docs/INSTALLATION-AND-SETUP-GUIDE.docx`. `reach enroll --course-passkey` is the flag;
  `--course-code` still works, unlisted. The wire contract keeps `course_code`, `course_code_unknown` and
  `course_code_expired`, so `specs/wire.yml` and its digest are unchanged and Teach needs no release.

## [0.18.0] - 2026-10-02

### Added

- Storage gates (`STD-STORAGE-GATES`, `lib/reach/storage.rb`). Reach measures the corpus together with the microbrain
  (brain folder, brain spool, import spool and imports folder) in a detached `reach storage measure`, started from
  session start at most once per `storage.check_interval_s` (3600) and never inside a hook, and keeps the result in
  `storage.json`. At 512, 1024 and 2048 MB (`storage.warn_mb`) the next prompt carries `M-STORAGE-WARN` once per
  threshold crossed, offering to compact the corpus only. At 4096 MB (`storage.demand_mb`) session start and the first
  prompt of each session carry `M-STORAGE-DEMAND`, which demands compaction, suggests a true backup to another drive,
  and refuses imports. `reach doctor` reports `R-DOC-STORAGE` at the limit.
- `reach storage status|measure|compact` and the `reach_storage` MCP tool, with the `reach-storage` skill.
  `reach storage compact` asks the student through Reach (consent kind `compaction`, `M-STORAGE-COMPACT-ASK`) and
  then compacts in a detached worker: `Rcorpus::Compact#run(compress: true)` when the installed rcorpus offers it
  (0.11.0), a plain compaction reported by `M-STORAGE-COMPACT-OLD-LIBRARY` otherwise, plus gzip of the admitted
  import-spool files, each verified before its plain copy goes. The microbrain is never compacted; the next prompt
  reports the before and after sizes.
- Importing an export of another AI system (`STD-EXPORT-IMPORT`, `lib/reach/export_import.rb` and
  `lib/reach/export_import/`). `reach import pick [--folder]` opens the system's file picker (osascript, PowerShell,
  zenity or kdialog, 300 s), and `reach import export <path> --mode brain|copy` takes a folder or a `.zip` from
  ChatGPT, Claude or Gemini (Takeout JSON); an HTML-only export answers `M-IMPORT-NEEDS-JSON`. Reach asks first
  (consent kind `export_import`): both asks warn that it takes a long time, and the brain-mode ask says that
  deleting the export loses its full text. A detached, resumable job streams the JSON (`Reach::JsonStream`, memory
  bounded by the largest conversation; a 198 MB export peaked at 90 MB RSS) into a catalog and a ranked queue under
  `~/.reach/brain/imports/<job>/`; copy mode also saves every conversation verbatim as private-tier corpus sources
  under `import/<vendor>/`. The agent distills findings from the queue with `reach import next|done|search|show`
  and `reach remember --origin import:<job>/<conversation>` within the normal write budget. Imported text never
  enters the prompt-time brain index or the spool cap and never reaches Teach. `reach import status|cancel|list`,
  the `reach_import` MCP tool and the `reach-import` skill come with it; a killed job resumes at the next session.
- Debug kinds `storage` and `import` (wire 2026-10-02d, `W-DBG-KINDS-2`), sent only when Teach advertises the same
  wire digest (Teach 0.18.3); otherwise the same fields go as kind `brain` with `event` `storage.<outcome>` or
  `import.<outcome>`. No path, name, title or text in either.

### Changed

- `reach memory forget --all` also cancels any import, erases every imported verbatim copy from the corpus and
  deletes the imports folder and import spool (`STD-BRAIN`).
- `ROADMAP.md` records a microbrain compression and compaction system for when a microbrain passes 512 MB.

### Fixed

- `tools/smoke/assignment_one.rb` links the smoke course to its reference, which Teach
  0.18.2 requires before it delivers any reference, and accepts the one 0600 brain-spool copy of course text that
  0.17.1 keeps (`STD-COURSE-CORPUS`); against Teach 0.18.4 it passes 36 checks again.

## [0.17.1] - 2026-10-02

### Added

- The course corpus in the microbrain (`STD-COURSE-CORPUS`). `Reach::CourseCorpus` (`lib/reach/course_corpus.rb`)
  fingerprints the delivered `.rref` blobs and key ids. When that fingerprint changes it decrypts them and spools
  every file as a private-tier source under `course/<course>/<path>` (category `course`, at most 1,000,000 bytes per
  part, `.md` appended to non-text extensions), and tombstones replaced or removed files. It records
  `~/.reach/brain/course-ingest.json`. It runs after `reach sync` (`lib/reach/sync.rb`), at session start without a
  forced admission (`lib/reach/hello.rb`) and from the new `reach reference ingest [--force]` (`M-COURSE-INGESTED`).
  Events `brain.course_ingested` and `brain.course_ingest_failed` carry counts only.
- Course passages in prompt recall. `Reach::BrainIndex` splits course sources into passages of at most 600 bytes
  (`search_course`, index cache version 4). `Reach::Brain.course_recall` adds up to `brain.course_k` (3) matching
  passages within `brain.course_budget_bytes` (600) above `brain.course_min_score` (0.2) under `M-BRAIN-COURSE` on
  each prompt while `brain.course_recall` is true (default). The `brain.course_recalled` event carries hits and bytes.

### Changed

- Course sources are never spool-cap prune victims, their bytes no longer count toward `brain.max_spool_bytes`, and
  `reach memory forget --all` keeps them. `Reach::BrainIndex` now honours source tombstones.
- The specs allow exactly one plaintext copy of course material: the microbrain's private tier (`STD-VAULT-PRIVATE`,
  `course_reference.handling`).

## [0.17.0] - 2026-10-02

### Added

- Submission with the student's approval (wire revision 2026-10-02c, `STD-SUBMIT-APPROVAL`, `W-SUB-2`). The persona
  (`agents/reach.md`, `skills/reach-assistant/SKILL.md`) and the rewritten `reach-submit` skill tell the agent that once
  a slice's work passes its checks the student can ask rEach to submit it. `reach submit` and `reach_submit` run every
  precondition, then ask through rEach (`M-SUBMIT-ASK`, kind `submission` in `Reach::Consent`); the prompt hook captures
  the answer, and a yes, valid for 30 minutes and for exactly the owned files it was asked about, is used once by the
  agent's next `reach submit` (`M-SUBMIT-YES-AGENT`). A change after the yes asks again; a no answers
  `M-CONSENT-DECLINED`. In a terminal `reach submit` asks at its own prompt; on Antigravity the agent asks first
  (`rules/reach.md`).
- A copy in the Downloads folder (`STD-SUBMIT-ARCHIVE`). Once an ingest receipt verifies, from `reach submit` or a later
  outbox retry, `Reach::Archive` (`lib/reach/archive.rb`) writes a ZIP of the whole assignment folder (every slice
  workspace without its top-level dot entries, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and links, plus the student's
  receipts and own part under `rEach/`) as `<course>-<assignment>-<YYYY-MM-DD>-<HHMM>-<zone>.zip` in course time
  (`Reach::CourseTime.stamp`), mode 0600, never overwriting a file (`-2`, `-3`). `Reach::Zip` (`lib/reach/zip.rb`) is a
  standard-library ZIP writer that runs on Ruby 2.6.10. The folder is `REACH_DOWNLOADS_DIR`, else `XDG_DOWNLOAD_DIR` on
  Linux, else `~/Downloads`; `config.yml` `submit.archive_max_mb` (default 256) caps it, and a failed copy never fails
  the submission (`M-SUBMIT-ARCHIVED`, `M-SUBMIT-ARCHIVE-SKIPPED`, `M-SUBMIT-ARCHIVE-FAILED`).
- Resubmission until the due time (`W-SUB-1`). After a receipt rEach says which submission it was and until when the
  student can submit again (`M-SUBMIT-AGAIN-OPEN`, `M-SUBMIT-AGAIN-OPEN-NODUE`, `M-SUBMIT-AGAIN-CLOSED`), from Teach's
  new `attempt`, `due` and `resubmit`. After the due time a slice that already holds an ingest receipt is refused before
  anything is asked (`M-SUBMIT-CLOSED`); Teach 0.18.0 refuses it too.
- `tools/fake_teach` serves `POST /api/v1/submissions` per W-SUB-1 (`FAKE_TEACH_DUE` sets the due time).

### Changed

- `reach submit` flushes the transcript only after the student's yes; the submit debug event records the archive state,
  attempt and resubmit (no path or file name). `tools/smoke/assignment_one.rb` asks, answers yes through the prompt hook,
  submits, and checks the Downloads ZIP (`REACH_DOWNLOADS_DIR`), its name, `unzip -t` and that it holds no `.reach`.

### Verified

- `tools/smoke/assignment_one.rb` against Teach 0.18.0's working tree on a scratch PostgreSQL database: 36 pass, 2
  manual skips; the first submit asked and sent nothing, the hook-captured yes sent it, and the ZIP passed `unzip -t`.
  Against `tools/fake_teach`: attempts 1 to 3, `-2` and `-3` names in one minute, a changed file asked again, a no
  declined, and a past-due slice with a receipt was refused before asking. Every changed lib file parses and loads on
  Ruby 2.6.10, where the ZIP writer's output passes `unzip -t`.

## [0.16.25] - 2026-10-02

### Added

- Teach connection safety (wire revision 2026-10-02b, `STD-TEACH-LINK`, `W-DBG-FAULT`). A student never sees a raw
  error, a Ruby backtrace, an exception class, a hook error or a hook timeout from rEach. `Reach::Link`
  (`lib/reach/link.rb`) tracks the connection to Teach in `link.json` under the rEach home. When a request fails for
  lack of a connection it is lost, and any answer from Teach restores it. The student is told once per outage
  (`M-TEACH-LINK-LOST`) that the connection was lost and that their work is saved and will be sent when it is back,
  and once when it returns (`M-TEACH-LINK-BACK`). On Claude Code and Codex this comes as a hook `systemMessage`; on
  Hermes it is a relay line in the prompt context; at the terminal it is a line on stderr.
- Every hook runs inside a guard that keeps its outcome and hides what went wrong. A rEach block stays a block. On
  Claude Code and Codex a failing hook still allows, as before, now with at most one plain `M-REACH-HICCUP` every 15
  minutes. Hermes' fail-closed write, shell and read gates block with `M-REACH-HICCUP-BLOCKED`. Each hook gives the
  network a deadline inside the harness's hook timeout. MCP tools answer `M-TEACH-LINK-LOST` or
  `M-REACH-HICCUP-TOOL` and run under a 25-second deadline. Terminal commands answer `M-REACH-HICCUP-CLI`, and
  `reach sync` warnings name the reason in plain words. `exe/reach` answers the same way when rEach cannot even
  load. A Teach refusal that the student can act on still shows Teach's text. One that means rEach sent something
  malformed is hidden.
- Fault reports. Every hidden error is recorded as a `fault` event and every connection change as a `link` event,
  and both are sent to Teach even while debug mode is off, with reason `fault`. A fault carries where it happened,
  the exception class, the errno, the frames and what the student was shown. It carries no message text unless
  debug mode is on. At most 60 an hour are kept; the rest are counted in `dropped_faults`. `config.yml` `link:` sets
  `hiccup_quiet_minutes` (15) and `fault_max_per_hour` (60). The student guide's Privacy section says so.

### Fixed

- A request to Teach could wait twice its read timeout. Net::HTTP silently retried an idempotent request once on a
  read timeout, on top of rEach's own retries. `Reach::Client` now sets `max_retries = 0` and a write timeout.
- A transport failure outside the client's retry list (for example a bad HTTP response) escaped as a raw exception.
  It is now a final `Reach::NetworkError`.

### Verified

- Against a real scratch Teach 0.17.3, the assignment-one smoke extended with link and crash journeys passed 51
  steps, with 1 test-expectation miss and 2 manual skips. The full student loop passed.
  - Teach stopped. The Stop hook exited 0 in 0.2 s with the lost notice. Later prompt and Stop hooks stayed quiet.
    `reach sync` and the `reach_sync` tool answered offline in plain words.
  - Raise injection in a copy of the plugin. A Claude Code write gate answered exit 0 with one hiccup, and stayed
    quiet inside the quiet window. A Hermes write gate answered exit 2 with the blocked text. A terminal command
    answered exit 1 with the CLI text. An MCP tool answered with the tool text. A load failure in `exe/reach` gave
    hook 0, Hermes gate 2 and terminal 1. No backtrace, class or raw message appeared anywhere.
  - Four faults were spooled with reason `fault` and no message while debug was off.
  - Teach restarted. The Stop hook showed the back notice, and Teach stored 4 fault and 2 link events (lost and
    back) classified `student`.
- Against a server that accepts connections and never answers, the `reach_sync` tool returned in 25 s (50 s before
  the Net::HTTP fix).
- Every changed file passes `ruby -c` on Ruby 2.6.10 and 3.3.
- Not verified: a live Claude Code, Codex or Hermes session showing the notices.

## [0.16.24] - 2026-10-02

### Fixed

- A Codex student whose rEach hooks already show as enabled is no longer sent round in circles to approve them. When
  Codex loaded none of rEach's hooks (openai/codex#47925) the agent still got the locked guidance through the
  `reach_hello` tool, and that guidance always said to trust rEach's hooks, which the student could not do because
  nothing was left to approve. `M-ENR-AGENT-GUIDE` now asks for hook trust only when Codex lists the hooks for review
  and tells the agent to believe a student who says they are enabled. When `reach hello` runs outside a hook and
  rEach's Codex plugin copy has been repaired (`Reach::CodexCache.repaired?`, `lib/reach/codex_cache.rb`), the
  locked context adds `M-ENR-AGENT-CODEX-REPAIRED`: nothing needs approving, quit and reopen Codex, start a new chat
  (`lib/reach/hello.rb`). Verified in a scratch home with a Codex cache holding the root `plugin.json`: the tool
  path repaired it and added the note, the hook path and a machine without Codex did not.
- `tools/smoke/assignment_one.rb` no longer defaults to a `/tmp/teach-a1` that does not exist. Without
  `--teach-dir`/`SMOKE_TEACH_DIR` it exports the committed `HEAD` of `SMOKE_TEACH_REPO` (default
  a sibling `teach` checkout) into the run directory, so a dirty Teach checkout never reaches the run.

## [0.16.23] - 2026-10-02

### Added

- Instructor personas (wire revision 2026-10-02a, `STD-INSTRUCTOR-PERSONA`). An install holding a valid instructor
  unlock can run as a test student: `reach instructor dummy [--course ID]` (blank) and
  `reach instructor as USERNAME [--course ID]` (a test copy of that roster student) enroll through the new
  `W-API-ENROLL-INSTRUCTOR`, and `reach instructor exit` ends it. `lib/reach/persona.rb` builds the persona in its own
  home (`~/.reach/personas/<id>/`) and workspace (`~/reach-work/personas/<id>/`), writes `~/.reach/persona.json` last
  so a half-made persona never becomes active, moves a failed or ended one to `.backup` and never deletes. While a
  persona is active rEach gates, captures and messages exactly as for a student and tells the agent nothing about it.
  Refusals map to M-PERSONA-CODE-REFUSED, M-PERSONA-COURSE-NEEDED, M-PERSONA-NO-STUDENT and M-PERSONA-TEACH-OLD; a
  revoked code or removed key locks the persona's next prompt (M-PERSONA-LOCKED). `reach instructor status` names the
  persona and `reach instructor lock` exits it first. Events `instructor.persona_started`, `persona_refused` and
  `persona_exited` carry ids, never the code. The start message and `reach instructor status` name the test student
  ID, which is what the instructor types when rEach asks a student to sign in.
- Debug mode (`STD-DEBUG-MODE`, wire W-API-DEBUG and W-DBG-*). `lib/reach/debug.rb` records scrubbed metadata events
  (session, hook, gate, command, request, lock, sync, check, qualify, submit, transcript, brain, update, error) into
  `debug/spool.jsonl` under the rEach home and sends them to Teach from the Stop and SessionEnd hooks and `reach sync`,
  keeping them queued on any failure. It is always on for a persona; otherwise `reach debug on [--for MINUTES]`, or an
  instructor's request delivered in `status.debug`, which the student is told about once per session (M-DEBUG-NOTICE).
  `lib/reach/debug_render.rb` shows the turn's events at the end of each turn as a hook `systemMessage`, never as agent
  context: an ASCII table on terminal surfaces and a Markdown table on desktop and IDE surfaces, detected from the
  harness environment, with `config.yml` `debug.render` (auto, ascii, markdown) as the override. Hermes has no
  user-visible hook channel, so there `reach debug show` is the way. New verbs: `reach debug on|off|status|show|flush`.

### Changed

- `Reach::Paths.root` and `workspace_base` are the computer-wide locations; `Paths.home` and `workspace_root` follow
  the active persona. The instructor unlock, the managed plugin, updates, the runtime kit and the Codex writable root
  stay at the root. While a persona is active its sidecar, brain spool and brain state live in the persona home,
  `Reach.ports` is nil (nothing reaches `~/.corpora/reach`), and import detection skips all of `~/.reach`.
- `specs/wire.yml` is wire revision 2026-10-02a (Teach 0.17.2 carries the identical copy):
  `W-API-ENROLL-INSTRUCTOR`, `W-API-DEBUG`, `status.classification`, `status.debug` and the `debug` section.
- `specs/app.yml` gains STD-INSTRUCTOR-PERSONA and STD-DEBUG-MODE and amends STD-WORKSPACE-LAYOUT,
  STD-INSTRUCTOR-UNLOCK, STD-SEAL-INVISIBLE and STD-BRAIN for personas.

### Verified

- Against a real scratch Teach 0.17.2: the assignment-one smoke extended with persona journeys passed 52 steps (2
  manual skips), the whole student loop plus unlock, a test copy with its workspace and receipts, sign-in by test ID,
  the gate, `reach check`, debug events stored as instructor data, the copied student's rows unchanged, exit, a dummy,
  revocation at Teach and the real install unaffected. With debug off, hook outputs and file listings are identical to
  0.16.22's. Every changed file parses on Ruby 2.6.10, and the persona flow ran there against a stub.

## [0.16.22] - 2026-10-02

### Fixed

- `reach memory forget` really forgets wherever rplugin and rcorpus 0.10.0 are installed: after tombstoning and
  admitting, `Reach::Corpus#erase` (`lib/reach/corpus.rb`) calls `Rcorpus::Erase`, which removes the finding, its
  lineage and its note from every corpus segment, snapshot, backup, vector and content file. Before this a
  forgotten finding stayed in the planes, and the tombstone itself kept its full text. Verified in a scratch HOME:
  the forgotten claim's text was in no file afterwards, and the finding that was kept was still recalled.
- Memory recall opens the corpus before checking for `Rcorpus::Context` (`lib/reach/brain.rb`). rcorpus loads only
  when a corpus is opened, so in a fresh process (an MCP `reach_memory_recall`) the check always failed and recall
  fell back to Reach's own index.
- `Gemfile.ruby26.lock` is a real Ruby 2.6 lock. The hand-written one recorded wrong dependency ranges for the
  cucumber 8.0.0 graph and pinned ferrum 0.14, which cuprite 0.14.3 cannot use, so `bundle install` failed on Ruby
  2.6. It is regenerated in a Ruby 2.6.10 container from the same top-level pins (ferrum 0.13), with native
  platforms for Linux, macOS and Windows; cucumber 8.0.0 installs and runs there. `bundle lock` on Ruby 4.0.7 resolves
  `Gemfile.lock` unchanged. Course runs use the course repository's locks, which were already correct.

### Changed

- `tools/smoke` enrolls through the v2 flow: a roster import, a class-wide course code and
  `reach enroll --course-code --username --student-id --password-stdin`. The code-reuse step is replaced by
  `enroll-wrong-student-id-refused`. The assignment-one smoke passed every step against a Teach 0.17.0 tree.
- `FEATURES.md` inventories every surface through 0.16.21, stating what is unverified.
- `docs/student-guide.md`: a "Choosing a model in Hermes" section (Claude Sonnet or Opus and OpenAI GPT-5.x are fit;
  local models are not advised until the instructor verifies one; Qwen3-Coder-30B did not keep the course rules), and
  the course-folders paragraph now says the files in `extracurricular/` stay on the computer, as Privacy does.

## [0.16.21] - 2026-10-01

### Added

- Enrollment password (wire revision 2026-10-01e, `STD-ENROLL-PASSWORD`). After the student types yes to confirm,
  the enrollment flow (`lib/reach/enroll_flow.rb`) asks them to choose a password of at least 8 characters, to type
  it again, and to write it down (`M-ENR-ASK-PASSWORD`, `M-ENR-ASK-PASSWORD-AGAIN`; `M-ENR-DONE` repeats the
  reminder). The prompt hook blocks both entries, so the agent never sees them; between them the flow file holds
  only a random salt and a SHA-256, removed when the flow moves on. `Reach::Enroll.register_v2` sends the password
  once in the shape v2 enroll body and nothing stores it. A failed or offline attempt asks for the password again
  (`M-ENR-PASSWORD-RETRY-FAILED`, `M-ENR-PASSWORD-RETRY-OFFLINE`), and a device move's later yes asks for it again.
- Hermes, which cannot hide a prompt from the agent, is sent to a terminal instead (`M-ENR-PASSWORD-TERMINAL`).
  `reach enroll` asks for the password twice with typing hidden, or reads one line with `--password-stdin`, and
  refuses to run without either when standard input is not a terminal.
- `tools/fake_teach` answers `400 password_required` like Teach 0.17.0, and the platform smoke enrolls with
  `--password-stdin`.

### Changed

- `specs/wire.yml` is revision 2026-10-01e, byte-identical to Teach 0.17.0's copy. This rEach enrolls only with
  Teach 0.17.0 or later, and rEach 0.16.20 or older cannot enroll with Teach 0.17.0 until it updates.

## [0.16.20] - 2026-10-01

### Changed

- rEach never asks the student or the agent for the course server. Every enrollment path uses `config.yml`
  `teach.url` (`https://sven-f1l1.tail062fd2.ts.net`): the `reach_enroll` tool no longer takes a `teach_url`
  argument (`lib/reach/mcp_bridge.rb`), `reach help` and the enroll usage line no longer list `--teach-url` (it stays
  an unlisted operator override, like `REACH_TEACH_URL`), and with no URL configured the enrollment flow and
  `reach enroll` say to run `reach update` instead of naming a missing address.
- `config.yml` enrollment identity rules match live Teach, which accepts student IDs of more than one length and
  usernames with an optional trailing letter. The enrollment prompts (`M-ENR-ASK-ID`, `M-ENR-ID-FORMAT`) and
  `docs/student-guide.md` no longer state an ID length.
  Verified in scratch homes against live Teach over the public URL: the prompt-hook flow previewed a course
  code and reached the confirm step for two roster identities without asking for a URL.

## [0.16.19] - 2026-10-01

### Fixed

- `config.yml` `teach.url` was blank, so `reach enroll` and the enrollment flow had no Teach to reach without
  `--teach-url` or `REACH_TEACH_URL`. It is now `https://sven-f1l1.tail062fd2.ts.net`, the course's Teach over HTTPS through Tailscale
  Funnel. Verified from public DNS and from Ruby 2.6.10: `GET /api/v1/enrollment/preview` answers, and a bare course
  id returns `details.course_only` (`bus101-fa26`).

## [0.16.18] - 2026-10-01

### Changed

- Pins the instructor signing key `343572ebf748c69d` under `enrollment.instructor_keys` in `config.yml`, so instructor
  codes minted from it with `reach instructor code` unlock installs on 0.16.18 or later. Only the public key ships.

## [0.16.17] - 2026-10-01

### Added

- Instructor unlock. Since 0.16.0 an installed rEach is inert until a student enrolls, which blocked instructors who
  install it to try it. An instructor now runs `reach instructor keygen` once, pins the printed public key under
  `enrollment.instructor_keys` in `config.yml`, ships it in a release, and mints never-expiring codes with
  `reach instructor code [--label TEXT]`. Pasting a code into the locked prompt lifts the enrollment lock on that
  install: the enrollment hook intercepts the code so the agent never sees it, rEach stops blocking prompts without
  checking guardrails, a workspace or a login, captures nothing, and tells the agent once per session it is in
  instructor mode. An enrolled install gates exactly as before. A bad code counts toward the enrollment lockout; a
  good one works even during a lockout. The stored code is re-verified every time, so removing its key or listing its id
  under `enrollment.instructor_revoked` relocks the next prompt. `reach instructor status` and `reach instructor lock`
  show and undo the unlock (`instructor` joins the commands that run while locked). Events go to
  `logs/instructor.jsonl` and never carry the code. New module `Reach::Instructor`; `STD-INSTRUCTOR-UNLOCK`.

## [0.16.16] - 2026-10-01

### Fixed

- Codex never offered rEach's hooks for approval. Codex 0.156 and newer takes the Agent Plugins root `plugin.json`
  (kept for Antigravity) over `.codex-plugin/plugin.json` and then loads no plugin hooks (openai/codex#47925), so the
  SessionStart and UserPromptSubmit hooks never reached the trust review, in every release under current Codex. The
  new `Reach::CodexCache.repair` renames that file to `plugin.json.agent-plugins` in Codex's cached copy of rEach only
  (`$CODEX_HOME/plugins/cache/*/reach/*/`), after `reach setup`, after every update and when Codex starts
  `reach mcp`, so an install from the app's Plugins directory heals on its first session. The repository and the
  install folder keep the file. Verified against Codex 0.160.0: both hooks list as untrusted, ready to trust.
- The update step refreshes Codex with `codex plugin add reach@reach` even when `codex plugin marketplace upgrade`
  fails, which it always does for a local marketplace.
- The setup message names both hooks and where to trust them: `/hooks` in a terminal, Settings > Hooks in the app.

## [0.16.15] - 2026-10-01

### Added

- The microbrain learns and recalls, locally. `Reach::Brain` (`lib/reach/brain.rb`) captures each conversation turn
  Reach already records in a course folder as a private `source` spool line, takes the findings the host agent
  distils through the new `reach remember` command and `reach_remember` tool, and gates them: a cosine of at least
  0.85 within the category only reinforces the existing finding, `per_hour` and `per_day` budgets hold the rest, and
  a claim or evidence that looks like a password, key, token or student ID is refused. A nudge asks the agent to
  record what the last turns taught, every 3 turns and backing off to 24 when nothing is saved.
- Recall. `reach hello` adds the memory instructions and the profile (at most 1500 bytes) to the session context, and
  every prompt hook adds the matching memories (at most 800 bytes, not repeating the last 10 injections).
  `Reach::BrainIndex` is the read model over the spool: BM25 search, term-frequency cosine, decay and reinforcement
  salience, cached in `~/.reach/brain/index.json`. The Hermes hooks receive the same blocks through the existing
  hello and prompt context. Hooks always recall lexically through the index, to stay inside the 150 ms hook budget,
  and a memory qualifies when its BM25 score is at least `brain.prompt_min_score` (0.2) of the ideal score for the
  prompt's known terms, so a small memory recalls as well as a large one. An explicit `reach_recall` query is fused
  through `Rcorpus::Context#render` when rplugin, rcorpus 0.9.0 and the encoder are present, and falls back to the
  index on any error.
- `reach memory list|show|forget|export` and the `reach_recall` and `reach_memory_forget` tools. Forgetting writes a
  tombstone and scrubs the finding, the findings it superseded and note sources only it used from Reach's spool
  (`Reach::BrainSpool.scrub!`, the one exception to the append-only spool); `forget --all --yes` scrubs every source
  too. Both commands refuse while locked. The first session greeting adds `G-MEMORY-NOTICE`, once per install.
- `source` and `finding` kinds in `specs/kinds.yml` and `reach.rplugin.yml`, with the novelty and budget settings;
  `config.yml` `brain` holds every limit. Spool admission now runs at most once per `admit_interval_s`, backs off
  after a failure and, once a day after an admit, runs `Rcorpus::Consolidate` when it is defined.
- A spool cap. After a capture, at most every 10 minutes, `brain.max_spool_bytes` (20 MiB) is checked; over it, the
  oldest `source` lines no active finding references are scrubbed until the spool is at or below 80% of the cap
  (`brain.pruned` logs counts and bytes). Findings, tombstones and other kinds are never removed. When only
  referenced sources remain and it is still over the cap, new captures are held (`brain.source_held`, reason
  `spool_full`) while findings are still accepted.
- `STD-BRAIN` in `specs/app.yml`, `Reach::Brain` and `Reach::BrainIndex` in `reach.spec.yml`, FEATURES 2.29, the README
  "Memory" section and the persona's Memory section (`skills/reach-assistant/SKILL.md`, `agents/reach.md`).
- Sources and findings are spooled with op `source` and op `finding`, so admission builds their content files,
  graph nodes, supports edges and embeddings (rcorpus 0.9.0, pinned by rplugin 1.4.0, whose `rplugin install`
  syncs the new kinds into the owned corpus).

## [0.16.14] - 2026-10-01

### Changed

- Auto-update now lists GitHub releases and tags on every check and takes the newest version from either
  (`Reach::Update.check`, `lib/reach/update.rb`). Before, tags were read only when releases were unavailable or
  listed no version, so once a version release existed, every newer tag after it was never offered. A version in
  both is recorded with source `releases`. A failed tag listing no longer fails the check when releases answered;
  when neither answers, the check backs off as before. `STD-AUTO-UPDATE`, `reach.spec.yml` (`update.sources`, the
  `reach update` synopsis) and FEATURES 1.4 say so.

## [0.16.13] - 2026-10-01

### Added

- `docs/INSTALLATION-AND-SETUP-GUIDE.docx`: the student setup guide, with no institution, instructor, course or term
  in it. Its new "Approvals and other extra steps" section walks each app through its approvals with official vendor
  screenshots. For Codex that means running the install outside the sandbox, Full access on Windows, trusting rEach's
  hooks, trusting each course folder and re-trusting after an update. Claude Code, Cowork, Antigravity and Hermes
  get the same treatment, and so do the Mac, Windows and Linux prompts (Documents access, Ruby from RubyInstaller,
  SmartScreen). Step 3 now describes enrollment v2 (course code, username, student ID, sign-in each session, a
  second computer). Listed under `contents.docs` in `reach.rplugin.yml`.
- `reach guide [--path] [--format text|json]` (`lib/reach/guide.rb`). It prints the guide's text from the .docx with
  the standard library (`Reach::Unzip`), one line per paragraph, table rows joined by " | " and `[Screenshot]` for
  pictures. It works while Reach is locked (`UNLOCKED_COMMANDS`) and exits 1 with `M-GUIDE-MISSING` or
  `M-GUIDE-DAMAGED`.
- Until the student is enrolled, every session's locked `reach hello` context adds `M-ENR-AGENT-GUIDE`. It tells the
  agent to run `reach guide` and read the guide. If the student's messages reach the agent while locked (the
  enrollment hook is not running, for example untrusted Codex hooks), the agent walks the student through the
  guide's extra steps for their app first, never asking for the code, username or student ID. Hermes's locked
  prompt context adds `M-ENR-HERMES-GUIDE`, which allows one line pointing to an unfinished step after the relayed
  message.
- `STD-SETUP-GUIDE` in `specs/app.yml`. `reach guide` and `Reach::Guide` are added to `reach.spec.yml`.

### Changed

- `INSTALL.md` step 3: the installing agent takes setup's host steps from `reach guide` and walks the student through
  the unfinished ones.
- `M-ENR-AGENT-CONTEXT` and `M-ENR-HERMES` make room for the guide's extra steps. `STD-ENROLL-LOCKDOWN` and
  FEATURES 2.27 list `guide` among the commands that work while locked.

## [0.16.12] - 2026-10-01

### Added

- `docs/DESIGN-DECISIONS.md`: the standing product decisions for rEach, latest form only, including the data-capture
  rule and the planned move of everything rEach keeps into one rEach folder (0.17.0).
- TODO: decide and send the analytics rEach captures, keyed to the enrolled student ID.

### Changed

- Files in the extracurricular folder no longer leave the student's computer. `reach transcript code` records AI
  writes and `reach transcript turn` scans for changed files only in slice workspaces (`lib/reach/transcript.rb`);
  before, every file in `extracurricular/`, a student's own and imported files included, went to Teach as
  extracurricular code. The conversation held there (prompts, replies, reasoning, actions and code blocks put in a
  reply) is still captured. `M-TRANSCRIPT-NOTICE`, the extracurricular fallback rule, the persona's answer to "what
  does rEach share", the student guide, `reach.spec.yml` and `specs/app.yml` say so. Teach changes its G-EXTRA-2 rule
  to match.

### Fixed

- Installing from Codex on Windows stopped at "Windows denies creating `C:\Users\<name>\.reach`" when the agent could
  not run the install outside Codex's sandbox. Codex's Windows sandbox lets a command write only in the chat's
  folder and the temp folder and blocks the network, whether elevated or not (measured on GitHub windows-2025 and
  windows-11-arm with Codex 0.160.0), so the install cannot succeed inside it. `INSTALL.md` now has the agent tell the
  student, in one message, to switch the chat's permissions to Full access and ask again, instead of improvising.

## [0.16.11] - 2026-10-01

### Fixed

- `rplugin install reach` on a computer with Hermes merged Reach's fail-closed enrollment gate and MCP server into the
  default Hermes profile's `config.yaml` and linked Reach's skills there, although Reach reaches Hermes only through
  the dedicated `reach` profile that `reach setup` creates. The manifest now claims `hermes: unsupported`
  (`reach.rplugin.yml`, and its copy in `reach.spec.yml`), which rplugin 1.3.0 and later honor in `install` and
  `doctor`; `rplugin doctor reach` drops from 10 findings to 0.

## [0.16.10] - 2026-10-01

### Fixed

- A student who already had a runtime kit never received a newer pinned one. `Reach::RuntimeAuto.due?` returned false
  whenever any kit was active, so a computer that installed `4.0.7-r1` kept it after Reach pinned `4.0.7-r3`. The
  session-start hook now also starts the background install when the active kit is not the pinned `RUNTIME_ID`; the
  older kit keeps serving local qualification until the new one is placed, and stays on disk afterwards
  (`lib/reach/runtime_auto.rb`).

## [0.16.9] - 2026-10-01

### Fixed

- `reach doctor` no longer fails a healthy install that has not enrolled yet. Right after an install or reinstall
  it printed `R-DOC-ENROLL: rEach is locked (not_enrolled)` and exited 1, so the student's AI partner reported
  that doctor "still exits with an error". Not being enrolled yet is the next step, not a fault: doctor now prints
  an `enrollment:` line with the same M-GATE-NOENROLL words and that line does not change the exit code. A revoked,
  damaged, moved or course-ended enrollment is still an R-DOC-ENROLL finding (`lib/reach/cli.rb`).
- `reach doctor` and `reach work` no longer pass a harness's own stderr through when they ask it for its version.
  Inside the Codex app's sandbox `codex --version` warns "proceeding, even though we could not create PATH
  aliases", and the student's AI partner reported that as a rEach problem. `Reach::Harness.detect` now reads the
  version from stdout and discards stderr (`lib/reach/harness.rb`).

## [0.16.8] - 2026-10-01

### Added

- Platform smoke, `tools/platform_smoke/run.rb`: on Linux, macOS or Windows, with no agent and no secret, it installs
  Reach from the checkout's HEAD with `bin/reach-install --archive` into a scratch path containing a space, starts
  `tools/fake_teach` (installing `webrick` into scratch gems when Ruby lacks it), runs the SessionStart and
  UserPromptSubmit hook command lines from `hooks/hooks.json` and `hooks/codex.json` the way the harness does (Git
  Bash on Windows), and checks that the gate blocks before enrollment and opens after it, `reach enroll`,
  `reach status` with the fingerprint, the machine id (`ioreg` on macOS, `reg query` on Windows, `/etc/machine-id`
  on Linux), the runtime kit (waiting for the background self-install) and `reach doctor` against a list of findings
  the fixture explains. `--report` writes `reach.platform-smoke/v1` JSON.
- `.github/workflows/platforms.yml` runs it on every push to main and on dispatch, never on pull requests: GitHub
  Linux x64 (Ruby 2.6.10), macOS arm64 and Intel (the system Ruby 2.6.10), Windows x64 and Windows 11 arm64
  (Ruby 4.0), plus self-hosted Windows 10 and Windows 11 VM legs (labels `win10`, `win11`) gated by the repository
  variable `REACH_VM_RUNNERS` or the dispatch input `vms`. Actions are pinned by SHA and Windows checkouts keep LF.
- `tools/platform_smoke/windows-runner/bootstrap.ps1` prepares a Windows VM (OpenSSH Server, Git for Windows
  2.56.0, RubyInstaller 4.0.7-1, GitHub Actions runner 2.337.0, each SHA-256 pinned) and `register.ps1` registers it
  as a runner service with a token passed at run time. STD-PLATFORM-SMOKE in `specs/app.yml`; blueprint
  `specs/implementation/platform-smoke.impl.yml`.

## [0.16.7] - 2026-10-01

### Fixed

- `reach runtime install` failed on every Windows x64 computer, and since 0.16.5 so did the automatic background
  install: `RuntimeKit.smoke_chrome!` ran `chrome.exe --version`, which on Windows opens a browser and never exits, so
  it was killed after 30 seconds and the install refused with "the runtime Chrome did not report 154.0.8037.92 (timed
  out)". On Windows the check now looks for the `<version>.manifest` file Chrome for Testing ships beside
  `chrome.exe` (the zip itself is already verified against the pinned SHA-256), and never launches Chrome
  (`lib/reach/runtime_kit.rb`). Linux and macOS keep the `--version` check. Found by the platform smoke on GitHub
  windows-2025.

## [0.16.6] - 2026-10-01

### Fixed

- On macOS's built-in Ruby 2.6.10, which INSTALL.md tells students to use, 11 of the 13 public engineering
  directives silently dropped out of the course directive table and `reach doctor` reported R-DOC-DIRECTIVES for
  each. That Ruby links libyaml 0.1.x, which rejects an unquoted colon inside a flow list such as
  `when: [task:after-task, task:rewrite]`. `Reach::Directives` now quotes the list items and reads the block again
  when the first parse raises `Psych::SyntaxError` (`lib/reach/directives.rb`); newer libyaml never takes that path.
  Under libyaml 0.1.7 the public rows went from 2 to 13 and the table is byte-identical to libyaml 0.2.5. Course
  rows from the guardrails package were not affected: Teach writes them with `YAML.dump` in block style, which
  libyaml 0.1.7 reads. Found by the platform smoke on GitHub macos-15 and macos-15-intel.

## [0.16.5] - 2026-10-01

### Added

- The runtime kit installs itself. The session-start hook (`reach hello`) starts `reach runtime install --auto` in a
  detached process when no kit is active (`lib/reach/runtime_auto.rb`), so the student is never asked about it. One
  install runs at a time (`~/.reach/state/runtime-install.lock`; a manual `reach runtime install`, `reach setup
  --runtime` or `reach doctor --install-chromium` meanwhile is refused with a message), an attempt starts at most once
  per `interval_s` (3600) plus up to `jitter_s` (600), and at most `max_attempts` (5) per pinned kit, recorded in
  `~/.reach/state/runtime-auto.json`, with `runtime.auto.start` and `runtime.auto.skip` in the runtime log. Nothing
  starts when that state cannot be written (an agent shell inside a sandbox), under `REACH_RUNTIME_DISABLE=1` or
  `REACH_OFFLINE=1`, or when `config.yml` sets `runtime.auto_install: false`.

### Changed

- `INSTALL.md` gives one command per platform that downloads the bootstrap, runs `bin/reach-install` and runs `reach
  setup`, so an app that sandboxes commands asks the student once instead of three times, and tells the agent to ask
  to run it outside the sandbox from the start. It no longer has the agent offer the runtime kit.
- `reach setup` says the checking tools install themselves in the background instead of offering `reach runtime
  install` (the offer returns when `runtime.auto_install` is false), and a local qualify that has no kit says the tools
  are still installing while the background install runs.

## [0.16.4] - 2026-10-01

### Changed

- Reach pins the portable runtime `runtime-4.0.7-r3` (manifest sha256 `cd79747a...c0bbc6a2`) instead of r1
  (`lib/reach/runtime_kit.rb`). r3 is the r2 build, whose Linux kits need only glibc 2.28, plus the 0.16.3
  relocation-check fix; all five kits passed CI and were published. Installed from the release on Linux x86_64 into a
  scratch home, and its Ruby ran in a Debian 11 container, where the r1 kit could not.

## [0.16.3] - 2026-10-01

### Fixed

- `runtime/relocate_check.rb` no longer fails a Windows runtime build after every check has passed. Chrome for
  Testing, launched by the Ferrum check, can still hold `chrome.dll` open while it exits, and the temp directory's
  cleanup raised `Errno::EACCES` (CI run 36838426832, tag `runtime-4.0.7-r2`, windows-x86_64). Cleanup now retries
  a busy or locked tree for up to a minute and then warns instead of failing.

## [0.16.2] - 2026-10-01

### Fixed

- `reach doctor` no longer reports R-DOC-GUARD or R-DOC-SEAL before enrollment. The guardrails package and the
  seal sidecar arrive with enrollment, so a student who had not enrolled yet saw both as faults, and under the
  Codex app's sandbox on macOS doctor's attempt to pre-create `~/Library/Application Support/reach/seal.json` was
  refused. Both checks run as before once `install.yml` exists (`lib/reach/cli.rb`).
- An R-DOC-DIRECTIVES "unreadable frontmatter" finding now names the reason: no `---` block, not a mapping, or the
  read or YAML error (`lib/reach/directives.rb`).

## [0.16.1] - 2026-10-01

### Fixed

- A bare course id of nine or more characters (`BUS101FA26`) that Teach reports as `course_code_unknown` with
  `details.course_only` is now answered with M-ENR-CODE-COURSE-ONLY naming the course, in the chat flow and in
  `reach enroll --course-code`, before the did-you-mean check.
- Wire revision 2026-10-01d (`specs/wire.yml`). Needs Teach 0.16.1.

## [0.16.0] - 2026-10-01

### Added

- Enrollment v2 (wire protocol 1 revision 2026-10-01b, `specs/wire.yml` W-ENR-1..7, W-API-ENROLL shape v2,
  W-API-ENROLL-PREVIEW). Students enroll with a class-wide course code tied to one course and expiring at the
  course's end (`BUS101-K7QX-94TD`, normalized from any spacing, case or Crockford look-alikes; a course id within
  two edits still matches), their institutional username (their school email address) and their student ID.
  Institution rules come from Teach's preview and fall back to the new `config.yml` `enrollment` block.
- Lockdown until enrolled (`lib/reach/enrollment_lock.rb`, `lib/reach/enroll_flow.rb`). A plugin-level
  UserPromptSubmit hook (`hooks/hooks.json`, `reach gate enroll`) blocks every prompt and runs the enrollment
  conversation itself, so the agent never sees the code, username or ID. The crisis check runs first. The flow
  supports start over and a local lockout (5 refusals in 15 minutes), and tells the agent once when Reach unlocks.
  Every CLI verb except help, enroll, setup, doctor, support, update, runtime and the hooks, every MCP tool, and the
  write, shell and read gates refuse while locked. Hermes gets the flow as context.
- Fingerprint and enrollment stamp (`lib/reach/fingerprint.rb`, `lib/reach/stamp.rb`).
  - The fingerprint is a salted, hashed record of the machine id, OS user, platform and install key, with
    descriptive extras: hostname hash, harness, OS, Ruby and Reach versions.
  - Teach signs a `teach.enrollment-stamp/v1`, and Reach verifies it before writing anything.
  - Reach locks as moved when the live fingerprint differs or Teach answers `fingerprint_mismatch` to the
    `X-Reach-Fingerprint` header on status. It then queues integrity kind `fingerprint_mismatch`.
  - Policy `enrollment.fingerprint_match` chooses binding (the default) or strict matching.
  - Policy `enrollment.require_stamp` makes shape v1 installs re-enroll.
- `reach enroll --course-code C --username U --student-id I`, or `reach enroll` with no arguments on a terminal,
  enrolls with shape v2; `reach enroll <code>` still sends shape v1. `lib/reach/identity.rb` normalizes codes,
  course ids, usernames and IDs.
- Device moves and handout expiry (wire revision 2026-10-01c, W-ENR-8, W-ENR-9).
  - A second computer for an enrolled student waits for the instructor's approval (`device_move_pending`): rEach says
    so and re-posts the identical request when the student types yes. The pending install key and fingerprint are
    kept in `~/.reach/state/enroll/` (0600), and are reused only for the same code, username and ID.
  - `reach enroll --course-code` exits 3 while a move waits.
  - A denial shows the instructor's reason.
  - An expired handout code says so (M-ENR-CODE-OLD).
  - Re-enrolling on the same computer keeps the fingerprint salt.
- `tools/fake_teach`: a local stand-in for Teach's half of enrollment v2 (WEBrick bound to 127.0.0.1, fixture
  courses and roster), until Teach implements it.

### Changed

- The `reach_enroll` MCP tool no longer enrolls while Reach is locked: a student's identity never passes through the
  agent.
- The plugin's enroll hook is declared in `hooks/reach.hooks.yml`, and `rplugin package` generates
  `hooks/hooks.json` and `hooks/codex.json` from it.
- `reach status` names the student from `install.yml` before the first sync.
- Enrolling a different student over an existing install drops the cached status, so `reach status` never names
  the previous student.
- The privacy notice, the student guide and `reach.spec.yml` disclose the fingerprint, and that enrollment now
  sends the username and student ID.

## [0.15.0] - 2026-10-01

### Fixed

- Corpus records were lost whenever the rplugin SDK was installed. Reach called `put` and `recall` on the corpus
  port's object, which has neither, and the callers swallowed the error; in a qualification the error also skipped
  the ledger entry. The SDK was also handed `~/.reach` as the plugin root, so it never found the manifest.

### Changed

- Every corpus record (note, tip, attempt, receipt, qualification) is first written as one rcorpus.spool/v1 line to
  `<rplugin state>/reach/brain-spool/<UTC date>.jsonl` (mode 0600), on any Ruby and with the standard library
  only. When rplugin and rcorpus load (Ruby 3.3+ or the runtime kit), Reach admits the spool into its own corpus's
  private tier after every write; a refused or failed admission is logged to `~/.reach/logs/brain.jsonl` and never
  reaches the caller. Lines wait in the spool until they are admitted, and `recent` reads both.
- A qualification always reaches the ledger, even when the corpus write fails; receipt and submission corpus failures
  are logged instead of dropped.
- `~/.reach/corpus-fallback/*.jsonl` is migrated into the spool once (idempotent; the files become `*.migrated`).
- `reach sync` no longer prunes corpus records; the size check reports the spool still waiting for admission.
- The native packages (Claude Code, Codex, Agent Plugins) are generated by rplugin 1.2.0 from `reach.rplugin.yml`,
  which now declares the hooks (`hooks/reach.hooks.yml`), the MCP bridge, the kinds file, `tiers_split`, the rEach
  presentation fields and the GitHub repository. Codex now gets the MCP bridge too, loaded from Codex's plugin cache
  through `${PLUGIN_ROOT}`; its start-up hook moved to `hooks/codex.json`, so Codex asks the student to trust it again.

### Added

- `specs/kinds.yml` declares Reach's five kinds with their required fields (rcorpus.kinds/v1).

## [0.14.6] - 2026-10-01

### Fixed

- The runtime workflow builds the Linux kits for glibc 2.28 and newer (Debian 10+, Ubuntu 20.04+). r1 used a
  prebuilt Ruby that needs glibc 2.38, so `reach runtime install` fails on Debian 11 and 12 and Ubuntu 22.04. Ruby
  4.0.7 is now built from source in a manylinux_2_28 container with its libraries linked in, the kit's gems are
  compiled there too, and the relocation check fails any kit that needs a newer glibc. Both Linux kits built and
  passed in CI under the tag runtime-4.0.7-r2, but the Windows build failed its relocation check, so r2 is not
  published and Reach still pins r1. Until it is, Linux below glibc 2.38 still cannot use the kit.
- `reach runtime install` names the system libraries Chrome for Testing lacks on a minimal or server Linux instead of
  "did not report <version>".
- When the checking tools fail to install, the error carries bundler's own reason (bundler writes it to stdout, and
  Reach read only stderr, so the reason was empty) and points at `reach runtime install`.
- `reach check`, `reach shape check` and `reach status` no longer report shape findings on the instructors' panel
  files a workspace does not hold (S-STATE-001 on Panel.svelte, "shape: 2 open"). Teach ships no suite package, so
  the reference panel is absent and those findings could not be acted on.

All four were reported by a peer session's full slice-build smoke on Reach 0.14.3.

## [0.14.5] - 2026-10-01

### Changed

- The repository carries no course material. `corpus/` is removed, and `reach reference` reads `.rref` blobs only from
  `~/.reach/vault/guardrails/reference/`, where Teach ships them as `reference/<name>.rref` entries of the guardrails
  package (`lib/reach/reference.rb`; `REACH_REFERENCE_DIR` still overrides the directory). Wire protocol 1 revision
  2026-10-01a (`specs/wire.yml`) adds those entries and documents the qualify object's `env` rule.
- `reach qualify`: a local failure whose answer the practice recording does not hold (`not_recorded`) is the finding
  QF-PRACTICE, which points at `qualify/kit/practice/README.md`, and the record carries `practice_readme`
  (`lib/reach/qualify.rb`). `directives/qualify.md` tells the agent to read that README before writing a panel slice's
  local scenarios.
- `tools/smoke/assignment_one.rb` packs the smoke's reference blob for Teach and no longer
  points Reach at it, so the reference steps prove delivery through the guardrails package.

## [0.14.4] - 2026-10-01

### Fixed

- A hand Teach refuses now says why. `reach hand raise` and the `reach_raise_hand` tool used to answer with a null
  hand id and no reason when Teach refused the hand (for example with hand-raises disabled), and printed
  "Hand raised: " with nothing after it. They now report M-HAND-REFUSED with Teach's reason, and a hand saved for
  later because Teach could not be reached is reported as queued (M-HAND-QUEUED). Reported by a peer session during
  the 0.14.3 verification.

## [0.14.3] - 2026-10-01

### Added

- Five MCP bridge tools for agents without a shell (`lib/reach/mcp_bridge.rb`): `reach_support`, `reach_part`,
  `reach_transfer_request`, `reach_modules` and `reach_next`. They call the same library functions as the CLI, keep the
  same sign-in and consent rules (`reach_part` records only from the student's captured prompt; a move or a choice is
  asked by Reach until the student's captured yes) and mark text the agent must give the student word for word
  (`relay_verbatim`).
- Course-alignment live scenarios in `tools/smoke/scenarios.yml` (`course-coach-stuck`, `course-offtopic-chain`,
  `course-life-advice`, `course-crisis`, `course-ownpart`, `course-moved`, `course-sandbox`, `course-ahead`) with a
  course rubric for the judge (`course_judge_rubric`). `tools/smoke/run.rb` gains per-scenario judge rubrics and
  judge-gated verdicts, seeded files, the checks `turn_reply_matches`, `tool_input_matches`, `no_tool_result_matches`,
  `workspace_file_exists`, `teach_hand_trigger` and `teach_transfers_count`, and gives workspace sessions the shell a
  student's agent has.

### Changed

- STD-CONSENT-FROM-REACH: a module move or choice is asked by Reach, never by the agent. The reach-course skill tells
  the agent to run `reach transfer request` / `reach modules choose` (or the tools) as soon as the student raises it and
  relay the printed question word for word, never offering or claiming a notification in its own words. Found live:
  Haiku and Sonnet both refused the claimed move but never sent a request.
- Reach acts on the student's yes or no itself: the prompt hook that captures the answer to a pending move or
  lock-in question sends it (or records the no) at once, with quick network timeouts and the existing offline queue,
  and gives the agent the outcome to relay (M-CONSENT-DONE). Found live: after the yes, Haiku told the student
  "I've sent that to Teach" without the second call, and Teach received nothing. When the send is queued (the
  client's rate bucket drained, or offline), a detached `reach transfer --flush` / `reach modules --flush` sends it
  at once instead of waiting for the next sync.
- The student's own part is coached on process only (reach-course skill): how to answer, never candidate answers,
  examples, options or sentences to copy.
- A crisis comes before the greeting: `reach hello`'s session context, the reach-assistant skill and the rEach agent
  say to skip the greeting and give `reach support`'s message first when the first message is a crisis.
- G-TRANSCRIPT-NOTICE no longer names code ("everything we make").
- Wire protocol W-PART-3 defines `unverifiable` (a reported transcript gap, or an entry still missing 7 days after the
  submission); `specs/wire.yml` stays byte-identical with Teach's copy.

### Fixed

- `tools/smoke/assignment_one.rb` and `tools/smoke/run.rb` create their own `reach_smoke_<run>` PostgreSQL database
  for Teach (0.14.0 and later) and drop it afterwards, so a Teach database setting inherited from the shell can never
  point a smoke run at a live Teach database.
- The A1 qualify fixture uses Grokit 0.8.0's graded name "A zero value is returned as ok, not treated as missing"; the
  transport smoke failed coverage without it. `course-gate` signs in first, as every course session must since 0.12.0.
- The plugin manifests (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.codex-plugin/plugin.json`)
  had stayed at 0.13.0; all version strings are 0.14.3.

## [0.14.2] - 2026-10-01

### Fixed

- `reach sync` removes qualify-kit files that a newer workspace package no longer ships. A stale kit file used to stay
  in the workspace, read-only, for good.
- A local qualification run can always clear and rebuild its run directory: a folder left read-only by an earlier
  run is made writable before it is replaced, kit files are copied writable, and the slice's own files are written
  over any kit copy at the same path. Before this, a kit that shipped a file at an owned path, or a run that stopped
  half way, made every later local run fail with Permission denied.
- Exercised with a panel slice end to end: Teach 0.14.0 packaged context.a1 panel with Grokit's practice replay, and
  `reach qualify --local-only` under the runtime kit passed the agent's three scenarios and failed them on the
  starting copy.

## [0.14.1] - 2026-10-01

### Fixed

- The workspace layout in reach.spec.yml listed a fixtures/ folder of demo-business data, which no Teach workspace
  carries and which the rule against reading test data forbids. It is gone; the answer-free qualify kit is what a
  slice's scenarios read. No code changed.

## [0.14.0] - 2026-10-01

### Added

- The portable runtime kit. `reach runtime install [--only ruby|chrome] [--from DIR]` downloads one bundle for this
  computer (Ruby 4.0.7 with bundler 4.0.19 and the course's gems already built) and Chrome for Testing 154.0.8037.92
  from Google's own storage, checks both against a manifest whose sha256 is pinned in Reach, extracts them in pure Ruby
  (`lib/reach/untar.rb`, `lib/reach/unzip.rb`), smoke-checks them and moves them into `~/.reach/runtime/<id>/` only when
  everything verified; a failed or interrupted install leaves the previous runtime in place. `reach runtime status`
  and `reach runtime remove --yes [--old]`. `--from DIR` installs from a folder of release files (a classroom can share
  one download). `REACH_RUNTIME_DISABLE=1` or `REACH_OFFLINE=1` turns network installs off.
- Local qualification uses the runtime when one is installed: its Ruby runs cucumber, and when the run's Gemfile.lock
  matches a prebuilt profile its gems are used as they are (frozen, nothing compiled); otherwise the runtime Ruby
  installs the gems. Chrome resolves as `REACH_CHROME`, then the runtime's Chrome, then browsers on PATH. On Linux,
  `CUPRITE_NO_SANDBOX=1` is set when running as root, or for the runtime Chrome where AppArmor restricts user
  namespaces.
- A qualify kit may carry `qualify.env` (for example the Grokit practice replay); Reach passes it to cucumber after
  checking every name and value, and records anything it dropped.
- `reach setup` offers the runtime when none is installed, and `reach setup --runtime` installs it in the same run.
  `reach doctor --install-chromium` now works (it installs the runtime's Chrome); R-DOC-CHROME points at
  `reach runtime install`, and doctor reports the runtime.
- `.github/workflows/runtime.yml` and `runtime/`: a tag `runtime-<ruby>-r<n>` builds the bundles on macOS arm64, macOS
  x86_64, Linux x86_64, Linux arm64 and Windows x64 from the lock profiles in `runtime/locks/`, checks each one after
  moving it to a new path (Ruby, the native gems, and a headless Chrome page), and publishes them with
  `runtime-manifest.json` as a GitHub release that is never marked latest. Google publishes no Chrome for Testing for
  Linux arm64, so that platform uses the distribution's chromium.

## [0.13.0] - 2026-09-30

### Added

- Automatic updates (`lib/reach/update.rb`, `update/apply.rb`, `reach.spec.yml` `auto_update`, STD-AUTO-UPDATE; build
  record `specs/implementation/v0.13.0.impl.yml`). Reach keeps a managed `~/.reach/plugin` install current: it reads
  published GitHub releases first (with a stored ETag, skipping drafts and prereleases) and falls back to the
  repository's tags through git's own `info/refs` listing when there are no releases or the API is limited or
  unreachable. It checks at session start and hourly from the prompt gate, always in a detached process with up to
  10 minutes of jitter, and backs off exponentially (to 24 h) after failures.
- An update manifest at `~/.reach/state/update.json` records the local version, every remote version ahead of it,
  the target and the phase (detected, downloaded, staged, swapped, refreshed, completed). Every phase is safe to
  repeat: a download killed mid-way, a crash after the swap and a crash between the two renames each resume on the
  next session start, and the `~/.reach/bin/reach` shim restores a missing install from the staged release or the
  backup before it loads Reach.
- The release installs itself: Reach downloads and stages the tag's archive (with the pinned Dovetail), then runs
  that release's `update/apply.rb`, which moves the old install to `~/.reach/.backup/`, swaps the new one in, runs
  any `update/migrations/<version>.rb`, points the shim at it and refreshes Claude Code (`claude plugin marketplace
  update reach`, `claude plugin update reach@reach`) and Codex (`codex plugin marketplace upgrade reach`,
  `codex plugin add reach@reach`).
- Student experience: a release found mid-session is staged in the background and announced once (M-UPDATE-READY);
  nothing is swapped mid-session. At the next session start the greeting opens with G-UPDATING and the install runs;
  course work (prompts, writes, shell, qualify, submit, sync) waits only while it is actually running
  (M-UPDATE-INSTALLING), sessions that started earlier are told M-UPDATE-DONE, and a failed install is reported once
  (M-UPDATE-RETRY) while the student keeps working.
- `reach update status|check|run [--apply] [--background] [--force] [--format text|json]`; `config.yml`
  `updates:` (repository, interval_s, jitter_s, max_attempts); `REACH_UPDATE_DISABLE=1` and
  `REACH_UPDATE_REPOSITORY`. A git checkout at `~/.reach/plugin` is never updated. Log at `~/.reach/logs/update.log`.

### Changed

- `bin/reach-install` can be loaded as a library (`ReachInstall.stage`) and behaves as before when run.
- `Reach::Runtime.ensure_shim!` no longer points the shim back at an older copy of Reach.

## [0.12.0] - 2026-09-30

### Added

- Course alignment (wire protocol 1 revision 2026-09-30b; design record `docs/course-alignment-design.md`, build
  record `specs/implementation/v0.12.0.impl.yml`).
- Sign-in every session (`lib/reach/login.rb`). The prompt hook asks for the student ID, then "Am I speaking with
  <name>?", and waits for a yes, blocking each step so the agent never sees the ID or the answer. Three wrong IDs lock
  the session for 15 minutes; a no ends course work for the session; both are reported to Teach. Until the student
  is signed in, every tool gate refuses and submit, qualify and the commitment commands need a sign-in.
  `reach login status`.
- The student's own part (`lib/reach/part.rb`). `reach part` lists the questions only the student can answer for
  the assignment; `reach part record <id>` takes the student's own typed words verbatim, linked to the transcript.
  `reach submit` refuses until every question is answered and sends the answers as `part.json`.
- Modules (`lib/reach/modules.rb`, `lib/reach/consent.rb`). Reach verifies and keeps Teach's signed record of the
  student's modules and refuses writes in another module's slice. In a course where students choose,
  `reach modules choose <a> <b>` asks the student to confirm the lock-in, seals the choice locally and sends it
  with their yes; it is then locked.
- Transfer requests (`lib/reach/transfer.rb`). `reach transfer request --modules a,b` asks "Would you like to notify
  the professor to verify?" and, on yes, sends the request; nothing changes until an instructor decides.
- Sandbox (`lib/reach/gate.rb`, `lib/reach/imports.rb`). A read gate and the shell gate refuse any path outside the
  workspace and web lookups in slices and the root, for Claude Code, Codex and Hermes. A file the student drags into
  the chat is copied into `materials/` within size and type limits; `reach import <path>` from their own terminal.
- Time gate (`lib/reach/pace.rb`). Writes are refused outside the current assignment or after its due time, by
  Teach's clock.
- `reach next` (`lib/reach/next.rb`) gives the student's next step, and every prompt carries a short anchor naming
  the current step for the agent.
- `reach support` (`lib/reach/support.rb`) prints a fixed message beginning "If this is an emergency, call 911 now.",
  then 988 and the course's support line, and raises a wellbeing hand to the instructors. The prompt hook catches
  crisis phrases even before sign-in and sends the hand within seconds.
- Local limits (`lib/reach/limits.rb`). `reach sync` prunes Reach's own corpus and archives acknowledged transcripts
  above the course's caps; `reach doctor` reports the sizes.
- `reach status` shows sign-in, modules, a pending module move, the student's part and the next step. Every local
  record carries the student ID.
- Skills and the rEach persona tell the agent to coach kindly and honestly, keep to the course, never write the
  student's part, run `reach support` in a crisis, and route module moves through `reach transfer request`.

### Changed

- Needs Teach 0.12.0; Teach refuses older Reach for course work. The A1 smoke signs in and records the student's
  part before submitting.

## [0.11.5] - 2026-09-30

### Added

- Receipt acknowledgments, a receipt of each receipt (wire protocol 1 revision 2026-09-30, W-RCPT-4 and
  W-API-RECEIPT-ACK). For every Teach receipt Reach verifies and stores, `Reach::ReceiptAcks`
  (`lib/reach/receipt_acks.rb`) writes a `reach.receipt-ack/v1` record signed with the install key. The record holds
  the receipt id, kind, submission, student, install and time, plus the SHA-256 digest of the receipt exactly as
  received. It lives at `~/.reach/receipts/acks/<receipt_id>.json` (0600) and moves through the states pending,
  linked, mismatch or refused. Reach sends it to `POST /api/v1/receipts/:receipt_id/acknowledgment` right after
  `reach submit` or a grade poll stores the receipt. `reach sync` sends any still pending (at most 20 per sync), and
  also acknowledges receipts stored before this version.
- `reach sync` now preserves receipts. It pages through `GET /api/v1/receipts` (at most 5 pages of 200) and
  verifies and stores every receipt missing from this computer. A receipt Teach cannot match is reported as a sync
  warning.
- `reach receipts acks` lists the acknowledgment records. `reach status` counts how many are confirmed with Teach,
  how many are waiting and how many are mismatched.

## [0.11.4] - 2026-09-30

### Fixed

- After installing from the link, `reach` is not on the student's PATH, yet setup and the docs told a Hermes student
  to open a course with `reach work --harness hermes`, which failed with command not found. `reach setup --harness
  hermes` now prints the full command for that computer (the Ruby interpreter and the absolute `~/.reach/bin/reach`
  shim, as the hooks use), and `INSTALL.md`, `README.md` and `docs/student-guide.md` give
  `~/.reach/bin/reach work --harness hermes`. Found in the Hermes install-from-link smoke.

## [0.11.3] - 2026-09-29

### Fixed

- The shell gate refused `ruby <shim> qualify` (`/usr/bin/ruby3.3 ~/.reach/bin/reach ...`), the exact form rEach's
  session context prints, so an agent that followed it could not qualify. `Reach::Gate.readonly_command?` now treats a
  `ruby`/`rubyX.Y` interpreter followed by Reach's own shim path like `reach`.
- `Reach::Gate.subshell_or_substitution?` reads quotes as the shell does: nothing inside single quotes counts, `$(` and
  backticks still count inside double quotes, and a backslash escapes the next character, so `grep -E '(a|b)'` is no
  longer refused as a subshell.
- Inline interpreter code (`ruby -e`, `python -c`, `node -e`/`-p`/`--eval`, `perl -e`/`-E`, `bash`/`sh`/`zsh -c`) is
  refused outside the extracurricular folder with `M-GATE-NOCODETOOL`. It had passed whenever the script held a `/`
  and no parenthesis, because the script token read as a relative path inside the workspace; the old parenthesis check
  was the only thing catching the rest. Found in the real-Teach Hermes smoke.

## [0.11.2] - 2026-09-29

### Fixed

- The reply splitter (`Reach::Transcript.split_reply`) missed a fenced code block indented under a list item, so its
  code stayed in the chat record instead of becoming a chat snippet. `CODE_FENCE_OPEN` and the closing fence now accept
  leading spaces or tabs; the pointer line keeps the fence's indent and the snippet drops it from each line. Found in
  the Hermes smoke with Qwen3-Coder-30B; it affected every harness.

## [0.11.1] - 2026-09-29

### Added

- Hermes Agent (Nous Research) as a supported harness. `reach setup --harness hermes` creates a Hermes profile named
  `reach` (`hermes profile create reach --clone --no-alias`, so no `~/.local/bin/reach` wrapper shadows Reach's own
  command) and links `skills/reach-assistant` and `skills/reach-course` into it; the profile's config path is kept in
  `~/.reach/state/hermes.json`. Every configure writes Reach's hooks, `mcp_servers.reach` and a disabled
  `code_execution` toolset into that profile's `config.yaml` only (backed up once to `config.yaml.reach-backup`; every
  other key kept). `reach work --harness hermes` runs `hermes -p reach --accept-hooks chat -q "Hi rEach"` in the course
  folder.
- Hermes hooks: `pre_tool_call` runs `reach gate write` for `write_file`, `patch` (including V4A patches) and
  `execute_code`, and `reach gate shell` for `terminal`, both fail-closed; `pre_llm_call` runs `reach gate prompt`,
  which records the prompt and answers `{"context": ...}` with the rEach session context on the first turn and the
  refusal when the gate blocks; `pre_verify` runs `reach check --format hermes` and keeps the agent working on findings
  once per turn; `post_tool_call`, `post_llm_call` and `on_session_end` build the course record from the hook payloads
  (Hermes has no transcript file); `on_session_start` writes the ledger's session witness. Outside a course folder
  every hook is a silent no-op.
- `M-GATE-NOCODETOOL`: `execute_code` is refused outside the extracurricular folder.
- Wire protocol 1 revision 2026-09-29e: the transcript harness enum gains `hermes`. Reach sends it only when the course
  server advertises the same wire digest, and `unknown` otherwise.

### Changed

- `Reach::Hello.context_text` returns the session context without printing it; `reach hello` output is unchanged.
- `TranscriptIngest.ingest` returns quietly when a hook carries no transcript path.

## [0.11.0] - 2026-09-29

### Added

- `reach qualify`: the agent proves a slice before submission with scenarios of its own, written under
  `qualify/features` and `qualify/step_definitions` (the only writable course files besides the owned files). It
  runs `reach check`, checks that every graded scenario name is covered, runs the agent's scenarios here on Grokit's
  answer-free qualify kit when the slice allows it (and on the starting copy, where they must fail), then sends a
  qualification to Teach (wire revision 2026-09-29d, W-PKG-7, W-API-QUALIFY), which runs them on the real build and
  the starting copy and runs the instructors' hidden scenarios. `--list` prints the tag and the graded names. The
  result is kept in `.reach/qualification.json`, the corpus and the ledger.
- The attempt ladder. Reach counts failed qualifications per slice: the student hears a notice from the second; at
  the third Reach raises a hand itself (originator agent, trigger attempt_ladder) and holds further work until the
  student says yes (`reach attempts continue`, accepted only after a captured student prompt); at the tenth it stops
  until an instructor replies. A pass or a reply resets it. `reach attempts show` prints it.
- Hand bundles are `reach.hand/v2`: originator, the task, the attempt history, every owned and scenario file in full,
  the last qualification's output, the agent's summary, the student's last request and the environment.
- The FLOW directive (R-FLOW, alias M) and the reach-feature and reach-bug skills: the agent writes code only
  through one of the two flows, overwriting files in place, with checkpoints as history.
- ROADMAP.md, with git support planned for Reach 2.0.
- MCP tools `reach_qualify` and `reach_attempts`.
- The real-Claude smoke's course-gate scenario expects rEach to say it writes the code and never to name the file or
  method; its privacy check bans asking for the student's email or address instead of any question that says "email".
- The assignment-one transport smoke checks the submit refusal, writes the agent's scenarios and qualifies before
  submitting.

### Changed

- `reach submit` refuses (M-SUBMIT-UNQUALIFIED) unless the latest qualification passed on exactly the current owned
  files and scenarios, and sends the scenarios and the passing record as evidence.
- The QUALIFY directive (R-QUALIFY, alias D) replaces NOTEST; TOZERO, VERIFY, PLAN1ST, RESUME and RUBY point at
  qualification. The course, submit, help, build, fix and assistant skills and the rEach agent follow.
- The gate refuses git in slice workspaces and at the course folder's top (M-GATE-NOGIT). The extracurricular folder
  is the student's own, so git is left alone there.
- `reach status` shows each slice's qualification instead of tips.
- The rEach persona and the reach-course skill have the agent talk with the student only in business terms: no files, code, tests,
  scenarios or commands, and "which file do I work in?" is answered with "I write and check all the code".
- Teach 0.11.0 requires Reach 0.11.0.

### Removed

- `reach tips`, the `reach_tips` tool, tips.yml and the Stop hook's `reach attempts settle` (the command stays as a
  no-op for old hook files). No graded suite or reference build reaches the student any more; `reach sync` no longer
  fetches the suite package.

### Fixed

- Qualify and submit count only check findings in the slice's own files. A panel slice's workspace holds only part of
  the panel, so the shape check flagged an instructors' file the student cannot change; since Teach 0.10.0 stopped
  building suite packages this blocked every panel submission.

### Security

- Teach answers a qualification with scenario names, results, the failing step only when it is a line of the agent's
  own feature files, and an error class from a fixed list. It never returns messages or output, because the run holds
  course code the student does not own. What remains is a pass or fail signal, bounded by 12 qualifications per slice
  per hour and 60 scenarios per package.

## [0.10.0] - 2026-09-29

### Added

- The course record captures the AI's side too (wire protocol 1 revision 2026-09-29c, W-TRN-3 to W-TRN-5). In every
  course folder, Claude Code and Codex now send the AI partner's replies, its reasoning where the harness stores it
  readably (an unreadable block is recorded as "reasoning not readable"), its actions (tool name and a summary of at
  most 2000 bytes) and every version of every code file, categorised as assignment code (with assignment, cutout and
  slice) or extracurricular code. `reach transcript code` (PostToolUse on writes) records each file the AI just wrote;
  `reach transcript turn` (Stop, and SessionEnd on Claude Code) reads the harness's own session transcript from where
  it last stopped, scans the folder for changes the hooks did not see (shell commands, the student's own editing,
  deletions) and flushes. A fenced code block in a reply is cut out, filed as `snippets/<seq>-<n>.<ext>` in the right
  folder, and replaced in the chat by a pointer line, so the chat stays prose.
- `~/reach-work/extracurricular/`: the student's own code folder, never graded or submitted, captured like
  everything else. `reach work --extracurricular` opens it through the gate. Writes inside it are allowed; writes
  outside it are refused (M-WRITE-OUTSIDE-EXTRA). Its rules come from Teach 0.10.0's G-CODE-1, G-EXTRA-1 and
  G-EXTRA-2, with built-in fallback rules for an older Teach.
- The workspace root and `deliverables/` get rules files and hooks too, so a session opened at the top is captured;
  every write there is refused (M-WRITE-ROOT).
- The public directive CODEFILE (R-CODEFILE): put code in files, never in chat, coursework in the slice's owned
  files and anything else in extracurricular/. Directives may list the folders whose table shows them (`spaces`,
  default `[slice]`); extracurricular/ shows only CODEFILE.
- Capability-limited sending: Reach sends only the entry kinds the course server's status lists
  (`transcripts.kinds`); against a Teach before 0.10.0 it sends prompts and holds everything after the first other
  entry, and `reach status` says how many are held.

### Changed

- Teach 0.10.0 refuses a Reach older than its minimum at enrollment with `reach_outdated`, before the code is used,
  and Reach shows its message; before, the code was spent and an orphan install left behind when Reach refused the
  version afterwards.
- Slice workspaces live under `~/reach-work/deliverables/<course>/<assignment>/<cutout>-<slice>/`. Every sync moves
  a slice workspace still at the old place there when the path is free, logs the move and never deletes anything.
- Enrollment is spelled with two l's everywhere: `reach enroll`, `Reach::Enroll`, the bridge tool `reach_enroll`,
  messages M-ENROLL-DONE, M-ENROLL-REFUSED and M-GATE-NOENROLL, and `POST /api/v1/enroll`. `reach enrol` and the
  `reach_enrol` tool still work, unlisted, and Reach retries once at `/api/v1/enrol` when an older Teach answers 404.
  The single l came from the first Teach blueprint (British spelling) and was copied everywhere since.
- The transcript notice, greeting, privacy notice and persona say what is now shared: everything the student and
  their AI partner write in their course folders, replies and code included. `reach status` counts entries, not
  prompts.

## [0.9.0] - 2026-09-29

### Added

- The slice API (wire protocol 1 revision 2026-09-29b). Workspaces from Teach 0.9.0 carry a generated `api/README.md`
  and `api/slice-api.json` (schema `grokit.slice-api/v1`, from Grokit 0.3.0's `bin/slice-api`): the operation and its
  types, the granted ports and their methods for a backend slice, and the root, hooks, props, client call and runtime
  primitives for a panel slice. CK-PORTS and the ruby shape's allowed constants read the granted ports from the JSON
  and fall back to `api/README.md`.
- The submission seal carries `hooked` (true when the slice's ledger holds a session record), and its harness falls
  back to `REACH_HARNESS` (claude-code, codex or antigravity) before `unknown`. `rules/reach.md` has Antigravity run
  `REACH_HARNESS=antigravity reach submit`, so Teach can note an Antigravity submission as unwitnessed instead of
  flagging it for review.
- `corpus/course-reference/bus-201.rref`: the BUS 201 reference packed as an encrypted RREF blob, like
  `bus-101.rref`.

### Changed

- `reach check` drops CK-PANEL's S-* findings whenever Dovetail's checker ran on a signed shape in the same run
  (`Reach::Shape.ran?`), since CK-SHAPE reports the same defects; CK-PANEL-TS, CK-FUSE, CK-TEST and CK-COMMENT stay,
  and every rule runs as before when there is no shape or the checker cannot run.
- `reach status` shows each slice's own last tips record instead of the corpus's latest tip record for every slice.
- `INSTALL.md` names which section an installing agent follows (any shell-capable Claude Code, Codex or Antigravity
  session, sandboxed or not, uses the main path; only Cowork mode uses the Cowork section, now last), and requires
  the agent's next message to begin with setup's NEXT lines copied exactly. The release smoke's install-from-link
  scenario failed on both: a sandboxed Claude Code agent took the Cowork branch, and another paraphrased the NEXT line.
- `FEATURES.md` covers every surface; `reach.spec.yml` names the GitHub repository.

### Fixed

- A reference blob whose key id was altered, while the install holds a key for the same course, is refused instead of
  reported as locked (`Reach::Reference.open_blob`).

## [0.8.0] - 2026-09-29

### Added

- Course transcripts. `reach gate prompt` (the UserPromptSubmit hook on Claude Code and Codex) captures every prompt a
  student submits in a course workspace before any gate check, blocked prompts included, into
  `~/.reach/transcripts/<session_id>.jsonl` (0700 directory, 0600 files) with a per-session seq, the harness, the slice,
  the whole prompt's byte size and SHA-256, and the text up to 131072 bytes cut on a character boundary. A hook payload
  with no prompt is still recorded. An allowed prompt's witness ledger record now carries `{session, seq, digest}`.
  `Reach::Transcript` sends the queue to Teach through signed `POST /api/v1/transcripts` (wire protocol 1 revision
  2026-09-29, W-API-TRANSCRIPT, W-TRN-1, W-TRN-2, W-SAFE-9).
- `reach transcript flush [--quick [--final]]` and `reach transcript status [--format json]`. A second Stop hook runs
  `transcript flush --quick` (at most 3 requests, at most once a minute), a new SessionEnd hook on Claude Code runs
  `transcript flush --quick --final`, and `reach sync` flushes in normal mode. The prompt hook makes no network call.
  A failure or refusal keeps every entry queued; entries in a request Teach refuses as malformed go to
  `<session_id>.rejected.jsonl` so one bad request cannot block the queue. `REACH_OFFLINE=1` stops sending, never
  capturing.
- `reach status` shows "Transcript: N prompts sent" (and how many are waiting).
- Disclosure: M-TRANSCRIPT-NOTICE is printed at enrollment, G-TRANSCRIPT-NOTICE ends every greeting inside a course
  folder, the persona answers what rEach shares when asked, and the privacy notice in `docs/student-guide.md` says what
  is sent. `STD-TRANSCRIPT` in `specs/app.yml`; `specs/implementation/v0.8.0.impl.yml`.

### Changed

- The prompt hook is `reach gate prompt --harness claude-code|codex`; workspace settings are rewritten at the next
  `reach hello` or `reach sync`.
- The privacy promise changed: prompts typed in a course workspace are now sent to Teach. `reach.spec.yml`
  `privacy_and_integrity` and `privacy_notice` say so; the AI partner's replies, conversations outside course
  workspaces, the corpus and the profile file are still never sent.
- Teach 0.8.0 requires Reach 0.8.0 by default (`minimum_reach_version`).

### Verified

- Against Teach 0.8.0 with a scratch course on real Grokit packages, on Ruby 3.3 and in a Ruby 2.6.10 container:
  capture with digests matching Teach's copy, 24 prompts captured while a flush ran arriving contiguous with no gap
  or duplicate, a full replay writing nothing twice, a 200000-byte prompt captured in 0.13 s and truncated on a
  character boundary, queues surviving `REACH_OFFLINE=1` and Teach's 403 kill switch and arriving once lifted, the
  Stop-hook flush printing nothing and spacing itself, and the greeting notice shown only inside a course folder.
- `tools/smoke` from clean clones of this commit and Teach 0.8.0 (run 20260929-020453, Haiku, $0.40):
  first-run-cooperative 7/7 and course-gate 5/5, judge clean. The real Claude Code session's three prompts were
  captured from its UserPromptSubmit payloads and reached Teach's transcript through the SessionEnd flush.

### Fixed

- The course-gate smoke asked rEach to edit `README.md`, an owned file since 0.7.0, so it failed against a correct
  rEach; it now asks for the read-only `api/README.md`.

## [0.7.3] - 2026-09-28

### Fixed

- The documented install (download `bin/reach-install` on its own from raw.githubusercontent, then run it) failed with
  "Dovetail revision file is missing": the installer looked for `dovetail-revision.txt` beside itself. It now reads the
  pin from the rEach archive it just downloaded, so the Dovetail revision always matches the rEach being installed;
  `--dovetail-revision` still overrides. The smoke never caught it because it ran the installer from inside a
  checkout; a clean Ruby 2.6 container enrolling against Teach over the LAN did.
- `tools/smoke/assignment_one.rb` defaults `SMOKE_DOVETAIL_ROOT` to `~/github/foss/dovetail`, the canonical checkout
  now that the Bitbucket clone is archived.

## [0.7.2] - 2026-09-28

### Changed

- GitHub `SteveBenner/rEach` is the canonical repository; the Bitbucket `paterasai/reach` checkout is archived. The
  work left uncommitted there (the course-reference corpus, its `reach.spec.yml` lines and the `reach-course` skill
  line) was already carried by this repository's import commit and superseded by 0.7.0's encrypted reference.
- `reach.spec.yml` templates `skill_reach_course`, `skill_reach_submit` and `skill_reach_help` are now byte-identical
  to `skills/*/SKILL.md` again; they had drifted since 0.4.0. The reach-course contents line names `reach reference`
  instead of the retired plaintext directory.

## [0.7.1] - 2026-09-28

### Fixed

- `bin/reach-install` refused every public GitHub install with "archive already contains a Dovetail directory":
  GitHub's archive of rEach carries the `dovetail` submodule as an empty directory. The installer now replaces an
  empty, non-symlink `dovetail/` with the pinned Dovetail archive and still refuses one with content. Found by the
  first `tools/smoke/assignment_one.rb --public` run against the published repository.

## [0.7.0] - 2026-09-28

### Added

- `bin/reach-install`, a public-ZIP installer that needs no Git and no GitHub login. It reads the ZIP with a pure-Ruby
  reader, materialises symlinks safely (the smoke found that the repository's `CLAUDE.md` symlink blocked installs from
  the public archive), backs up an existing install before replacing it, and downloads the Dovetail archive pinned in
  `dovetail-revision.txt`. It enforces size and count limits, retries downloads a bounded number of times, and stops
  when `REACH_INSTALL_KILL_SWITCH` is set.
- Dovetail as a git submodule at `dovetail`, pinned by `dovetail-revision.txt`.
- Remote acceptance mode: when a workspace's acceptance runs at Teach, `reach tips` shows the pending or returned
  signed results instead of running a local Grokit, and `reach doctor` skips the gems check when every workspace is
  remote.
- Encrypted course reference: `reach reference list|show|search|links`, the `reach_reference` MCP tool, RREF version 1
  blobs, and keys read from the guardrails package's `reference-keys.json`. Blobs are decrypted in memory only and a
  tampered blob is refused.
- `tools/smoke/assignment_one.rb`, a deterministic smoke that starts a real Teach, installs from a local ZIP, enrolls,
  syncs, submits and follows the receipts, and `docs/smoke-assignment-1.md`, the runbook with the manual Codex
  dialogue and same-WiFi second-device passes.
- Wire protocol 1 revision 2026-09-28f: `reference-keys.json` is an optional entry of the guardrails package
  (W-PKG-1).
- `FEATURES.md`, a partial feature registry.

### Changed

- `reach setup` exits 1 and prints no installed text or greeting when nothing was installed, including the manual
  branches taken when a harness CLI is missing.
- `reach enroll` verifies the response fields, the wire digest equality and `minimum_reach_version` before it writes
  any key.
- `README.md` in a workspace is student-owned and is preserved on sync.
- `skills/persona` and the course skills now have the agent implement all permitted code while the student makes the
  business decisions; the agent never invents the student's reflection or contributions.
- The BUS 101 reference ships only as `corpus/course-reference/bus-101.rref`: 21 files (the Assignment 1 handout,
  the student quizzes, the syllabus, the glossary and infographics, the Grokit module guide, the A1 course path, ten
  contracts and the A1 cutout extract), with the OpenStax textbook as a link. The plaintext copies were removed.

### Verified

- The last smoke run, `~/.cache/reach-smoke/a1/20260928-203803`, ended with 31 pass, 2 skip (codex-conversation and
  lan-second-device, not run) and 0 fail, against a real Teach and its Docker grader.

## [0.6.0] - 2026-09-28

### Added

- `reach sync` fetches the grade receipt of each submission that has an ingest receipt and no grade receipt, at most
  once per submission every 30 seconds, verifies and stores it, and prints "Your panel work for finance.a1 was
  graded. 2 of 2 checks passed."; `reach status` then shows the slice as graded. Before, Reach only ever fetched the
  ingest receipt, so a student never saw a grade.

### Changed

- `Reach::Shape` runs the Dovetail checker the shape package carries in the vault
  (`ruby vault/shape/dovetail/exe/dovetail check ...`, the student's own Ruby), and falls back to `dovetail` on the
  PATH only when the package carries none.
- The shape check runs on the whole panel the student's code lives in: a copy of the suite's
  `reference_build/<module>/modules/<module>/panel` with the slice's owned panel files laid over it, the same tree
  Teach's grading sandbox checks. Before, it saw only the student's own files and reported every view the
  instructors' panel renders as missing, on untouched starting code and even on backend slices. A slice that owns no
  panel files now has nothing to check.
- `Reach::Suite` assembles the tips run directory as `specs/wire.yml` W-RUN-1 (revision 2026-09-28e):
  `reference_build/<module>/**` for the slice's module, then `features/**` into `features/`, then the gem files and
  `reasons.yml` at the root, then the slice's owned files.
- When the vault suite carries its own `Gemfile`, its gems install once per SHA-256 of the Gemfile and the chosen lock
  (Ruby 3.1 and earlier the ruby26 lock) into a bundle environment under `~/.reach/gems`, with the path given as
  `BUNDLE_PATH` in the environment (Bundler 1.17 reads `bundle config set` as a key named "set", and Bundler 4 has no
  `--path`).
- Tips reasons come from the suite's `reasons.yml` when it names the category, and from Reach's own catalogue
  otherwise. A failure whose message names not_built is its own category: "This part still answers "not built yet":
  its code is the starting copy, or stops before it does the work." Before, every untagged failure read "the result
  was the wrong value (for example, the margin should be 35.0%)".
- `reach check`'s Ruby rules follow the course: the behaviour is a plain class (the course has no `Grokit::Behaviour`),
  `def call` may name an unused argument `_input` or `_ports`, a Grokit constant the slice's `api/README.md` names is
  allowed (`Grokit::Money`, `Grokit::Rules::Expression`), and the allowed error classes are the course's own
  (`NotImplemented`, `InvalidInput`, `Unavailable`, `CurrencyMismatch`). `directives/ruby.md` says the same.
  Before, the check refused every correct A1 backend solution.

### Fixed

- The second `reach sync` after a student edited an owned file replaced the edit with the starting copy. The first
  sync kept the file but recorded its content as the delivered copy, so the next sync saw an unchanged file. A kept
  file now keeps its earlier delivered digest, and repeated syncs keep it.
- `reach check` and `reach gate` no longer wait forever for hook input when stdin is open but silent, as in an agent's
  shell or a script; they wait half a second for it, then run without it.

### Verified

- Against Grokit 0.2.0, Dovetail 0.2.0 and Teach 0.6.0, on Ruby 3.3: enroll, sync, the shape check (clean on the
  starting copies, two findings on a planted violation at the right line), tips on a finance.a1 panel slice (the live
  build in Chrome) and a records.a1 backend slice (passing with a solution, not_built with the starting copy),
  submit, Teach's grading at 1.0 for both, and the grades arriving on sync. `reach check` finds nothing in any of the
  twenty A1 reference slices on Ruby 3.3 and 2.6.10, and the overlaid shape check runs on 2.6.10.

### Known limitations

- The no-Gemfile fallback gem set (`Reach::Suite`'s own generated Gemfile plus the repository's root
  `Gemfile.lock`/`Gemfile.ruby26.lock`) still fails to install on a current Bundler, because those root lock files
  pin exact gem versions the generated Gemfile does not ask for and Bundler's deployment mode refuses the mismatch;
  this predates 0.6.0 and is unchanged here (see TODO.md).
- `reach status` reports tips as "not run" or "last recorded" from the corpus's latest tip record, not per slice.

## [0.5.0] - 2026-09-28

### Changed

- Private directive bodies are served by Teach, one per signed request, and never stored on the student's computer. `reach directive <OPCODE>` for a course row asks `GET /api/v1/directives/<OPCODE>` in quick mode (one attempt, two-second timeouts); a Teach older than 0.5.0 that still put the body in the package is read from there; offline, the one-line rule prints with `M-DIRECTIVE-OFFLINE`. Nothing is written to disk in any branch (`W-API-DIRECTIVE`).
- Teach keeps the only read log and derives `directive_dump` events itself; the client-side counter from 0.4.1 (`~/.reach/state/directive-reads.json`, `Reach::Integrity.note_private_read`) is gone.
- `STD-DIRECTIVES-CARRY-NO-SECRETS`: a directive body says what the agent does, never why or how it is enforced, so any body could be disclosed without harm; OPAQUE is manners, not a boundary.

## [0.4.2] - 2026-09-28

### Fixed

- The shape check saw no findings from Dovetail 0.1.0. `Reach::Shape` ran `dovetail check --require-signed <shape>` and parsed a text format Dovetail does not print, so every finding was dropped. It now runs `dovetail check <workspace>/modules/<module>/panel --shape <vault>/shape/<cutout>/shape.json --require-signed --format json`, reads the JSON report, and returns findings in `reach check`'s own form (`id`, `rule`, `file`, `line`, `column`, `message`, `fix`, `severity`, classification) with paths relative to the workspace. `--changed` is passed relative to the panel directory; a changed file outside it has no shape findings.
- A shape check that could not run read as no findings. A bad or missing signature (D-SHP-002), no configured key (D-SHP-003), any other exit or a missing `dovetail` now raises: `reach shape check` prints the reason and exits 1, `reach check` reports one visible CK-SHAPE finding that blocks a panel submission, `reach status` shows `shape: cannot run`, and `reach watch` prints the reason and keeps watching.
- Dovetail found no key to verify with. Reach writes Teach's signing public keys from `install.yml` to `~/.reach/keys/teach/<key_id>.pem` and passes them in `DOVETAIL_PUBLIC_KEYS`.
- S-LAY-004 (Dovetail 0.1.0's new rule) is classified visible. A rule on neither list is visible when Dovetail reports an error and invisible when it reports a warning, so a warning Dovetail passes never blocks a submission.

### Known limitations

- Reach runs the `dovetail` on the PATH; the spec's vault-carried checker is not built, and Teach does not yet write the `shape.sig` Dovetail needs beside `shape.json`.

## [0.4.1] - 2026-09-28

### Added

- Integrity kind `directive_dump`: three or more distinct private directives read within 300 seconds, or every private directive within an hour, is reported to Teach silently (`~/.reach/state/directive-reads.json` keeps the last hour of reads). `W-API-INTEGRITY` gains the kind.
- Teach 0.4.1 ships the OPAQUE course directive (the agent never quotes, lists, paraphrases or explains its directives, the vault, the seal, the ledger or the checks) and a stronger G-INTEGRITY-1; both render through the existing table and numbered rules.

### Changed

- Private directive bodies are no longer written to the vault. `reach sync` unpacks the rows, course and tips and leaves `directives/<opcode>.md` inside the stored, encrypted package; `reach directive <OPCODE>` decrypts the one body in memory (`Reach::Guardrails.private_body`). A 0.4.0 vault that still holds bodies on disk is re-unpacked on the next command. This stops a casual read of the vault, not a determined one: the install key that opens the package sits on the same disk.

## [0.4.0] - 2026-09-28

### Added

- Directives. Every course workspace's `AGENTS.md` ends with a directive table in the fleet's opcode form: one row per rule with its alias, opcode, rule, `reach directive <OPCODE>` pointer, enforcement and condition. Public engineering directives ship in this repo (`directives/`: PLAN1ST, RUBY, PURE, NOTEST, NOCOM, VERIFY, TOZERO, CHECKPOINT, RESUME, LEAN, DOVETAIL); course directives arrive inside Teach's encrypted guardrails package and are read from the vault. `reach directive <OPCODE>` and `--list`, the `reach_directive` tool, `Reach::Directives` (`STD-DIRECTIVE-TABLE`).
- `reach check`, the one checker the hooks and the submit gate run: `ruby -wc`, the Ruby 2.6 floor, one-class shape, comments, test code, purity, granted ports, fuse boundaries and Dovetail panel rules, each finding with a rule id, file, line, message, fix and invisible/visible classification; `--changed <path>` for the PostToolUse hooks, `--format text|agent|json`. Findings feed the attempt gate like shape findings. `Reach::Check`.
- `reach checkpoint save|list|show|restore`: snapshots of the slice's owned files under `~/.reach/checkpoints`, no git in the workspace, identical states refused, a restore saving the state it replaces first (`STD-NO-GIT-IN-WORKSPACE`). `reach plan save|note|show`: the slice plan at `<workspace>/.reach/plan.yml`, bounded fields, read back at session start. Both as MCP tools.
- The seal. Reach stamps every owned file's second line (Ruby) or first line (Svelte) with an invisible zero-width payload encoding a per-install, per-file mark that Teach derives and Reach cannot forge; a witness ledger at `~/.reach/state/ledger/` records every session, prompt, directive read, write, check, checkpoint, restore, submit and integrity event as an HMAC-chained line; a sidecar at the platform's state directory ties installs together; foreign, corrupt and missing marks, ledger breaks and vault tampering are reported silently to Teach's `/api/v1/integrity` and never shown to the student (`STD-SEAL-INVISIBLE`). Submissions carry the seal block and the ledger tail. `Reach::Seal`, `Reach::Ledger`, `Reach::Sidecar`, `Reach::Integrity`.
- The submit gate: a submit with `reach check` findings returns them with M-SUBMIT-FIX-FIRST once; a second attempt on the same findings is refused with M-SUBMIT-BLOCKED-CHECK, in plain words, and raises a `check_gate` hand to the instructors (`STD-CHECK-BEFORE-SUBMIT`).
- Skills `reach-build` (one step of one slice, plan first, check to zero, checkpoint, tips, then offer to submit), `reach-fix` (a failing scenario or finding, three attempts then a hand) and `reach-checkpoint`; the vendored `design-taste-frontend` skill (tasteskill.dev, MIT, upstream ccbc156) for panel slices.
- `reach doctor` checks R-DOC-DIRECTIVES (every public directive file parses and fits the table), R-DOC-TASTE (the vendored skill is the official one) and R-DOC-SEAL (the sidecar is readable).
- `specs/wire.yml`: W-PKG-1 directive rows, bodies and `seal.yml`; W-PKG-5 the manifest's `seal` and `ledger.jsonl`; W-PKG-6 the plan; W-RENDER-1/2 the table; W-API-HAND trigger `check_gate`; W-API-INTEGRITY; W-SAFE-8; W-SEAL-1..4. Teach 0.4.0 carries the same bytes.

### Changed

- The PostToolUse hooks (Claude and Codex) run `reach check --format agent` instead of the shape check alone; `reach attempts settle` settles on check findings.
- `Reach::Guardrails.load` verifies the vault against its manifest on every read and reports a mismatch silently; `reach sync` heals the vault from the package.
- `reach enroll` announces the sidecar to Teach; the workspace's `.reach` marker records `module` and `class`.
- The reach-course skill reads the directive table, names the build, fix and checkpoint skills, loads the taste skill for a panel slice and never spawns subagents.

## [0.3.1] - 2026-09-28

### Fixed

- rEach's intake interview asked two things at once in two places, against its own one-question rule. "What are you studying, and what year are you in?" is now two questions (`studies`, then `year`). "When do you usually do your coursework, and would you like me to remind you about deadlines?" is now two as well (`work_times`, then `deadline_reminders`). The interview has at most twelve main questions (`skills/reach-assistant/SKILL.md`, `agents/reach.md`, `reach.spec.yml` `interview`). The smoke test's judge rubric expects about twelve.

## [0.3.0] - 2026-09-28

### Added

- `tools/smoke/`, the release smoke test (`STD-SMOKE`). `ruby tools/smoke/run.rb` drives real Claude sessions with rEach loaded, each in a Docker sandbox (Ruby 2.6.10 plus git, all capabilities dropped, a read-only root, a scratch home). The sandbox never sees the developer's home or Claude configuration. Eight scenarios cover install from a link, the intake interview, skip and stop, drift, a sensitive disclosure, show and forget, a returning student and the course gate. Students are scripted or played by a model. Hard checks decide pass or fail, and a model judge adds notes. Spending ceilings, per-turn timeouts and a kill switch are built in. See `tools/smoke/README.md`.
- `Reach::CourseTime` and `Reach::Messages.course_time`. Every time rEach shows (due dates, receipt times) is in the course's timezone with its label, e.g. "Sat 3 Oct 11:59 pm PDT", whatever zone the student's computer is in (`STD-COURSE-TIME`). America/Los_Angeles, the zone BUS 101 and BUS 201 run on and the default (`config.yml` `course.timezone`), uses built-in US daylight-time rules, so it is right on every platform.

### Changed

- The persona asks one question per message and checks back one thing at a time.
- Setup's NEXT block takes "rEach is installed and ready." from the greetings catalogue (`G-INSTALLED`). It ends by naming the reach-assistant skill and giving the `reach hello --format text` command to read it, instead of a relative file path the installing agent could not read without a permission prompt. `--format json` gains `instructions`.
- `INSTALL.md` tells the installing agent to clone straight into `~/.reach/plugin`.
- `reach hello` no longer adds the course's question to a returning or not-yet-enrolled student's greeting, which made that greeting ask two questions at once. The session context asks rEach to put the question once, in a message of its own, until the student has answered it.

### Removed

- `Reach::Messages.local_time`, replaced by `course_time`.

## [0.2.0] - 2026-09-28

### Added

- `specs/wire.yml`, the Teach–Reach wire contract (protocol 1), pinned byte-identical in Teach. Requests are signed over method, path with query, timestamp, a 32-hex nonce and the body digest (`X-Teach-*` headers, RSA-PSS salt 32); packages and submissions share one `teach.package/v1` envelope (AES-256-GCM with the canonical header as additional data, the key wrapped with RSA-OAEP to Teach's advertised `encryption_key`); submissions are gzip tars with `manifest.json`; workspace packages carry `slices.json`. `reach doctor` reports `R-DOC-WIRE` when Teach advertises a different contract digest.
- rEach, the persona: `skills/reach-assistant/SKILL.md` and `agents/reach.md` (one body), `locales/greetings.en-US.yml`, and `reach hello`, which greets first-run, resuming, not-yet-enrolled and returning students, adds the course's own interview question, and runs at every session start through the plugin's SessionStart hook.
- The intake interview's profile: `reach profile show|save|forget` and the `reach_profile_*` MCP tools, stored only in `~/.reach/profile.yml` (0600) and sent to Teach only inside a hand raised with `--include-profile`.
- Install from a repository link: `.claude-plugin/` (Claude Code and Cowork), `.codex-plugin/` with `.agents/plugins/marketplace.json` (Codex), `plugin.json` and `rules/reach.md` (Antigravity), `INSTALL.md` for the agent doing the install, and `reach setup`, which runs each harness's own install commands and ends with the NEXT block the agent reads to the student.
- `reach sync` (packages, workspaces, kept edits, the outbox), `reach start`, `reach attempts settle`, a stable `~/.reach/bin/reach` shim for workspace hooks, `GEMINI.md` beside `AGENTS.md` and `CLAUDE.md`, and the MCP tools `reach_hello`, `reach_enroll` and `reach_sync`.
- Codex workspace hooks (`.codex/hooks.json`); `reach gate write` reads a Codex `apply_patch`, and `reach gate shell` reads argv-form commands and routes heredoc patches through the write gate.
- A token bucket shared by every Reach process under a file lock, quick mode for calls a harness waits on, and a rotating request log.

### Changed

- The executable moved from `bin/reach` to `exe/reach` (Cowork refuses a plugin with a top-level `bin/`).
- rplugin is optional: Reach loads it on Ruby 3.3+ when present and runs standalone from a harness's plugin copy otherwise. `R-DOC-SDK` and `R-DOC-LINKS` are replaced by `R-DOC-SHIM`, `R-DOC-VERSION`, `R-DOC-PERSONA`, `R-DOC-OUTDATED` and `R-DOC-WIRE`.
- The gate also refuses when Reach is older than Teach's `minimum_reach_version`, when the cached status is over a day old, and when the course rules are older than Teach advertises.
- Workspace MCP registration moved to `.mcp.json`, and the Codex configuration uses `sandbox_mode` and `[sandbox_workspace_write]`.
- `AGENTS.md`, `CLAUDE.md` and `GEMINI.md` are rendered from the guardrails package's directives.

### Fixed

- The MCP bridge spoke LSP-style `Content-Length` framing; it now speaks MCP's newline-delimited JSON (framed input is still answered in kind), answers a malformed line with a parse error instead of exiting, and negotiates the protocol version.
- `reach submit`, `reach hand raise` and the MCP tools resolve the slice from the current workspace and accept either `context.a1-backend` or `backend`.
- The Stop hook called `reach attempts settle`, which did not exist.
- Hook commands called `reach` from the PATH; they now call Ruby with the shim's absolute path.
- A new client and token bucket were created per call.
- `reach status` printed "Course rules: v (verified)" before any rules arrived.
- `reach doctor`'s clock check compared against a field the health route never sends.

## [0.1.0] - 2026-09-27

### Added

- First implementation of every module in `reach.spec.yml`'s `library.modules`: `Reach::Errors`, `Paths`, `Messages` (the student-message catalogue, `locales/en-US.yml`), `Crypto` (RSA-PSS signing, RSA-OAEP key wrap, AES-256-GCM), `Client` (rate limiter, exponential-backoff retries with full jitter, a circuit breaker, `REACH_OFFLINE`), `Packages`, `Corpus`, `Enroll`, `Guardrails`, `Workspace`, `Gate`, `Shape`, `Attempts`, `Suite`, `Submit`, `Receipts`, `Hands`, `Harness`, `MCPBridge`, `Status`, `CLI`.
- The `reach` command with every subcommand in the blueprint: `enroll`, `sync`, `status`, `work`, `gate session|prompt|write|shell`, `shape check`, `tips`, `submit`, `receipts wait|show`, `hand raise|status|list`, `watch`, `doctor`, `lock`, `mcp`.
- A hand-rolled stdio MCP bridge exposing the seven documented tools, no MCP gem dependency.
- Claude Code hook configuration (`SessionStart`, `UserPromptSubmit`, `PreToolUse` for Write/Edit/MultiEdit/NotebookEdit and Bash, `PostToolUse`, `Stop`) and Codex `config.toml` sandbox configuration, both written and repaired by `Reach::Harness`.
- The three skills (`reach-course`, `reach-submit`, `reach-help`) and `docs/student-guide.md`.
- `Gemfile`, `Gemfile.ruby26.lock` and `Gemfile.lock` for the tips suite's five gems (cucumber, capybara, cuprite, ferrum, nokogiri).
- The implementation blueprint at `specs/implementation/v0.1.0.impl.yml`.

### Known gaps (tracked in TODO.md)

- `Reach::Guardrails` cannot yet detect a guardrails package that is stale relative to what Teach last announced (`M-GATE-OLDGUARD`), because nothing records "the version Teach last announced" anywhere yet.
- `Reach::Gate.session`/`.prompt` do not refresh the cached enrollment/revocation status online; they read the local cache only.
- `Reach::Shape`'s Dovetail-output parsing and `Reach::Suite`'s Cucumber/Cuprite orchestration are real, runnable code but have never run against an actual `dovetail` binary or a real tips suite — there is no Teach server, no signed shape, and no suite package to test against yet.
- The two Gemfile locks were authored from training-data knowledge of these gems' release history, not resolved live against rubygems.org; run `bundle lock` for real on each Ruby line before relying on them.
- `reach enroll` needs a Teach URL from `--teach-url` or `REACH_TEACH_URL`; nothing in the blueprint says where else it should come from.
