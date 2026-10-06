# Alignment design decisions

This file records the design decisions behind rEach's alignment work, each with the alternatives that were on the table, what a student or instructor feels as a result, which standing priority decided it, what is given up, and the toggle that carries it. It is written as the decisions are taken, 2026-10-06 onward, and only the latest form of each decision is kept. The standing product decisions live in `docs/DESIGN-DECISIONS.md`; the system as built is drawn in `docs/architecture.md`. The course server is described here by what it does, never by how it is built.

## How decisions are made

Priorities, in order: **security, then consistency and resilience, then performance, then durability.** A real difference on a higher axis decides outright; a lower axis is consulted only when the higher ones tie, and "they tie" has to be defended. Extensibility is not on the list. User experience is weighed on every decision and recorded, but it does not outrank an axis above it; when experience loses, the entry says exactly what the student or instructor gives up.

Toggles: every behavior has one of three homes. **Build** means fixed in the released code. **Config** means a value the course server sets and signs, delivered with the course policy. **Runtime** means an instructor action during the course (a control, a kill switch). A hybrid of these is the default answer; a pure choice is an exception and is marked as one. Nothing a student can edit may lift a rule (D13 below settles what the student may configure).

Research: 58 papers inform these decisions; the paper ids below are arXiv identifiers.

## D1. The work lands in place, behind toggles

**Decision.** New core modules (policy engine, provenance envelope, gate, decision log) are added to rEach and the course server under build and config toggles. The existing paths stay until the new ones reach parity, then are removed. The wire protocol is extended, never broken, and students keep updating through the `stable` branch.

**Alternatives.** A new major line with a second wire protocol served beside the first; a new repository with the current rEach frozen for the term.

**What people feel.** Nothing, until a toggle flips; a class never carries two protocols.

**Priority.** Consistency and resilience: one live class, one protocol, no migration day.

**Given up.** Two paths coexist until the new one reaches parity.

**Toggle.** Build (per module), then config to activate.

## D2. Typed items bind; prose is guidance

**Decision.** Only typed items change what the gate allows: controls (pause, hold, test), policy flags, and instructor rules that carry a kind from a small vocabulary (permit, obligation, prohibition) with a check the code can run. Prose rules keep the rule frame and their place in the order of authority, but no sentence can grant or remove a capability.

**Alternatives.** Prose rules that bind by model obedience; typed items only with no prose tier at all.

**What people feel.** An instructor who needs something enforced picks a kind; an instructor who wants tone or coaching writes prose as before. A student is never blocked by a sentence, only by a typed rule they can be shown.

**Priority.** Security. Prompt-stated policies are followed in about half of repeated trials (CAR-bench Pass^3 about 54%, 2601.22027); a constitution in the prompt gave no measurable gain (2601.11369); typed controls enforced in code held at 0% attack success (2601.11893).

**Given up.** No binding rule can be invented mid-sentence.

**Toggle.** Build for the vocabulary; config for which kinds a course uses.

## D3. The course server classifies; rEach's channel map is the floor

**Decision.** Every item the course server sends carries a signed envelope: class, tier, issuer, issued time, expiry, policy version. rEach frames by the envelope. Items with no envelope (local memory, imports, known issues, due changes computed locally) use the tier fixed per channel in code. When an envelope claims a tier above the channel's ceiling, the lower wins: authority only narrows.

**Alternatives.** Channel map only; the envelope as the only authority with no ceiling.

**What people feel.** Nothing visible; the frames are the same text. An instructor can lower one item (an announcement sent as a plain notice) but can never raise one above what the channel allows.

**Priority.** Security. Warrant must come from the content's class and provenance, never the channel that carried it (2601.08333, 2602.05877, 2601.17549); a server bug or a compromised instructor account cannot promote a notice to a control.

**Given up.** An envelope on every route the course server serves.

**Scope of the first pass (2026-10-06).** In the code and on the wire the envelope is called a provenance record, because envelope already names the sealed package format in both programs. The first pass signs the items rEach frames: each control, the current test, each announcement and each private directive body. The status body, the known-issues list and the instructor keyring stay unsigned until the release manifest (Phase 4), because status carries the signing keys themselves and signing it needs the key-rotation chain designed first; until then those three travel over TLS. Controls and tests require a verified record from the first release; information does not, so a server that sends no records still delivers announcements.

**Toggle.** Build for the envelope shape; config for the ceilings and for which classes require a record (control and test by default).

## D4. A 2.6 shim over a Ruby 4 core

**Decision.** One tiny hook entry point stays compatible with Ruby 2.6.10 (the macOS system Ruby) and does one thing: block course work until the portable Ruby 4 kit is present, then delegate to it. The policy engine, gate and bridge are written for Ruby 4 only.

**Alternatives.** Everything stays 2.6-compatible; the kit required everywhere with no shim.

**What people feel.** Nothing new; the first-run path is unchanged.

**Priority.** Consistency: the gate exists from the first prompt on every platform. Then performance and durability of the code itself.

**Given up.** One file keeps the old syntax forever.

**Toggle.** Build.

## D5. Default-deny for state-changing tools in course spaces

This decision and D6 were asked for in depth.

**Why.** A gate that matches tool names covers the tools it lists. A host's subagent tool, tools from other MCP servers the student has installed and tools a host adds in a future release need coverage that does not depend on a list being current, above all during a test. The research is unambiguous on the direction: a gate that allows on no match leaves every unlabeled path open (2601.11893 reaches 0% attack success only "with proper labels" and itself defaults to allow); read-only tools can be exposed freely while state-changing tools need an explicit grant (2601.12449 cut attack success from 24.3% to 2.3% this way); the coding-assistant SoK (2601.17548) proposes silent for read-only in scope, logged for project writes, and constrained shell, network and credentials.

**Decision.** In a course space (a slice or the workspace root) the policy lists tools by class. Read-only tools pass silently. State-changing tools (file writes, shell, network, spawning a subagent, every tool of another MCP server) need an allow entry in the policy or are refused with a reason that names the rule and says what the student can do instead. The extracurricular folder keeps default-allow with the existing path rules. A new host tool needs one policy line from the course server, delivered as config, not a release.

**Alternatives considered.** Default-allow with deny rules: no new friction, and nothing unlisted is covered. Default-deny everywhere including extracurricular: one rule set, but it breaks the standing promise that the student's own practice folder is theirs to use freely (`docs/DESIGN-DECISIONS.md`).

**What the student feels.** In a slice, the first time an unlisted tool is used, a refusal that reads like every other rEach refusal: what was refused, which rule, and that the instructor can allow it. Reads, searches and the ordinary edit and run tools are unaffected because they are listed. In extracurricular nothing changes. During a test the lockdown covers every tool, listed or not.

**What the instructor feels.** A short allow list to keep, shown on the course server with the tools students have actually tried (the logged tier of D7 supplies the names). Allowing a tool is a config change that reaches students at the next sync.

**Priority.** Security decides. Consistency is also served: the same answer on every host and for every tool, listed or not. Performance is unaffected (the check is a table lookup). User experience loses in one place: the first week of a term will surface tools nobody listed, and each one costs a student a refusal and an instructor an allow entry.

**Given up.** The convenience of a tool working before anyone thought about it.

**Failure cases this covers.** A test taken with a second MCP server that can write files; a subagent that inherits none of the frames; a host update that renames a tool out of the matcher list.

**Failure cases this does not cover.** A host that has no hooks at all (D16); a student who edits local state (D14); anything the host does not route through a hook.

**Toggle.** Config: the allow list per space kind, owned by the course server. The class of each known tool is build. There is no student-side toggle.

**Evidence.** 2601.11893, 2601.12449, 2601.17548, 2604.14228 (a hook allow cannot override a host deny; only hooks and deny rules are deterministic).

## D6. Fail-closed inside a known window, fail-open outside it

This decision was asked for in depth.

**Why.** A control has to hold through failure: a hook error, a server restart or a kill switch must not end a pause or a test early. The research favors failing closed: a deterministic authorization boundary that treats any timeout or error as deny (2601.17744, 200 of 200 fail-closed in its harness) and delegation grants that fail on anything stale or unresolvable (2601.14982). The cost it names is liveness: an offline student stops working.

**Decision.** Controls are signed by the course server with a window (start, end) and a policy version, and rEach caches them. While a cached control's window is active, any failure (server unreachable, hook crash, state file unreadable, a 503) refuses state-changing actions with a reason that says a control is in force and until when; a 503 or a network error never clears a control before its expiry. Outside any known window, failures let work continue, are written to the decision log, and are shown by doctor. A grace period after expiry, during which a control is still honored while the server cannot be reached, is a config value with a default of a few minutes. A student is therefore only ever blocked by a control that was already in force when the failure happened.

**Alternatives considered.** Fail-closed always: rules never lapse, and a server restart or a flaky network stops the whole class, which at classroom scale means the instructor's own machine becomes a single point of failure for every student's work. Fail-open always: zero liveness cost and no guarantee, including during a test.

**What the student feels.** Nothing new in ordinary work; a network drop outside a control window changes nothing. Inside a pause or a test window, a failure produces the same refusal as the control itself, with the end time, instead of silently lifting it. A student whose test window has ended and whose machine cannot reach the server keeps the lockdown only for the grace period.

**What the instructor feels.** A kill switch on the controls route stops new controls from being issued; it does not end a control already running on students' machines until its window ends. To end one early the instructor cancels it, which students pick up at the next sync. The decision log shows every failure that was let through outside a window.

**Priority.** Security decides inside a window: a control that lapses on error is not a control. Consistency and resilience decide outside a window: the class keeps working through outages. User experience is preserved everywhere except where a security property would otherwise be lost.

**Given up.** The ability to end a control from the server instantly during an outage; a student who is offline when a window ends waits out the grace period.

**Failure cases this covers.** Server restart during a test; a kill switch flipped during a pause; a crashed hook during a lockdown; a deleted or unreadable controls file during a window (treated as a failure inside the window if the window is known from any other cached record, otherwise as outside).

**Failure cases this does not cover.** A control the student's machine never received because it was offline when it was issued; local tampering with the cached signed state (D14).

**Toggle.** Config: grace seconds, owned by the course server. The windowed behavior itself is build.

**Evidence.** 2601.17744, 2601.14982, 2601.15630 (mandatory expiry, kill switches).

## D7. Three tiers: silent, logged, blocked; deferral goes to the instructor

**Decision.** No tier asks the student. Read-only actions in scope pass silently; project writes and other allowed state changes pass and are logged; everything else is blocked with the rule id. A blocked action an instructor could legitimately allow carries the hint that the instructor can issue a control or a permit through the course server; the existing hand mechanism carries the request.

**Alternatives.** A confirmed tier for shell and network using the host's "ask" where it exists; silent and blocked only.

**What people feel.** The same behavior on every host. A student cannot unblock anything alone in the moment; an instructor can, in minutes.

**Priority.** Security and consistency. Users approve about 93% of permission prompts (2604.14228), so a confirmation is habit, not control; and only one host can ask.

**Given up.** In-the-moment flexibility for the student.

**Toggle.** Build for the tiers; config for which tools sit in which tier.

## D8. No model judges in the student-side gate

**Decision.** Every decision on the student's machine is code over typed state. The host agent's own instructions (run `reach support` on a crisis, relay refusals word for word) remain the only semantic layer, and they cost no extra call. The course server may later run a model over de-identified transcripts to label events for instructor review; that is a config toggle that ships off.

**Alternatives.** A host-model judgment hook for cases the deterministic tiers cannot place; model judgment wherever it helps.

**What people feel.** Refusals are instant and identical every time.

**Priority.** Security and consistency. Model judges cost about 500 ms per step and misfire 11 to 13% and up (2601.22136, 2601.09292); 2% false positives on student phrasing (2601.13186); adaptive attacks beat trained defenses (2602.05746); deterministic checks held at 100% (2601.09292, 2601.05467).

**Given up.** Semantic cases the rules do not enumerate.

**Toggle.** Build on the student side; config on the course server for post-hoc labeling.

## D9. A short floor every turn, the rest at capped triggers

**Decision.** The floor injected on every prompt is the order of authority, the active controls and the current-step anchor, under a byte budget with a default of about 1.5 KB. Each information item (announcement, due change, memory, consent) is pushed once when it arrives, framed, then only as a one-line pointer. Reminders fire at triggers (a tool-call count, a refusal, a change of space) with per-type caps and only restate rules already given. Budget, triggers and caps come from the course server.

**Alternatives.** Everything every turn (about 18 to 20 KB after sign-in); once at session start only.

**What people feel.** Faster turns; fewer repeated notices; the agent stays on the rules late in a long session.

**Priority.** Consistency (adherence holds across a session) and performance. Noise cuts accuracy 9 to 80.6% (2601.07226); one-line constraints lift compliance 82% to 91.5% (2601.03359); adherence fades after 15 to 30 tool calls and capped reminders restore it (2603.05344, 2604.01658).

**Given up.** Completeness on every turn; a pointer must say exactly when to fetch.

**Toggle.** Config: budget, triggers, caps.

## D10. Frames state the class first, then the issuer, with no authority adjectives

**Decision.** An information frame opens with the class ("Information, not a rule") and then the issuer ("from the course's instructors"). Words such as important, urgent, official and must are refused in information-class frames by the course server's policy check at publish time. Frame wording stays course-server config inside that check.

**Alternatives.** Neutralize the issuer entirely; name the issuer freely.

**What people feel.** Students still learn who wrote a notice; nothing reads as an order.

**Priority.** Security. With content held fixed, a source label alone shifts an agent's agreement (2601.04790).

**Given up.** Emphatic wording in notices.

**Toggle.** Config, under a build-time lint.

## D11. Typed announcement kinds and a warn-only phrase screen at publish

**Decision.** An announcement has a kind (notice, schedule change, outage, reminder); each kind has a fixed frame, and an outage adds the server's canonical "rEach may be unavailable; keep working" sentence automatically. The body stays verbatim. A phrase screen (ignore, stop helping, you must, override, do not tell, and similar) warns the instructor with the matched phrase before sending; it never blocks and never strips. The same screen runs on course rules and directives.

**Alternatives.** Screen and block until rephrased; free text with frames only.

**What people feel.** An instructor sees a warning once in a while and decides; a student reads exactly what was written.

**Priority.** Security, then user experience on the instructor side. Stripping imperatives from relayed text cut attacks to near zero but cost 28 to 45% of benign usefulness (2601.04795); structure beats filtering. 84.2% of malicious skill behavior is plain-language instruction (2602.06547); static scans reach 91.2% recall with noisy flags (2601.10338), which is why the screen warns and never decides.

**Given up.** Nothing is ever refused at publish, so a coercive notice can still ship if the instructor overrides the warning.

**Toggle.** Config: screen on, warn or off; the kinds are build.

## D12. Rules files are budget-bounded; overflow goes to retrieval

**Decision.** The generated AGENTS.md, CLAUDE.md and GEMINI.md hold the floor, the typed rules and one-line pointers; directive bodies and course reference come through `reach directive` and the MCP bridge, which exist. The budget is course-server config; a freshness digest in each file lets doctor flag a stale workspace.

**Alternatives.** Full rules files; pointer-only files.

**What people feel.** Shorter session starts; the agent fetches a directive when a pointer says to.

**Priority.** Consistency (a stale file is detected) and performance. A short always-loaded set with bulky material on demand works, but agents trust documentation absolutely, so staleness must be caught (2602.20478).

**Given up.** On a host without the MCP bridge, pointers are all the agent gets beyond the floor.

**Toggle.** Config: budget.

## D13. Build ships, server config binds, runtime controls act; student config is convenience only

**Decision.** Feature flags are build-time and disappear at parity. Anything that binds (tool allow lists, budgets, grace seconds, publish screens, tier tables) is course-server config, signed inside the policy. Runtime is the instructor's controls and kill switches. The student's `config.yml` may hold conveniences only (display, paths, update cadence); no key in it is read by the gate, and an unreadable config falls to the signed defaults, which enforce.

**Alternatives.** The same, plus one documented student-side key that disables enforcement for support cases; or a student config with binding keys.

**What people feel.** A student loses nothing they were meant to have; support cases go through the instructor, who can pause enforcement for one install from the course server.

**Priority.** Security: a rule a student can switch off locally is not a rule. Consistency: one place to read what binds.

**Given up.** A local escape hatch during a hook misbehavior; the recovery is the server-side per-install pause and `reach doctor`.

**Toggle.** Build.

## D14. Every control is signed; local state is sealed; tampering refuses and reports

**Decision.** The course server signs every control and envelope with the key already pinned at enrollment. rEach seals its own state files (`controls.json`, `exam.json`, `install.yml`) with an install-derived MAC. A missing or altered file inside a known control window is a failure under D6: state-changing actions are refused with the reason, and an integrity event goes to the course server. Outside a window it is logged. The server-side checks (deadline, answer provenance, submission acceptance) stay the real guarantee.

**Alternatives.** Sign controls only, with no local sealing; server-side checks only.

**What people feel.** Honest students feel nothing. A student who edits or deletes a state file during a pause or test gets a refusal that says why, and the instructor sees an integrity event with the install id, not the file contents.

**Priority.** Security. Deterministic signature checks caught 100% of forged calls (2601.09292); scope, expiry and revocation freshness fail closed (2601.14982). The student owns the machine, so this stops casual edits and makes deliberate ones visible; it claims nothing more, and the server-side checks carry the integrity of grades.

**Given up.** A claim of more than tamper evidence on a machine the student owns; the server-side record is what counts.

**Toggle.** Build for signing and sealing; config for whether integrity events leave the machine (default on).

## D15. The updater verifies releases against a server-published manifest

**Decision.** The course server lists the releases it accepts (version, archive digest, minimum version) in signed status. The updater refuses an archive whose digest is not listed and `reach doctor` says why. When the server is unreachable the last signed manifest is used; with none, no update happens.

**Alternatives.** Detached signatures on each release asset with a key shipped in the plugin (independent of any server; rotation needs a release the old key still signs); both layers; the `stable` branch alone.

**What people feel.** Updates behave as before; a release the course has not accepted does not install, and doctor names it. A student on another course's server is governed by that server's list.

**Priority.** Security, then consistency: the class runs the release the course accepted. The plugin's own files are the attack surface; hook and permission-flag abuse appeared in the wild across 98,380 skills (2602.06547), and two host CVEs ran hooks before the trust dialog (2604.14228).

**Given up.** A release is not installable until the course server lists it, so a hotfix reaches students one publish step later than a push to `stable`.

**Toggle.** Build for verification; config for the manifest. Runtime: pulling a release from the list stops its installation at the next sync.

## D16. Hookless hosts may do course work, marked; they may not take tests

**Decision.** An install on a host without hooks (such as Antigravity, or any future host without them) receives the floor and pointers as context, its submissions and progress are marked unhooked so the instructor sees it, and the course server refuses to open a test for it because a lockdown cannot be enforced there. The student is told which hosts can take tests. Nothing pretends to be enforced.

**Alternatives.** Refuse all course work on hookless hosts (a student whose only host is hookless is locked out); allow everything including tests with server-side checks only (no lockdown at all).

**What people feel.** A student on a hookless host works normally and sees the mark on their own progress page; at test time they switch to a hooked host or ask the instructor. Instructors see which submissions came from unhooked installs.

**Priority.** Security for tests (no lockdown, no test), then user experience for ordinary work, which the server-side checks already protect. The context file is the only mechanism on every host; hooks exist on a subset (2602.14690); a prompt-only rule is advisory (2604.14228).

**Given up.** A hookless host cannot be used for tests, and the unhooked mark follows that student's work.

**Toggle.** Build for the capability matrix; config for which activities a hookless host may do (default: everything but tests).

## D17. Refusals and integrity events leave the machine; the rest stays local; counts travel in the heartbeat

**Decision.** Every gate decision is appended locally as one structured line: time, tool class, space kind, tier, rule id, policy version; never prompt text or file contents. Refusals and integrity events are sent to the course server as they happen. Silent and logged tiers stay on the machine; only per-tier counts travel with the heartbeat. No hash chain in the first pass.

**Alternatives.** Stream every decision to the server (a per-tool record of a student's whole session on the server); counts only (an instructor cannot see which rule refused a student or whether local state was tampered with).

**What people feel.** Instructors see what was blocked, why and under which policy version; students keep what they did. A student can read their own full log.

**Priority.** Security (refusals and integrity events are what an instructor acts on) and consistency (every decision carries its policy version, 2601.15630). User experience on the student side is protected: the content of their work never leaves. 40% of 70 surveyed harnesses keep no audit and 5% are tamper-evident (2604.18071); this is structured, not tamper-evident, and says so.

**Given up.** Tamper evidence for the local log of silent and logged decisions, which the server never needed.

**Toggle.** Config: which tiers leave the machine (default: blocked and integrity), owned by the course server.

## D18. Students see everything that binds them

**Decision.** `reach policy` lists every binding rule and active control with its source, kind and expiry. Every refusal names the rule id and the retry path. `reach why` replays the last gate decision from the local log. Students can argue with a rule; they cannot change one.

**Alternatives.** Rule id on refusals only (no view, no replay); opaque refusals (text only).

**What people feel.** A refused student knows exactly which rule and what to do next; support questions start with a rule id. An instructor is asked about rules, not about mysteries.

**Priority.** Consistency and resilience (the same rule reads the same everywhere and support is reproducible). Security is unaffected because the gate is deterministic: knowing a rule does not help bypass it, and the server-side checks are the guarantee either way. Reject-with-reason produced 100% legal actions (2603.03329) and 90.2% of blocked code was repaired within two retries (STELP).

**Given up.** Nothing a deterministic gate needed to hide.

**Toggle.** Build.

## D19. A deterministic replay suite gates every policy publish; real-model runs are a recipe

**Decision.** Recorded hook inputs (an announcement worded like an order, a pause, a lockdown, a tamper, a hookless install, each default-deny case) are replayed through the gate with no model, and the course server's policy check runs them before a policy publishes. Pass^k against a real host model is a documented recipe the instructor runs when they choose.

**Alternatives.** The replay suite plus a real-model Pass^k run on every release (catches obedience regressions the gate cannot see; spends tokens every release and the number moves with the model); manual scenarios only.

**What people feel.** A policy that would let such an announcement act as a control cannot be published; the instructor sees which scenario failed. Students never see the suite.

**Priority.** Consistency and resilience: the gate's behavior is fixed by replay, not by recollection. Performance: no model call in the release path. The papers measure with Pass^k against real models (2601.22027, 2601.22136); the gate is deterministic, so the replay is exact and the model run measures the host model, not rEach.

**Given up.** Automatic detection of a host model that stops honoring the frames; that is caught only when the recipe is run.

**Toggle.** Build for the suite; config for which scenarios a course adds.

## D20. The policy file is the source; the console previews, lints and shows drift; publish is a command

**Decision.** Policy stays a versioned YAML file in the course server's repository; its digest is the policy version. The console renders the effective policy, the lint and phrase-screen results, and which installs still hold an older version. Publishing is one command that signs and serves it. There is no console editor, so every change has a commit.

**Alternatives.** A console editor with versioned saves (friendlier for an instructor without git; two surfaces could disagree unless the file is retired); file only with no console view.

**What people feel.** An instructor sees exactly what students hold and what differs; a change is a commit and a publish.

**Priority.** Consistency (one source, one version, visible drift) over instructor convenience. A hashed, versioned manifest with a log of changes (2601.08012, position paper).

**Given up.** Editing policy from a phone during class; controls and announcements remain the runtime surface for that.

**Toggle.** Build.

## D21. Host-native deny rules are offered with consent, per host, for course spaces only

**Decision.** `reach configure` offers to write deny rules for the course workspace into the host's project-level settings (never user-level), lists exactly what it will write, and records the consent. The rules cover tests even when a hook crashes. Doctor shows whether the layer is present. A student may decline; the install is then marked single-layer, and tests still open because the hook layer enforces.

**Alternatives.** Write the rules during enrollment without a separate yes (two layers everywhere; a student who later finds them may distrust the plugin); hooks only (a hook failure during a test leaves D6 as the only backstop).

**What people feel.** One more question at configure time, with the exact lines shown. Students who say yes gain a layer that holds even if rEach is broken; students who say no lose nothing they had.

**Priority.** Security through an independent layer (a host deny cannot be overridden by a hook allow, 2604.14228; two independent layers, 2601.17548), bounded by user experience: the student's host settings are theirs, so consent is asked and recorded.

**Given up.** Universal two-layer coverage; the single-layer mark tells the instructor where it is missing.

**Toggle.** Config: offered or not, per host; the student's consent is runtime and revocable through `reach configure`.

## D22. Subagents are allowed in course spaces, gated identically, and refused during lockdown

**Decision.** Spawning a subagent is a state-changing action under D5 and needs an allow entry. When allowed, the subagent's tool calls pass through the same hooks, inherit the parent's space and policy, and receive the floor in their context. During a test lockdown, spawning is refused. On a host that cannot hook a subagent's calls, spawning is refused in course spaces.

**Alternatives.** Refused in course spaces altogether (a student loses parallel help on course work); allowed and ungated (a gap in every control).

**What people feel.** Course work can fan out as before where the instructor allows it; during a test it cannot. A refused spawn names the rule.

**Priority.** Security (scope never widens along a chain, 2601.14982; subagents need their own hooks and allow lists, 2604.14228), then user experience for ordinary work.

**Given up.** Subagents on hosts that cannot hook them.

**Toggle.** Config: allow entry per space kind, owned by the course server.

## D23. Information items are pulled on a cadence, injected once at arrival, then pointed to

**Decision.** rEach keeps polling the course server; no inbound connection reaches a student machine. The first prompt after an item arrives carries it framed once; afterwards a one-line pointer stands in and `reach announcements` serves it on demand. Controls use the same poll with a shorter cadence inside a test window; both cadences are course-server config.

**Alternatives.** Repeat the full item every turn until the student marks it read (nothing missed; bytes on every turn and an agent trained to skim repeats); pointer only (an announcement a student needs now may not be read).

**What people feel.** A notice shows up once, in full, and stays reachable; the agent is not nagged. During a test, a control reaches the machine within the short cadence.

**Priority.** Consistency (every student sees each item once, framed the same way) and performance (D9's budget holds). Nothing about delivery changes authority (2601.08333).

**Given up.** Sub-cadence latency for a control; the test-window cadence is the knob.

**Toggle.** Config: both cadences.

## D24. Definition of done for the first pass

**Decision.** The first pass counts as shipped when these four scenarios pass live on a real host, with a live course server and an enrolled install:

1. Announcement replay: a notice worded as an order ("no rEach for today until end of class") arrives framed as information, the agent keeps helping, and the decision log shows no control.
2. Pause and lockdown through an outage: an instructor pauses, the course server is stopped mid-window, the pause holds with its end time, a write is refused with the rule id, and work resumes when the window ends.
3. Tamper detected: a student edits `exam.json` during a test; the next write is refused and the console shows the integrity event.
4. Hookless and default-deny: an Antigravity install shows unhooked and cannot open a test; on a hooked host an unlisted MCP write tool is refused in a slice and allowed after one policy line.

The replay suite of D19 holds the same four as fixtures; the live run is what counts.

**Given up.** Anything beyond these four is a later pass: post-hoc labeling, a hash-chained log, signed release assets, a console editor.

**Toggle.** None; this is the acceptance bar.
