# TODO

## Live sessions (0.23.0, wire revision 2026-10-03f)

- [ ] Run a live session on a real macOS and a real Windows install, and on Ruby 2.6; only Linux with Ruby 3.3 ran
      (on 2.6.10 the code was syntax-checked and loaded, nothing more).
- [ ] Run it under Codex and Cowork; only Claude Code ran as the student's harness.
- [ ] A student at the ordinary sign-in question cannot ask for a live session until they answered it; only a
      locked-out or refused sign-in opens the blocked path (a typed yes there would be ambiguous).
- [ ] The blocked path ran through the prompt hook from a terminal only; see it once in a real harness, where the
      block text is what the student reads.
- [ ] A student who becomes blocked while a `reach live watch` is still running has their notices given to the
      assistant, not shown under the block text. Not run.
- [ ] The wake exists on Claude Code 2.1.288 or newer only. Codex, Cowork and Hermes show notices at the next
      prompt; the desktop notification ran on Linux only.
- [ ] `tools/fake_teach` has no live routes yet.
- [ ] The installation and setup guide (both copies) does not mention live sessions; the student guide and the
      reach-help skill do.
- [ ] Agent messages for regular students stay behind the safety gate in ROADMAP.md.

## Analytics

- [ ] Analytics we capture, identified by the enrolled student ID: decide and document which usage data, metadata
      and analytics rEach sends to Teach, and send them keyed to the enrollment (docs/DESIGN-DECISIONS.md, data
      capture).

## Storage gates and AI-export import (0.18.0)

- [ ] Run `reach import pick` on a real macOS (osascript) and Windows (PowerShell -STA) desktop; only zenity and
  kdialog ran on Linux, against fake binaries.
- [ ] `reach import search|next|show` run in a course folder land in the course record's command line (first 200
  characters) like `reach remember`; the skill says to work from the extracurricular folder, but nothing enforces it.
- [ ] Build microbrain compression and compaction once a student's microbrain passes 512 MB (ROADMAP.md).

## Microbrain (0.16.15)

- [ ] Ship rplugin and rcorpus in the runtime kit so students get corpus-side recall (`Rcorpus::Context`) and
      consolidation; deferred 10-01 pending the decision to publish them. Students run on the spool plus Reach's own
      recall, and the planes are admitted wherever rplugin is installed.
- [x] Erase tombstoned history from corpus planes: `reach memory forget` scrubs Reach's spool only, so a finding or
      source already admitted into a plane stays there until rcorpus can erase a tombstoned id. (Done in 0.16.22 with
      rcorpus 0.10.0 `Rcorpus::Erase`: verified in a scratch HOME that a forgotten finding's text is in no file.)
- [x] Verify the in-process `Rcorpus::Context` recall and `Rcorpus::Consolidate` paths once rcorpus 0.9.0 lands.
      (Done 2026-10-02: recall never reached Context in a fresh process, and Consolidate tombstoned every finding and
      copied private bodies into committed segments; fixed in 0.16.22 and rcorpus 0.10.0.)

## Enrollment v2 (0.16.0, branch `enrollment-v2`)

- [x] Teach's half (roster, course codes, preview and shape v2 routes, stamp signing, fingerprint check,
      `minimum_reach_version`, byte-identical wire). Done in Teach 0.16.0 (wire 2026-10-01c), with device moves and
      handout expiry.
- [x] Merge `enrollment-v2` into main and tag. Shipped as 0.16.0 on top of the peer's 0.15.0.
- [x] A student can enroll with a course code only once the live Teach runs 0.16.0 with a roster and a minted code.
      (Live Teach runs 0.17.0 with the BUS201FA26 roster imported and a class-wide code minted.)
- [ ] Verify a real Codex session: the shared `hooks/hooks.json` passes `--harness claude-code` and
      `${CLAUDE_PLUGIN_ROOT}`; whether Codex's plugin hooks honor that and block a prompt is unproven.
- [ ] Field report 2026-10-02: on 0.16.x some students' Codex enrolls without trouble and some is stuck. The stuck
      ones keep being told to approve rEach's hooks (M-ENR-AGENT-GUIDE), but the plugin and its hooks already show as
      enabled in Codex's settings and neither the student nor the maintainer found anything left to approve in the app. Likely
      openai/codex#47925 (Codex >= 0.156 loads no plugin hooks while the root `plugin.json` exists), whose cache repair
      shipped in 0.16.16 and was first tagged in v0.16.20; unconfirmed. Find each stuck student's Reach and Codex
      versions, and stop the agent guide from sending a student to approve hooks that are already enabled. (The guide half is fixed in 0.16.24; the version check still needs the students.)
- [ ] Verify a real Hermes session (enroll hook as context) and Antigravity (CLI only). Field report 2026-10-02:
      Hermes works for students; its enrollment is still untested.
- [x] Verify machine ids on macOS (ioreg) and Windows (reg query); only Linux and a Docker container were exercised. (Done in 0.16.8: the platform smoke reads IOPlatformUUID on GitHub macOS arm64 and Intel and MachineGuid on Windows x64 and arm64, and the fake Teach accepts the fingerprint on status.)
- [x] tools/smoke still enrolls with shape v1 codes; move the smoke to the v2 flow once Teach mints course codes.
      (Done in 0.16.22: roster import, course code mint and `--password-stdin`; assignment-one passes every step.)
- [x] The plugin-level hook runs in every Claude Code session on a machine with rEach installed; a developer
      machine with the plugin enabled is locked too until it enrolls. (Answered by the instructor unlock in 0.16.17:
      pasting an instructor code lifts the lock on that install.)

## Verified in 0.2.0

- [x] End-to-end against a real Teach 0.2.0 on Ruby 3.3 and in a Ruby 2.6.10 container: enroll, sync, read-only workspace, gate (including Codex patch and argv forms), submit with a verified ingest receipt, hand raised and answered, a non-owned file rejected by Teach, revocation.
- [x] A live Claude Code session loads the plugin, connects the MCP bridge (13 tools) and opens with the first-run greeting.
- [x] `claude plugin marketplace add` / `plugin install reach@reach` and `codex plugin marketplace add` / `plugin add reach@reach` install 0.2.0 into scratch homes.
- [x] `M-GATE-OLDGUARD`, the "what's new" question and request signing are settled by `specs/wire.yml` (status advertises package versions and keys).

## Verified in 0.4.0

- [x] End-to-end against a scratch Teach 0.4.0 on Ruby 4.0.6, with the Reach side on Ruby 3.3 and in a Ruby 2.6.10 container: enroll announces the sidecar; sync unpacks directive rows, bodies and the seal; `AGENTS.md` renders the table; `reach check` names CK-RUBY-SYNTAX, CK-COMMENT, CK-PURE, CK-PORTS, CK-RUBY-FLOOR and CK-RUBY-SHAPE on a bad behaviour and nothing on a good one; plan, checkpoint (save, same-state refusal, restore); a clean submit assessed `clean` with a verified ledger and the file witnessed; the submit gate (fix-first, then blocked with a `check_gate` hand); a corrupt mark healed and reported; a foreign mark assessed `foreign:<install>:<student>`; a vault edit reported silently and healed at sync.

## Verified in 0.6.0

- [x] End-to-end against Grokit 0.2.0, Dovetail 0.2.0 and Teach 0.6.0 with Reach on Ruby 3.3: enroll, sync, a shape package compiled and signed by Teach with Dovetail's exported checker, the shape check on the overlaid panel, tips on a finance.a1 panel slice and a records.a1 backend slice from a real suite package, submit, grading at 1.0 in Teach's Docker sandbox, and the grade receipts arriving on sync. `reach check` finds nothing in any of the twenty A1 reference slices on Ruby 3.3 and 2.6.10.

## Verified in 0.10.0

- [x] End-to-end against a scratch Teach 0.10.0, with Reach on Ruby 3.3 and the capture path again in a Ruby 2.6.10 container. Covered: enrollment through a proxy that 404s `/api/v1/enroll` (Reach retried `/api/v1/enrol`), after a too-old Reach was refused with `reach_outdated` and the code stayed unused; the `deliverables/` layout and the move of a pre-0.10.0 slice; `extracurricular/` writes allowed inside and refused outside, and the root refusing writes; prompts, replies, unreadable and readable reasoning, actions (a subagent's noted), AI writes, chat snippets and turn-end scans reaching the student's subcorpus with byte-identical mirrors; a symlink to a secret never read; kinds held against a status without `transcripts` and sent once it returned; a reply the student interrupted recorded before the next prompt.
- [x] Real-Claude smoke (`tools/smoke`, Haiku, from a clean clone of the release commit) run 20260929-040851: first-run-cooperative 7/7, course-gate 5/5. The course-gate session's prompts, replies, reasoning, actions and the owned files' baseline scan all reached the scratch Teach's subcorpus, the final reply through SessionEnd. The run before it, 20260929-040452, failed one check in each scenario because Haiku ended the interview early and saved a partial profile; the rerun passed.
- [ ] Run a live Codex session in a course folder and check its replies, reasoning summaries and apply_patch code reach Teach; the Codex path is verified only on a synthetic rollout file.
- [ ] Claude Code stores thinking as a signature with empty text, so its reasoning arrives as "reasoning not readable"; revisit if the harness starts storing readable thinking.

## Verified in 0.11.0

- [x] End-to-end against a scratch Teach 0.11.0 and Grokit 0.5.0 on Ruby 4.0.6, Reach loading on 2.6.10 and 4.0.6: workspaces carry the answer-free qualify kit and the writable qualify folders; a backend slice (context.a1) qualified locally and on Teach in about 22 s (agent rows pass, starting-copy rows fail, 3 of 3 hidden pass); submit refused after a step file changed, then accepted with the evidence stored and graded 3 of 3; a panel slice (finance.a1) qualified on Teach and graded 2 of 2; the ladder gave a notice at 2, one agent v2 hand at 3, held work until a captured student prompt and `reach attempts continue`, stopped at 10, and reset on an instructor reply; git refused in slices; a step that raised a reference source string came back as step text and an error class only.
- [x] Assignment-one transport smoke on 0.11.0 against the Teach 0.11.0 tree (2026-09-29): 33 pass, 2 manual skips; submit refused before qualifying, then qualified locally and on Teach, graded 1.0.
- [x] Real-Claude smoke (Haiku, from a clean clone of the release commit) run 20260929-060009: 8 of 8 scenarios pass. In course-gate rEach now answers "which file do I work in?" with "I write and check all the code". Earlier runs that day failed on a model-played student inventing a different install link and on a privacy check that fired on the word email; both passed on rerun and the check was narrowed.
- [ ] The judge still notes rEach sometimes asks two things in one reply (course-gate) and does not use the first-run greeting right after a profile is forgotten (advisory only).
- [x] Portable Ruby 4.0.7 and Chrome for Testing on the student side, so panel slices can qualify locally too. (Shipped in 0.14.0 as `reach runtime install`; panels qualify locally where the course ships a practice recording.)
- [ ] The runtime bundles for macOS, Windows and Linux arm64 are built and relocation-checked only in CI; no student machine on those platforms has installed one yet.
- [x] Publish runtime-4.0.7-r2 and pin it (lib/reach/runtime_kit.rb RUNTIME_TAG and MANIFEST_SHA256): the tag's CI run 36838426832 built and passed both Linux kits (glibc 2.28) and both macOS kits, but windows-x86_64 failed its relocation check and publish was skipped. Read that job's log (needs a GitHub login), fix or re-run it ("Re-run failed jobs" on the run page), then pin. Until then Linux below glibc 2.38 cannot use the kit. (Done in 0.16.4: the log showed every check passing and a still-exiting Chrome holding chrome.dll during cleanup; fixed in 0.16.3, rebuilt as runtime-4.0.7-r3, all five kits passed and published, and Reach pins r3.)

## Verified in 0.11.1 to 0.11.3 (Hermes)

- [x] Hermes Agent 2026.9.24 against a local Teach 0.11.1 (2026-09-29): setup, `reach work`, the gate, `pre_verify` check, `reach qualify`, the ladder, submit refusal and the course record filed as a `hermes` chat.
- [x] Claude Sonnet as Hermes' model (local shim over `claude -p`, 41 calls, $2.75): the course rules held and Teach's qualification passed; the agent declined to submit with a blank README.
- [x] The smokes found and fixed an indented-fence miss in the reply splitter (0.11.2) and three shell-gate problems (0.11.3).
- [x] Qwen3-Coder-30B as Hermes' model does not keep the course rules (talks code, calls failing work ready); students need guidance on which models are fit. (Done in 0.16.22: `docs/student-guide.md` names Claude Sonnet or Opus and OpenAI GPT-5.x, and advises against local models until the instructor verifies one.)
- [x] Install from the link with Hermes: an agent reading `INSTALL.md` in a clean home (2026-09-30, Claude via the shim, public `main` 0.11.4): installer, `reach setup --harness hermes` and a working launch command. The agent still skipped the NEXT lines on purpose ("you didn't ask for that"), as Sonnet does in Claude Code.
- [ ] An interactive Hermes session (first-use hook prompts, a student typing), and a Hermes provider connection instead of the shim.
- [x] Teach names Hermes chat files by the session id's first 8 characters, which for Hermes is the date; two sessions starting in the same minute share a file. (They got a `_2` suffix rather than one file; Teach 0.17.1 names them by the session's random suffix.)

## Release 0.7.0 open items

- [x] Run the manual Codex dialogue pass from `docs/smoke-assignment-1.md` (passed 2026-09-29, live).
- [x] Run the same-WiFi second-device test from `docs/smoke-assignment-1.md` (passed 2026-09-29, live).
- [x] Verify the public ZIP install against real GitHub after the push (passed 2026-09-28 with `--public`, after the 0.7.1 empty-submodule fix).
- [ ] The installer's Windows path is unverified.
- [ ] The plaintext BUS 101 files remain in the public GitHub history (the Initial commit) unless history is rewritten.
- [x] The bus-201 reference now ships as an encrypted `.rref` (packed 2026-09-29 from the existing hand-vetted copy, key id `09d72206a5d3b1ae`; parity with bus-101). The plaintext source copy still sits under `corpus/course-reference/.backup/` pending a human's go-ahead to delete it (AGENTS.md Part E; the delete itself was refused by the auto-mode classifier as irreversible). Resolved in 0.14.5: `corpus/` is gone and the source copy lives with Teach.
- [x] A tampered blob's key id now reports refused, not locked, when we hold a key for the same course under a different key id (fixed 2026-09-29 in `Reach::Reference.open_blob`).
- [x] Complete the `FEATURES.md` inventory: it covers the 0.7.0 surfaces and the core flows only. (Done in 0.16.22: every surface through 0.16.21, with unverified rows stated.)

## Slice API

- [x] Specify and ship the slice API: the generic surface a student's behaviour and panel program against. Shipped in 0.9.0 as a generated reference (Grokit 0.3.0 `bin/slice-api`, Teach 0.9.0 writes `api/README.md` and `api/slice-api.json`, wire revision 2026-09-29b). The "one slice per week" wording did not match the Grokit module guide, which sets A1 to A4 per module; the course keeps that cadence.
- [x] `reach check` defers CK-PANEL's S-* rules to Dovetail's checker whenever it ran on a signed shape, and runs them itself otherwise (0.9.0).
- [x] Antigravity submissions: decided and shipped in 0.9.0. The seal carries `hooked` and the harness (Antigravity runs `REACH_HARNESS=antigravity reach submit`); Teach notes a hookless submission as unwitnessed instead of flagging it for review, behind `<Teach setting>` (default `note`).

## Before a class uses it

- [ ] Publish the repository (GitHub mirror planned); installing from a link needs a public repository.
- [x] Set `teach.url` in `config.yml` for the course, so `reach enroll <code>` needs no `--teach-url` (0.16.19: `https://sven-f1l1.tail062fd2.ts.net`).
- [x] A real signed Dovetail shape and a real `dovetail` binary to verify `Reach::Shape`'s output parsing: done in 0.4.2 against dovetail 0.1.0 on Ruby 3.3 and 2.6.10, and in 0.6.0 against a shape package Teach compiled and signed from Grokit's contracts.
- [x] A real suite package and reference build to verify `Reach::Suite` end-to-end: done in 0.6.0 with Grokit 0.2.0's suite.
- [x] `reach status` now shows each slice's own last tips result instead of the corpus's global latest tip record (fixed 2026-09-29; since 0.11.0 it shows each slice's qualification instead).
- [x] Run `bundle lock` for real against `Gemfile` for both the Ruby 2.6 and modern lines, and diff against the hand-authored locks. (Done in 0.16.22: the modern lock resolves unchanged; the Ruby 2.6 lock could not install, so it is regenerated in a Ruby 2.6.10 container and cucumber 8.0.0 installs and runs there.)
- [x] A live Codex session with the plugin installed: confirm the hook-trust prompt, the SessionStart context and the greeting (passed 2026-09-29, live).
- [ ] A live Codex session on 0.15.0: the start-up hook moved to `hooks/codex.json` (generated by rplugin), so confirm Codex asks to trust it again and that it runs. A scratch install loaded the MCP bridge but cannot run untrusted hooks.
- [ ] A live Codex session on macOS with 0.16.16: confirm both rEach hooks appear under `/hooks` (or Settings > Hooks), trust them, and see the greeting. The scratch `hooks/list` check passed; drop the cache repair once openai/codex#47925 is fixed.
- [ ] Antigravity: `agy` is not installed here; `reach setup --harness antigravity`, `agy plugin install` and the plugin-directory link are untested.
- [ ] Confirm whether Claude applies the plugin's `settings.json` `"agent": "reach:reach"` for an installed plugin; a `--plugin-dir` session did not report it (the greeting works without it).
- [ ] Windows: hook-command quoting and the Antigravity copy fallback are untested.

## Known limits

- Desktop apps (Claude app, Codex app, Antigravity desktop) wait for the student to type first, so rEach introduces itself in its first reply rather than unprompted.
- Codex runs plugin and workspace hooks only after the student trusts them; until then enforcement is the read-only files plus the submit-time check.
- Codex's default sandbox may stop `reach profile save` writing to `~/.reach` until the student approves it. Since 0.15.0 Codex's plugin carries the MCP bridge (`mcp.json`, `${PLUGIN_ROOT}` expanded by Codex to its plugin cache).
- Antigravity has no documented hook format, so it gets no hooks.
- DeepSeek's harness is unsupported; the Gemini consumer app has no plugins.

## rplugin

- [x] rplugin linked only `bin/<id>` onto the PATH and ignored `contents.scripts`, so since the move to `exe/reach` it linked no executable. Fixed 2026-09-29 in `Rplugin::Installer#plugin_plan` (`~/superproject/foss/rplugin`): it now falls back to the `contents.scripts` entry whose basename equals the plugin id when no `bin/<id>` exists. `rplugin doctor`'s existing `link_findings` needed no change — it already validates whatever the plan produces, it just had nothing to validate before. Verified with `rplugin install --dry-run` against reach (now plans `~/.local/bin/reach` → `exe/reach`) and against aivorytower/rubric/integration-bitbucket/likeaboss (no regressions; likeaboss was silently affected by the same bug and now also gets a link). Not yet applied for real on this machine — `rplugin install` for reach is separately blocked by an unrelated pre-existing conflict (`~/.claude/skills/design-taste-frontend` exists and is not a symlink) and by the manifest id ("reach") not matching the GitHub directory name ("rEach"); the dev-machine `~/.local/bin/reach` shim still stands until those are resolved.
- [x] Since 0.15.0 the manifest declares no `scripts` entry, so `rplugin install reach` no longer links `exe/reach` over Reach's own `~/.local/bin/reach` shim. The native packages are generated by `rplugin package` (rplugin 1.2.0) and `rplugin check` reports 0 through `~/.rplugins/reach`; checked against the clone directory `rEach` it reports the id/directory-name mismatch.
- [x] `rplugin install reach` links the reach-assistant skill and the reach agent into the user's own `~/.claude`, where the skill's "use at the start of every session" applies to every session; on a developer's machine, leave them unlinked. (Since rplugin 1.2 reach installs natively as a Claude Code and Codex plugin, so nothing is linked into `~/.claude`; the three stale 09-28 links on the maintainer's machine were moved to `~/.backup/reach-skill-links-20261002/`.)

## Course reference corpus

- [x] `corpus/course-reference/` (BUS 101 and BUS 201) is a one-time hand-vetted copy from the instructor's AIvoryTower course stores, made 2026-09-28. It does not stay in sync with the instructor's evolving syllabus, glossary or assignments. Build a live-update mechanism (re-running the same vetted copy from AIvoryTower, or a future instructor-upload path) so this directory tracks the real course material instead of going stale. Deferred; not started. Moved to Teach in 0.14.5: Reach carries no course material.
- [x] Whatever sync mechanism gets built must carry forward the same hard exclusion by hand: instructor-only material (answer keys, instructor keys, grading rubrics with solutions, or anything else marked as an instructor/answer-key artifact) must never land in `corpus/course-reference/`, no matter how the sync pulls its source. Moved to Teach in 0.14.5: Reach carries no course material.

## Home inside reach-work (branch in-workspace)

- [ ] Run the Windows sandbox probe: with the project opened at `~/reach-work`, measure that writes inside `.reach-home` succeed, whether the network opens, that the install and relocation run under Full access, and whether the top-level `.codex` is read-only. Nothing about the Windows sandbox is proven.
- [ ] Measure whether the Codex sandbox allows the network on macOS and Linux with an allow rule; until then enroll, sync, updates and the subscription check need Full access.
- [ ] `scripts/reach-install.ps1` is changed but was never run (no PowerShell here); run it on Windows.
- [ ] Verify the relocation on macOS (case-insensitive filesystem path handling in `Paths.realish` is untested there).
- [x] `lib/reach/late_work.rb` (`prompt_notice`) and `lib/reach/submit.rb` (`default_archive_assignment`) still use the cwd-based `current_workspace_path`; move them to `Gate.focus_workspace` so a root-kind session behaves like the rest.
- [ ] `docs/INSTALLATION-AND-SETUP-GUIDE.docx` still describes `~/.reach`; rebuild both copies of the guide.
- [ ] No receipt was in the relocation fixture (no grader available); check that receipts and acks survive a relocation.
- [ ] `state/enroll/fingerprint_cache.json` keeps the legacy path inside its key after a relocation; it is recomputed and harmless, but is reported in `legacy_path_hits`.

## Housekeeping

- [ ] Decide the licence (currently `undecided` in `reach.spec.yml`) before any public release; `exe/reach` and `lib/reach.rb` already carry an MIT SPDX line from 0.1.0.
