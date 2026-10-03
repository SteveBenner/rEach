# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

- `tools/smoke/assignment_one.rb` links the smoke course to its reference (`<Teach command>`), which Teach
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
  `~/src/teach`) into the run directory, so a dirty Teach checkout never reaches the run.

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
- `config.yml` enrollment identity rules match live Teach: student IDs of six or seven digits (`^[0-9]{5,10}$`) and
  usernames with an optional trailing letter (`^[a-z][a-z0-9._-]{1,31}$`, for example `jsmith`). The enrollment
  prompts (`M-ENR-ASK-ID`, `M-ENR-ID-FORMAT`) and `docs/student-guide.md` no longer say the ID has seven digits.
  Verified in scratch homes against live Teach over the public URL: the prompt-hook flow previewed the BUS 201
  code and reached the confirm step for `jsmith` / 20410001 and for `jdoe` / 20410002 without asking for a URL.

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
  two edits still matches), their institutional username (`FLLLNNN@school.example`) and their seven-digit student ID.
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
- `tools/smoke/assignment_one.rb` packs the smoke's reference blob for Teach (`<Teach setting>`) and no longer
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
  for Teach (0.14.0 and later) and drop it afterwards, so a `<Teach setting>` inherited from the shell can never
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
