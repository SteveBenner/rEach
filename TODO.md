# TODO

## Verified in 0.2.0

- [x] End-to-end against a real Teach 0.2.0 on Ruby 3.3 and in a Ruby 2.6.10 container: enrol, sync, read-only workspace, gate (including Codex patch and argv forms), submit with a verified ingest receipt, hand raised and answered, a non-owned file rejected by Teach, revocation.
- [x] A live Claude Code session loads the plugin, connects the MCP bridge (13 tools) and opens with the first-run greeting.
- [x] `claude plugin marketplace add` / `plugin install reach@reach` and `codex plugin marketplace add` / `plugin add reach@reach` install 0.2.0 into scratch homes.
- [x] `M-GATE-OLDGUARD`, the "what's new" question and request signing are settled by `specs/wire.yml` (status advertises package versions and keys).

## Verified in 0.4.0

- [x] End-to-end against a scratch Teach 0.4.0 on Ruby 4.0.6, with the Reach side on Ruby 3.3 and in a Ruby 2.6.10 container: enrol announces the sidecar; sync unpacks directive rows, bodies and the seal; `AGENTS.md` renders the table; `reach check` names CK-RUBY-SYNTAX, CK-COMMENT, CK-PURE, CK-PORTS, CK-RUBY-FLOOR and CK-RUBY-SHAPE on a bad behaviour and nothing on a good one; plan, checkpoint (save, same-state refusal, restore); a clean submit assessed `clean` with a verified ledger and the file witnessed; the submit gate (fix-first, then blocked with a `check_gate` hand); a corrupt mark healed and reported; a foreign mark assessed `foreign:<install>:<student>`; a vault edit reported silently and healed at sync.

## Verified in 0.6.0

- [x] End-to-end against Grokit 0.2.0, Dovetail 0.2.0 and Teach 0.6.0 with Reach on Ruby 3.3: enrol, sync, a shape package compiled and signed by Teach with Dovetail's exported checker, the shape check on the overlaid panel, tips on a finance.a1 panel slice and a records.a1 backend slice from a real suite package, submit, grading at 1.0 in Teach's Docker sandbox, and the grade receipts arriving on sync. `reach check` finds nothing in any of the twenty A1 reference slices on Ruby 3.3 and 2.6.10.

## Release 0.7.0 open items

- [x] Run the manual Codex dialogue pass from `docs/smoke-assignment-1.md` (passed 2026-09-29, live).
- [x] Run the same-WiFi second-device test from `docs/smoke-assignment-1.md` (passed 2026-09-29, live).
- [x] Verify the public ZIP install against real GitHub after the push (passed 2026-09-28 with `--public`, after the 0.7.1 empty-submodule fix).
- [ ] The installer's Windows path is unverified.
- [ ] The plaintext MGMT 327 files remain in the public GitHub history (the Initial commit) unless history is rewritten.
- [x] The 695ad-781 reference now ships as an encrypted `.rref` (packed 2026-09-29 from the existing hand-vetted copy, key id `09d72206a5d3b1ae`; parity with mgmt-327). The plaintext source copy still sits under `corpus/course-reference/.backup/` pending a human's go-ahead to delete it (AGENTS.md Part E; the delete itself was refused by the auto-mode classifier as irreversible).
- [x] A tampered blob's key id now reports refused, not locked, when we hold a key for the same course under a different key id (fixed 2026-09-29 in `Reach::Reference.open_blob`).
- [ ] Complete the `FEATURES.md` inventory: it covers the 0.7.0 surfaces and the core flows only.

## Slice API

- [x] Specify and ship the slice API: the generic surface a student's behaviour and panel program against. Shipped in 0.9.0 as a generated reference (Grokit 0.3.0 `bin/slice-api`, Teach 0.9.0 writes `api/README.md` and `api/slice-api.json`, wire revision 2026-09-29b). The "one slice per week" wording did not match the Grokit module guide, which sets A1 to A4 per module; the course keeps that cadence.
- [x] `reach check` defers CK-PANEL's S-* rules to Dovetail's checker whenever it ran on a signed shape, and runs them itself otherwise (0.9.0).
- [x] Antigravity submissions: decided and shipped in 0.9.0. The seal carries `hooked` and the harness (Antigravity runs `REACH_HARNESS=antigravity reach submit`); Teach notes a hookless submission as unwitnessed instead of flagging it for review, behind `TEACH_UNHOOKED_HARNESS_POLICY` (default `note`).

## Before a class uses it

- [ ] Publish the repository (GitHub mirror planned); installing from a link needs a public repository.
- [ ] Set `teach.url` in `config.yml` for the course, so `reach enrol <code>` needs no `--teach-url`.
- [x] A real signed Dovetail shape and a real `dovetail` binary to verify `Reach::Shape`'s output parsing: done in 0.4.2 against dovetail 0.1.0 on Ruby 3.3 and 2.6.10, and in 0.6.0 against a shape package Teach compiled and signed from Grokit's contracts.
- [x] A real suite package and reference build to verify `Reach::Suite` end-to-end: done in 0.6.0 with Grokit 0.2.0's suite.
- [x] `reach status` now shows each slice's own last tips result instead of the corpus's global latest tip record (fixed 2026-09-29 in `Reach::Status.tips_summary`).
- [ ] Run `bundle lock` for real against `Gemfile` for both the Ruby 2.6 and modern lines, and diff against the hand-authored locks.
- [x] A live Codex session with the plugin installed: confirm the hook-trust prompt, the SessionStart context and the greeting (passed 2026-09-29, live).
- [ ] Antigravity: `agy` is not installed here; `reach setup --harness antigravity`, `agy plugin install` and the plugin-directory link are untested.
- [ ] Confirm whether Claude applies the plugin's `settings.json` `"agent": "reach:reach"` for an installed plugin; a `--plugin-dir` session did not report it (the greeting works without it).
- [ ] Windows: hook-command quoting and the Antigravity copy fallback are untested.

## Known limits

- Desktop apps (Claude app, Codex app, Antigravity desktop) wait for the student to type first, so rEach introduces itself in its first reply rather than unprompted.
- Codex runs plugin and workspace hooks only after the student trusts them; until then enforcement is the read-only files plus the submit-time check.
- Codex's plugin carries no MCP server (Codex does not substitute `${CLAUDE_PLUGIN_ROOT}`); outside course workspaces rEach uses the CLI, and Codex's default sandbox may stop `reach profile save` writing to `~/.reach` until the student approves it (not yet observed).
- Antigravity has no documented hook format, so it gets no hooks.
- DeepSeek's harness is unsupported; the Gemini consumer app has no plugins.

## rplugin

- [x] rplugin linked only `bin/<id>` onto the PATH and ignored `contents.scripts`, so since the move to `exe/reach` it linked no executable. Fixed 2026-09-29 in `Rplugin::Installer#plugin_plan` (`~/rstack-uber/foss/rplugin`): it now falls back to the `contents.scripts` entry whose basename equals the plugin id when no `bin/<id>` exists. `rplugin doctor`'s existing `link_findings` needed no change — it already validates whatever the plan produces, it just had nothing to validate before. Verified with `rplugin install --dry-run` against reach (now plans `~/.local/bin/reach` → `exe/reach`) and against aivorytower/rubric/integration-bitbucket/likeaboss (no regressions; likeaboss was silently affected by the same bug and now also gets a link). Not yet applied for real on this machine — `rplugin install` for reach is separately blocked by an unrelated pre-existing conflict (`~/.claude/skills/design-taste-frontend` exists and is not a symlink) and by the manifest id ("reach") not matching the GitHub directory name ("rEach"); the dev-machine `~/.local/bin/reach` shim still stands until those are resolved.
- [ ] `rplugin install reach` links the reach-assistant skill and the reach agent into the user's own `~/.claude`, where the skill's "use at the start of every session" applies to every session; on a developer's machine, leave them unlinked.

## Course reference corpus

- [ ] `corpus/course-reference/` (MGMT 327 and 695AD-781) is a one-time hand-vetted copy from the instructor's AIvoryTower course stores, made 2026-09-28. It does not stay in sync with the instructor's evolving syllabus, glossary or assignments. Build a live-update mechanism (re-running the same vetted copy from AIvoryTower, or a future instructor-upload path) so this directory tracks the real course material instead of going stale. Deferred; not started.
- [ ] Whatever sync mechanism gets built must carry forward the same hard exclusion by hand: instructor-only material (answer keys, instructor keys, grading rubrics with solutions, or anything else marked as an instructor/answer-key artifact) must never land in `corpus/course-reference/`, no matter how the sync pulls its source.

## Housekeeping

- [ ] Decide the licence (currently `undecided` in `reach.spec.yml`) before any public release; `exe/reach` and `lib/reach.rb` already carry an MIT SPDX line from 0.1.0.
