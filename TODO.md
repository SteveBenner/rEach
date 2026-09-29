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

## Slice API

- [ ] Specify and ship the slice API: the generic surface a student's behaviour and panel program against, one slice per week so a module is complete by week 11 (the Grokit module guide). Until it ships, `api/README.md` in each workspace names only the granted ports.
- [ ] Dovetail's checker is not installed here, so CK-PANEL's rules run on their own; when a signed shape package and a `dovetail` binary exist, `reach check` should defer the panel rules to it.
- [ ] Antigravity has no hooks, so its sessions leave no `session`, `prompt` or `write` records; a submission from it is assessed `not witnessed by the harness` by design. Decide whether Teach should treat that harness as unwitnessed-but-expected.

## Before a class uses it

- [ ] Publish the repository (GitHub mirror planned); installing from a link needs a public repository.
- [ ] Set `teach.url` in `config.yml` for the course, so `reach enrol <code>` needs no `--teach-url`.
- [x] A real signed Dovetail shape and a real `dovetail` binary to verify `Reach::Shape`'s output parsing: done in 0.4.2 against dovetail 0.1.0 on Ruby 3.3 and 2.6.10, and in 0.6.0 against a shape package Teach compiled and signed from Grokit's contracts.
- [x] A real suite package and reference build to verify `Reach::Suite` end-to-end: done in 0.6.0 with Grokit 0.2.0's suite.
- [ ] `reach status` shows tips as "not run" or "last recorded" from the corpus's latest tip record; show each slice's own last tips result instead.
- [ ] Run `bundle lock` for real against `Gemfile` for both the Ruby 2.6 and modern lines, and diff against the hand-authored locks.
- [ ] A live Codex session with the plugin installed: confirm the hook-trust prompt, the SessionStart context and the greeting (installed in a scratch home only; no session run).
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

- [ ] rplugin links only `bin/<id>` onto the PATH and ignores `contents.scripts`, so since the move to `exe/reach` it links no executable (and `rplugin doctor` does not notice a dangling one). On the development machine `~/.local/bin/reach` now points at the `~/.reach/bin/reach` shim. rplugin should link `contents.scripts`.
- [ ] `rplugin install reach` links the reach-assistant skill and the reach agent into the user's own `~/.claude`, where the skill's "use at the start of every session" applies to every session; on a developer's machine, leave them unlinked.

## Course reference corpus

- [ ] `corpus/course-reference/` (BUS 101 and BUS 201) is a one-time hand-vetted copy from the instructor's AIvoryTower course stores, made 2026-09-28. It does not stay in sync with the instructor's evolving syllabus, glossary or assignments. Build a live-update mechanism (re-running the same vetted copy from AIvoryTower, or a future instructor-upload path) so this directory tracks the real course material instead of going stale. Deferred; not started.
- [ ] Whatever sync mechanism gets built must carry forward the same hard exclusion by hand: instructor-only material (answer keys, instructor keys, grading rubrics with solutions, or anything else marked as an instructor/answer-key artifact) must never land in `corpus/course-reference/`, no matter how the sync pulls its source.

## Housekeeping

- [ ] Decide the licence (currently `undecided` in `reach.spec.yml`) before any public release; `exe/reach` and `lib/reach.rb` already carry an MIT SPDX line from 0.1.0.
