# TODO

## Installation reports and check sessions (0.68.20, wire revision 2026-11-05a)

- [ ] Run the installer's first report, a detached drain, the background job, and a check session on a real macOS and a real Windows install, and on Ruby 2.6.10 with LibreSSL. Only Linux with Ruby 3.3 and 4.0 ran.
- [ ] See a check session once in a real harness, where the notice and the yes question are what the student reads. The prompts entered through the real hook, but no real app showed them.
- [ ] Windows without Ruby reports nothing until the PowerShell step has fetched Ruby.
- [ ] `reach live yes` at a terminal cannot always tell an agent from a person. Find a stronger sign that a person is there.
- [ ] The offer an older copy still needs stays until no copy older than 0.68.20 reports. Remove it then.

## Assignment-one smoke is stale (found 2026-10-18 running it for 0.53.22)

The same failures and skips occur on 0.53.21, so they predate partial work.

- [x] `tools/smoke/assignment_one.rb` expects a nonzero exit from the Claude Code login hook; the hook now blocks with exit 0, so the login, guarded-write, unqualified-submit and qualify-scenario steps fail.
- [x] Its grader image names no longer match the images the grader uses, so the grader never starts and every grading step skips.
- [x] `hook_prompt("Yes")` sends no `transcript_path`, and rEach accepts a hook yes only when the asked question is in the transcript's assistant text, so the full-submit yes can never be taken; the harness should write a transcript holding the pending question.
- [x] Qualification needs `bundle` on the PATH of the rEach commands it runs.
- [x] `ingest-receipt-ids` assumes one ingest receipt; a partial submission before the full one adds a second.

## Audit 2026-10-08 (0.46.0, main b1b85d5)

Five read-and-reproduce reviews (client, work, data, agent, install). Repros live outside the tree. Paths are under
`lib/reach/` unless named otherwise.

### Decisions (Sven, 2026-10-08)

- Shell gate fails closed: a command the gate cannot fully parse and classify is refused, not allowed.
- Consent accepts only an explicit yes (`yes`, `y`) and binds to the question that was actually shown.
- A live session's `diagnosis` approval counts only when the diagnosis consent is recorded on the student's machine.
- `codex_configure` from a live session uses the safe mode, never `full`.
- Ship: merge to main, hold the push and the release; then one smoke run against a scratch Teach ($5 cap).

### Status after 0.46.1

- 66 of 67 done; RAUD-09 first half open (below).
- Not run on a real Windows or macOS host: schtasks Task XML, launchctl, PowerShell unwrapping and cmdlet mapping, rename retry.

### Client: transport, identity, enrollment

- [ ] RAUD-09 (second half done in 0.46.1: an enrolled install fetches from its own teach_url; first half open, needs a pinned trust root because STD-INSTRUCTOR-UNLOCK documents the unsigned pre-enrollment fetch) `instructor_keyring.rb:467` an unenrolled install accepts an unsigned keyring (fetched or dropped in),
      so a self-made RINS1 code unlocks `EnrollmentLock`; an enrolled install fetches from the default URL.

## Compatibility matrix (0.42.0, wire revision 2026-10-07a)

- [ ] The tested matrix covers commands and hook command lines only; no leg runs a live Claude Code, Codex or
      Antigravity session, so a harness cell passing does not prove the harness works end to end.
- [ ] The harness's own version (Claude Code, Codex) is not reported; only its label is.
- [ ] Run the platforms workflow with the Windows 10 and 11 VM legs once, so the tested matrix covers them.

## Test lockdown on an invalid policy (0.68.2)

- [ ] During a real test an invalid policy still refuses every bridge tool, including `reach_support`
      (`Reach::Controls.tool_allowed?` answers false on `BehaviorPolicy::Invalid`).
- [ ] `GuidedLearner` reloads its policy through `Runtime.root` the same way, so a plugin folder an update replaced can
      hand it a newer policy (hooks only).

## Set up a domain (0.38.4)

- [ ] SET UP DOMAIN: serve Teach at a neutral public host name, a custom domain in front of the Tailscale Funnel,
      so the built-in course server address (`config.yml` `teach.url`, `Reach::Runtime::TEACH_URL`, the docs and
      the specs) no longer shows the maintainer's machine name and tailnet id. Switch rEach to it only with a
      transition that keeps installed students reaching Teach, and record the new address in the wire spec.

## Course content out of the repository (0.33.0, wire revision 2026-10-04j)

- [ ] Read the profile's `terms` and `slices`: the message catalogue still says slice, cutout, module and panel,
      and `directives.rb`, `hands.rb` and `policy.rb` still list `backend panel verification`.
- [ ] The skills, the agent file and `mcp_bridge.rb` still carry course teaching rules, private directive names and
      one learning system's name in places; they are to keep mechanics only.
- [ ] `check.rb`'s rule tables, the AGENTS.md wrapper text, and the `dovetail`, `qualify` and `ruby` directives are
      to arrive from the course server; the Dovetail submodule is to go.
- [ ] An instructor key trusted on first contact where none is pinned; the pinned key stays for existing installs.

## Announcements and course updates (0.30.0, wire revision 2026-10-04g)

- [ ] See an announcement arrive in a real harness session on macOS and Windows; only Linux with Ruby 4.0 ran,
      through the prompt hook from a terminal.
- [ ] The installation and setup guide (both copies) and the student guide do not mention announcements.
- [ ] Per-student and per-group due times: the status already carries one due time per install, so only the
      course server needs to change.
- [ ] Course facts still written into this repository (institution, time zone, LMS name, ladder limits, message
      wording) are to come from the course server instead; audited 2026-10-04, not yet moved.

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

## Enrollment v2 (0.16.0, branch `enrollment-v2`)

- [ ] Verify a real Codex session: the shared `hooks/hooks.json` passes `--harness claude-code` and
      `${CLAUDE_PLUGIN_ROOT}`; whether Codex's plugin hooks honor that and block a prompt is unproven.
- [ ] Field report 2026-10-02: on 0.16.x some students' Codex enrolls without trouble and some is stuck. The stuck
      ones keep being told to approve rEach's hooks (M-ENR-AGENT-GUIDE), but the plugin and its hooks already show as
      enabled in Codex's settings and neither the student nor the instructor found anything left to approve in the app. Likely
      openai/codex#47925 (Codex >= 0.156 loads no plugin hooks while the root `plugin.json` exists), whose cache repair
      shipped in 0.16.16 and was first tagged in v0.16.20; unconfirmed. Find each stuck student's Reach and Codex
      versions, and stop the agent guide from sending a student to approve hooks that are already enabled. (The guide half is fixed in 0.16.24; the version check still needs the students.)
- [ ] Verify a real Hermes session (enroll hook as context) and Antigravity (CLI only). Field report 2026-10-02:
      Hermes works for students; its enrollment is still untested.

## Verified in 0.10.0

- [ ] Run a live Codex session in a course folder and check its replies, reasoning summaries and apply_patch code reach Teach; the Codex path is verified only on a synthetic rollout file.
- [ ] Claude Code stores thinking as a signature with empty text, so its reasoning arrives as "reasoning not readable"; revisit if the harness starts storing readable thinking.

## Verified in 0.11.0

- [ ] The judge still notes rEach sometimes asks two things in one reply (course-gate) and does not use the first-run greeting right after a profile is forgotten (advisory only).
- [ ] The runtime bundles for macOS, Windows and Linux arm64 are built and relocation-checked only in CI; no student machine on those platforms has installed one yet.

## Verified in 0.11.1 to 0.11.3 (Hermes)

- [ ] An interactive Hermes session (first-use hook prompts, a student typing), and a Hermes provider connection instead of the shim.

## Release 0.7.0 open items

- [ ] The installer's Windows path is unverified.

## Before a class uses it

- [ ] A live Codex session on macOS with 0.16.16: confirm both rEach hooks appear under `/hooks` (or Settings > Hooks), trust them, and see the greeting. The scratch `hooks/list` check passed; drop the cache repair once openai/codex#47925 is fixed.
- [ ] Antigravity: `reach setup --harness antigravity`, `agy plugin install` and the plugin-directory link are untested.
- [ ] Confirm whether Claude applies the plugin's `settings.json` `"agent": "reach:reach"` for an installed plugin; a `--plugin-dir` session did not report it (the greeting works without it).
- [ ] Windows: hook-command quoting and the Antigravity copy fallback are untested.

## Known limits

- Desktop apps (Claude app, Codex app, Antigravity desktop) wait for the student to type first, so rEach introduces itself in its first reply rather than unprompted.
- Codex runs plugin and workspace hooks only after the student trusts them; until then enforcement is the read-only files plus the submit-time check.
- Codex's default sandbox may stop `reach profile save` writing to `~/.reach` until the student approves it. Since 0.15.0 Codex's plugin carries the MCP bridge (`mcp.json`, `${PLUGIN_ROOT}` expanded by Codex to its plugin cache).
- Antigravity has no documented hook format, so it gets no hooks.
- DeepSeek's harness is unsupported; the Gemini consumer app has no plugins.

## Home inside reach-work (branch in-workspace)

- [ ] Run the Windows sandbox probe: with the project opened at `~/reach-work`, measure that writes inside `.reach-home` succeed, whether the network opens, that the install and relocation run under Full access, and whether the top-level `.codex` is read-only. Nothing about the Windows sandbox is proven.
- [ ] Measure whether the Codex sandbox allows the network on macOS and Linux with an allow rule; until then enroll, sync, updates and the subscription check need Full access.
- [ ] `scripts/reach-install.ps1` is changed but was never run (no PowerShell here); run it on Windows.
- [ ] Verify the relocation on macOS (case-insensitive filesystem path handling in `Paths.realish` is untested there).
- [ ] No receipt was in the relocation fixture (no grader available); check that receipts and acks survive a relocation.
- [ ] `state/enroll/fingerprint_cache.json` keeps the legacy path inside its key after a relocation; it is recomputed and harmless, but is reported in `legacy_path_hits`.
