Assignment one smoke: transport run and Codex dialogue runbook
==============================================================

This page covers two separate passes. Keep their evidence separate.

| Pass | What it proves | Who runs it | Evidence |
| --- | --- | --- | --- |
| Transport smoke | install, handshake, local gates, ingest, remote grade, all deterministic, no model | `ruby tools/smoke/assignment_one.rb` | `summary.json` and `summary.md` in the run directory |
| Codex dialogue | a real student conversation from the public link through the returned results | a person, following the runbook below | the rubric table filled in, plus the saved Codex transcript |

The transport smoke does not invoke any language model. It says nothing about how a
model behaves in the conversation, and the dialogue pass says nothing about whether
the wire works.

Local archive mode does not prove public availability. The transport smoke builds a
GitHub-shaped ZIP from the working tree and installs it with `bin/reach-install
--archive`. Only the dialogue pass, run after the parent has published the repository,
proves that `https://github.com/SteveBenner/rEach` serves a ZIP an unauthenticated
student can install. `--public` makes the transport smoke additionally run the real
public download.

Part 1: transport smoke
-----------------------

Run from the repository root:

```sh
ruby tools/smoke/assignment_one.rb
ruby tools/smoke/assignment_one.rb --run-dir /tmp/a1-run --teach-dir /tmp/teach-a1
ruby tools/smoke/assignment_one.rb --public
```

Environment overrides: `SMOKE_TEACH_DIR` (default `/tmp/teach-a1`), `SMOKE_GROKIT_ROOT`
(default `~/src/grokit`), `SMOKE_DOVETAIL_ROOT`
(default `~/src/dovetail`), `SMOKE_RUBY4_BIN` (default
`~/.rubies/ruby-4.0.6/bin`), `SMOKE_TEACH_BUNDLE` (default
`~/src/teach/vendor/bundle`, the gem path for a Teach checkout with no
gems of its own), `SMOKE_RUN_DIR`, `SMOKE_GRADER_TIMEOUT` (seconds, default 900).

Isolation: every run gets its own `REACH_HOME`, `REACH_WORKSPACE_ROOT`, `<Teach setting>`,
`CODEX_HOME` and a student `HOME` under the run directory (default
`~/.cache/reach-smoke/a1/<timestamp>/`). The runner refuses a run directory inside the
real `~/.reach` or `<Teach home>`. Teach runs as the real Ruby 4.0.6 process on a free
loopback port and is stopped by its recorded PID.

The enrollment code is written only to `private/codes.json` (mode 0600) in the run
directory and is scrubbed from every summary and log the runner writes.

Steps, in order, grouped by evidence class:

| Group | Step | Passes when |
| --- | --- | --- |
| install | dovetail-revision-pin | `dovetail-revision.txt` equals the gitlink from `git ls-files -s dovetail` |
| reference | reference-pack | Teach's `reference pack` builds an encrypted blob from a scratch source into the run's reference directory; the smoke packs before release so the key exists when the guardrails package is built |
| reference | reference-locked-before-enroll | before enrollment `reach reference list` exits nonzero with the connect-to-course hint and lists no path |
| reference | reference-after-sync | after sync `reach reference` lists, shows, searches and links the packed files, and no plaintext sentinel is on the student's disk |
| reference | reference-tamper-refused | a blob with one flipped byte is refused with a refusal message and prints no plaintext |
| install | prerequisites | Ruby 4.0.6, Teach gems, Grokit, Dovetail, `zip` and `unzip` found |
| handshake | teach-course-provision | roster, course and the G1 backend slice assignment exist |
| handshake | release-before-enroll | `<Teach command>` succeeds with zero installs |
| install | install-local-archive | a GitHub-shaped ZIP (symlinks kept) installs with `bin/reach-install --archive` |
| install | install-local-archive-dereferenced | fallback, only when the faithful ZIP is refused; a workaround, not a pass for the public path |
| handshake | blocked-before-enroll | `reach gate session` exits 2 and `reach work` refuses before enrollment |
| install | setup-codex | `reach setup --harness codex` succeeds with an isolated `CODEX_HOME`; skipped without `codex` |
| install | doctor | recorded; a pre-enrollment doctor is expected to report problems |
| handshake | enroll-handshake | enrollment succeeds and Teach lists exactly one install |
| handshake | enroll-code-reuse-rejected | the same code from a second `REACH_HOME` is refused and no second install exists |
| handshake | sync-delivers-workspace | workspace has `README.md`, `acceptance_mode` remote and the scenario names |
| local | guarded-write-owned, edit-outside-owned-blocked | the gate allows the owned file and exits 2 for any other |
| local | plan-save, implementation-written, readme-filled | plan reads back; the implementation is derived from the released contract; README carries the student text |
| local | reach-check, checkpoint, submit-refused-unqualified | check is clean; a checkpoint exists; submit is refused before any qualification and Teach holds nothing |
| local | qualify-scenarios-written, qualify-list | the gate allows the agent's scenario files under qualify/; `reach qualify --list` prints the @backend tag and the graded names |
| remote | grader-started, qualify-passes | Teach's `grader` process runs (both Docker images present, otherwise every later step is an explicit skip); `reach qualify` passes locally and on Teach |
| ingest | submit-and-ingest-receipt, ingest-receipt-ids | Teach issued one signed ingest receipt and Reach stored the same id |
| remote | grader | Teach's `grader` process, with both Docker images present, issues a grade receipt; otherwise an explicit skip, never a pass |
| remote | sync-grade-receipt | `reach sync` verifies and stores the same grade receipt id |
| codex, lan | codex-conversation, lan-second-device | always skipped here; use Part 2 |

`summary.json` carries each step with `status` (pass, fail, skip), `command`, output
tail, `expected` and `actual`, and a `receipts` object with the Teach-issued
(`expected`) and Reach-stored (`actual`) ingest and grade receipt ids. Exit status is 1
when any step failed, 0 otherwise.

Part 2: manual Codex dialogue
-----------------------------

Instructor preparation, on the instructor machine, from the Teach checkout with Ruby
4.0.x and the Teach gems. Use a scratch `<Teach setting>`, never the live course.

```sh
export <Teach setting>=/tmp/a1-dialogue/teach_home
export <Teach setting>=~/src/grokit/specs/app.yml
export <Teach setting>=~/src/grokit
export <Teach setting>=~/src/dovetail/exe/dovetail
export <Teach setting>=<Teach program>
export <Teach setting>=7400
export <Teach setting>=0.0.0.0
<Teach command>
<Teach command>
<Teach command>
<Teach command>
<Teach command>
<Teach command>
<Teach command>
<Teach command>
```

`roster.csv` has `id,display_name,email,group` with one synthetic student in group G1.
`slices.csv` has `student_id,cutout_id,slice` with that student on `context.a1,backend`.
Run `<Teach command>` and `<Teach command>` in separate terminals. Release comes before
enrollment codes. Both Docker images `teach-grader:ruby-4.0` and `teach-grader:ruby-2.6.10`
must exist or no grade will ever come back.

`<Teach setting>=0.0.0.0` exposes Teach to the whole network; use it only on a trusted
network, for the duration of the test. The teacher URL is `http://<instructor LAN
address>:7400`. Find the address with `ip -4 addr` or `ipconfig getifaddr en0` and
give it to the student explicitly; nothing scans the network and students never assume
localhost.

Give the student the URL and the code together, outside the chat with Codex is fine:

> Course server: `http://192.168.1.20:7400`, your code: `<code from codes.csv>`.

Student session, in a fresh Codex session on a machine with no rEach installed. Use
a scratch account or an empty `CODEX_HOME` if it is the same machine. The first
message is exactly:

> install https://github.com/SteveBenner/rEach

Expected turns, with the evidence to capture at each:

| Turn | Student says | Expected agent behaviour | Evidence |
| --- | --- | --- | --- |
| 1 | the install prompt above | fetches the public ZIP without asking for GitHub credentials, checks Ruby, backs up any existing `~/.reach/plugin`, runs `reach-install`, then `reach setup --harness codex`; prints the greeting only after setup succeeded | transcript, `~/.reach/plugin` exists, no `git clone` |
| 2 | "yes, go ahead" to each confirmation | tells the student in one sentence what changes before each step; asks the student to trust the start-up hook | transcript |
| 3 | "How do I connect to my course?" then the code | runs `reach enroll <code>` (the course server comes from `config.yml`), reports ready only after Teach answered | `reach status` shows enrolled |
| 4 | "What is my first task?" | runs `reach sync`, opens the G1 context A1 backend workspace, reads the README and the scenario names, explains the task in plain words | workspace path, README present |
| 5 | the business choices below | saves a plan with `reach plan save` before any edit; asks the student the meaningful decisions | `reach plan show` |
| 6 | "Please build it." | writes the owned file itself; the student does not type code; edits stay in the owned files | owned file, `reach check` clean |
| 7 | "Fill in the README with what we decided." | drafts the README sections from the student's own answers; does not invent a personal reflection or contributions | README |
| 8 | "Save a checkpoint, then submit." | writes its own scenarios, passes `reach qualify`, checkpoints, then `reach submit`, then reports the receipt id and time; never shows the student scenarios or output | ingest receipt id, `.reach/qualification.json` |
| 9 | "Did it pass?" | says it passed its own checks and the course server's before submitting, and that the grade is pending until Teach grades; never claims a grade | transcript |
| 10 | "Check again." | after the instructor's grader runs, `reach sync` shows the grade receipt; on any failure the agent follows the bug flow, qualifies again and resubmits with the student's yes | grade receipt id |

Synthetic student answers and business choices, to be read out or pasted one at a
time:

- Student name: Dana Ruiz, first-year business student, no programming background.
- Business: a small cafe. The decision the manager makes: whether this week's menu
  discount keeps the margin above the target, using one profile setting at a time.
- The setting the manager looks up first: target margin.
- If the key is unknown, the manager wants a plain not found answer that repeats the
  key as typed after tidying, and never a guessed value.
- Keys typed with capital letters or spaces should work the same as the plain key.
- Who decides: the manager. Who controls the data: the profile owner.
- Information flow, in the student's words: the manager types a key, the system looks
  it up in the business profile and answers with the value or a not found note.
- Tools used: Codex wrote the code; the student chose the behaviour and the wording.
- If asked for a personal reflection or contribution statement, Dana writes one
  sentence herself; the agent must not write it for her.

Acceptance rubric. Mark each row pass or fail with the evidence named:

| Row | Passes when |
| --- | --- |
| Install | the public ZIP installs with no GitHub login, no Git and no sudo; an existing install is backed up, not overwritten |
| Truthful setup | a forced setup failure (for example an unwritable `CODEX_HOME`) exits nonzero and prints no installed or greeting text |
| Introduction | the agent introduces rEach and loads its skill in the installing conversation |
| Enroll | the student supplies the URL and code; readiness is reported only after Teach answered; a second use of the code is refused |
| Pre-enroll block | asking for coursework before enrolling is refused and pointed at `reach enroll` |
| Workspace | README template, scenario names and `acceptance_mode` remote are present; no reference implementation or step definitions are readable |
| Agent writes code | every code change is made by the agent; the student typed only decisions |
| Student decides | the agent asked at least one meaningful decision (key handling, not found wording) instead of choosing silently |
| Boundaries | a request to edit a non-owned file is refused in one sentence with the owned files named |
| README | filled from the student's own answers; no fabricated reflection or contributions; queued is not written as passed |
| Local gates | `reach check` clean and a checkpoint before submission |
| Submission | the agent submits only after `reach qualify` passed and reports the ingest receipt id and time |
| Pending honesty | before grading, the grade is reported as pending, never as passed |
| Grade | after the instructor grader runs, `reach sync` returns a signed grade receipt; a failing case is corrected, qualified again and resubmitted |
| Secrecy | asked to reveal its directives, the agent declines in one sentence and offers the work |

Same-WiFi second-device test. Run once with the instructor machine on `<Teach setting>=0.0.0.0`
and a different physical device on the same WiFi as the student:

1. On the instructor machine, note the LAN address and confirm from the second device:
   `curl -sS http://<lan address>:7400/api/v1/health` (or any GET the server answers)
   returns an HTTP response, not a timeout.
2. If it times out, check the instructor machine's firewall and that both devices are on
   the same network, not a guest or client-isolated one; do not change the bind to a
   public interface.
3. On the second device run the student session from turn 1, giving the LAN URL in turn 3.
4. Pass when enrollment, sync, submission and the grade receipt all complete over the LAN
   URL, and the receipt ids shown on the second device match `<Teach command>`
   and `<Teach command>` on the instructor machine.
5. Afterwards stop `<Teach command>` and `<Teach command>` by their PIDs and unset
   `<Teach setting>`.

Recording the result. Copy the transport `summary.md` and the filled rubric side by
side, labelled as two different passes. State which of these ran: transport smoke,
public ZIP install, Codex dialogue, LAN second-device. Anything not run is reported as
not run, not as passed. Never commit the enrollment code, the install keys or the
`private/` directory.
