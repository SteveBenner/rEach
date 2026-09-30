# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- `corpus/course-reference/695ad-781.rref`: the 695AD-781 reference packed as an encrypted RREF blob, like
  `mgmt-327.rref`.

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
- The MGMT 327 reference ships only as `corpus/course-reference/mgmt-327.rref`: 21 files (the Assignment 1 handout,
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
- `Reach::CourseTime` and `Reach::Messages.course_time`. Every time rEach shows (due dates, receipt times) is in the course's timezone with its label, e.g. "Sat 3 Oct 11:59 pm PDT", whatever zone the student's computer is in (`STD-COURSE-TIME`). America/Los_Angeles, the zone MGMT 327 and 695AD-781 run on and the default (`config.yml` `course.timezone`), uses built-in US daylight-time rules, so it is right on every platform.

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
