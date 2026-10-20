# Reach smoke test

## Full course pipeline smoke

`course_matrix.rb` inventories every module and assignment slot from Grokit
`v0.10.1`, both backend and panel slices, and every required answer shape from
Teach's developer specification. It reads pinned source with `git show`, keeps
implementations out of the inventory and agent prompts, and fails if a module, slot,
owned slice, or tagged scenario is absent. Course mapping confirmed by Sven:
SMOKECHOICEFA26 uses student choice; smoke-assign-fa26 uses instructor assignment.
These are synthetic test profiles, not snapshots of live course settings.

The inventory is 280 cases: two courses × ten modules × seven cutouts × two
slice kinds. A1 has one cutout per module; A2, A3, and A4 each have two. Every
case also includes all four of that assignment's student questions. The older
`slice_build.rb` and `assignment_one.rb` remain narrow runners; neither proves
coverage of this matrix.

`scenarios` lists the protected graded cases. `local_scenarios` lists the
delivered practice cases for panel replay kits, and the graded cases for backend
slices. Local practice inputs differ from graded inputs. Local coverage and the
starting-stub check require the shipped practice names; Teach independently runs
every protected graded name. An absent or empty practice contract fails closed.

```
ruby tools/smoke/course_matrix.rb --plan
ruby tools/smoke/course_matrix.rb --run
ruby tools/smoke/course_matrix.rb --plan --select smoke-assign-fa26 --select context.a1
ruby tools/smoke/course_matrix.rb --run --select .a2
ruby tools/smoke/course_matrix.rb --verify-case /absolute/run/0001
```

`--plan` materializes `case.json` and `prompt.md` in each case directory and
whole-run `report.json` and `report.md` under `.scratch/course-smoke-<timestamp>-<random>/`.
Every case is explicitly `planned`; no pipeline or model is invoked. It accepts
`--grokit DIR`, `--teach DIR`, and a new `--output DIR`. Repeated `--select TEXT`
filters intersect, match case IDs, and reject an empty selection. Repeated
`--case ID` selects a union of exact IDs and rejects unknown IDs.

`--run` defaults to the bundled `course_native.rb` driver. It copies Teach's
public source to scratch, shifts dates there so the case's assignment is current,
creates a fresh PostgreSQL database and synthetic course/student, and runs the
native security validation, enrollment, sign-in, module selection/assignment,
package delivery, answer capture, planning, checks, checkpoint, local real/stub
qualification, Teach qualification, encrypted submission, ingest receipt,
student-facing confirmation, grading, and grade receipt retrieval. Teach's
actual Docker grading sandboxes run the scenarios; no grade or qualification
result is fabricated. Each failed case retains its failed stage and reason,
and the suite continues through the other cases.

Native mode installs the pinned Grokit developer reference slice and tagged
scenarios as **test fixtures**. It does not prove an agent can build that slice.
When a reference behaviour calls an ungranted `Grokit::Decimal`, the fixture
copies that pinned pure helper into a nested module inside its owned behaviour
class and calls the owned helper instead. `build.json` lists each adaptation.
This adds no instructor API grant and does not relax the boundary checker.
The pinned Finance A3s2 backend fixture sums existing typed input amounts rather
than constructing an ungranted Money zero. Its aggregation path requires at
least three people. This exact pinned-source adaptation is also recorded in
`build.json`; runtime checks and instructor source remain unchanged.
`execution_kind: native_fixture` identifies this explicitly. It invokes no model
and accounts for $0 in model spending. It replaces only Reach's HTTP transport
with in-process Rack calls into the actual scratch Teach app and omits network
token-bucket waits in that process. Signatures, authentication, ownership,
consent, qualification, ingestion, and receipt verification remain native.
It does not verify deployed networking, TLS, pacing, or agent conversation quality.

Prerequisites: PostgreSQL (`createdb` and access to a scratch database), Docker,
the `teach-grader:ruby-4.0.7` and `teach-grader:ruby-2.6.10` images, Ruby 4.0.6 at
`~/.rubies/ruby-4.0.6/bin` (or `SMOKE_RUBY4_BIN`), Teach's installed bundle,
Dovetail, and the Grokit v0.10.1 source. Teach must implement the security
validation contract. In this development checkout the default is the isolated
`.scratch/teach-security-validation` candidate when present, otherwise the usual
Teach source checkout. `--teach`, `--bundle`, `--dovetail`, and `--grokit` override
these developer source locations; none selects a live service or database.

`--runtime-kit DIR` uses a cached Reach runtime kit containing its manifest and
assets. Reach checks its existing manifest and asset pins. Without it, Reach's
normal runtime installer downloads its pinned kit. The runtime and build caches
are shared only inside the scratch run; each case keeps its own Teach and Reach
homes, keys, database, workspace, and evidence.
Use disk-backed storage for a full sweep. The runner checks estimated free bytes
and inodes before provisioning; a tmpfs can exhaust its file count while still
showing many free gigabytes. Every selected case appears in the report before
execution, including cases not yet run.
Browser and grader temporary directories use short sibling names (`.rs-<nonce>`)
on that same disk, avoiding Chromium's Unix-socket path-length limit. An overly
long output parent is refused before provisioning. A passing case's directory is
removed with its homes; a failing case's stays until `--prune`; container cleanup is restricted to mounts belonging to
that case or its exact temporary directory. A pending qualification is resumed
at most twice through Reach's own pending-record path; no result is synthesized.

### Resource guards (the SMOKE directive)

Every output, including `--plan`, `--merge-run`, and the default, must sit
under this checkout's ignored `.scratch/` or the main clone's `.scratch/` (a
worktree's own path is usually too long for Chromium sockets). Any other root,
such as `~/Downloads` or `/tmp`, is refused; there is no override.

Before a `--run` provisions anything, the runner requires free bytes and inodes
of three times the estimate (`limits.disk_headroom`) and inspects every image
in `grader_images`; a missing image stops the run before the first case. The
image IDs are recorded in the report under `environment`.

The first case is the canary (`canary: true`). A case is materialized only when
it is about to run, so a stopped run leaves no directories for unrun cases. A
failure whose reason matches `environment_failures` (or starts with
`environment:`) is classed `environment`: it writes `STOP` with the reason and
every later case stays `not_run`. Other failures are classed `product`; when
`limits.repeat_failure_halt` (3) cases fail with the same stage and reason,
numbers and hashes aside, the run writes `STOP` the same way.

A passing case keeps only `case.json` and `evidence.json`; its homes, logs, and
`reach_smoke_<random>` database are removed once the verifier accepts it, so
`--verify-case` applies to failures and to runs made with `--keep-passing`.
A failing case keeps everything. The Grokit export tarball is deleted once
extracted.

When a run is finished, archive it and then remove the tree:

```
ruby tools/smoke/course_matrix.rb --archive .scratch/course-smoke-<id>
ruby tools/smoke/course_matrix.rb --prune .scratch/course-smoke-<id>
```

`--archive` writes `<run>.tar.gz` and `<run>.manifest.json` (archive SHA-256,
entry count, tree and archive bytes, sources, and statuses) beside the run and
refuses to overwrite either. `--prune` deletes the tree only when the archive
still matches its manifest's hash and entry count, and also removes each case's
`.rs-<nonce>` sibling, which the archive does not hold.

An explicit `--harness-argv JSON` selects an external, budget-enforcing agent
adapter with no shell interpolation. It receives the absolute `case.json` and
case directory as two additional arguments, must perform native provisioning
and evidence collection, and is reported as `agent_adapter`. It is separate
from the bundled fixture runner; a fixture pass is not agent-build coverage.

Examples:

```
ruby tools/smoke/course_matrix.rb --run --runtime-kit /absolute/cached/runtime-kit
ruby tools/smoke/course_matrix.rb --run --select context.a1 \
  --harness-argv '["/absolute/path/to/agent-adapter"]' --budget-usd 25
```

Native runs reserve $0. External agent adapters reserve at most $4.50 per case
($1,260 for all 280); that is a configured ceiling, not an observed cost. The
agent adapter must enforce each reservation for all nested model calls.
The controller runs one case at a time, with no retries, a
2,700-second case timeout, a 2 MiB log limit, process-group cleanup, and a clean
environment containing only PATH, scratch HOME/TEACH_HOME/REACH_HOME, a unique
`reach_smoke_<random>` database URL, and the reservation. It does not pass host
Teach credentials or configuration. An agent adapter needs dedicated harness credentials;
it must not extract host service secrets. `REACH_SMOKE_DISABLE=1` refuses startup;
Ctrl-C, SIGTERM, or a run/case `STOP` file stops further execution. Failed cases
charge the full reservation because actual usage is unknown.
Unused cases are `not_run`; subsets never set `coverage_complete` true.
`execution_complete` means every selected case was attempted; `coverage_complete`
requires all 280 cases to pass. `reach_source_sha256` binds plans to the tested
Reach source and runner; native execution refuses a changed source snapshot.

For a bounded parallel sweep, run four independent `--select .a1`, `.a2`, `.a3`,
and `.a4` commands with different output directories under `.scratch/`. They select 40, 80, 80, and
80 cases. Merge their finished reports:

```
ruby tools/smoke/course_matrix.rb \
  --merge-run /absolute/run-a1 --merge-run /absolute/run-a2 \
  --merge-run /absolute/run-a3 --merge-run /absolute/run-a4 \
  --output /absolute/merged-report
```

Merging rejects duplicate/unknown cases and mismatched source snapshots or engines.
The merged command fails unless every case in the full inventory passed.

### Verified execution, 2026-10-18

The r8 full sweep attempted all 280 unique cases: 278 passed, two failed, and
none were skipped or left unrun. Each course had 139 passes and one failure.
A1 passed 40/40; A2 passed 80/80; A3 passed 78/80; A4 passed 80/80.
Both failures were `finance.a3s2/backend` at CK-PORTS because the pinned
reference fixture constructed an ungranted Money zero. The r9 fixture correction
then passed both affected course profiles through all fifteen stages, including
Teach qualification, submission, and matching signed ingest and grade receipts.
The other 278 fixtures and the runtime code were unchanged.

Baseline reports: `.scratch/course-full-merged-r8/report.{json,md}`.
Corrective reports: `.scratch/course-finance-correction-r9/report.{json,md}`.
The source fingerprints differ, so these are separate cohorts, not one green
280-case snapshot. Both reports retain `coverage_complete: false`: the baseline
has failures, and the correction is a subset. Native model cost was $0.
This is fixture pipeline evidence, not agent-built or deployed-network coverage.

### Native evidence contract

The adapter writes `evidence.json` in its case directory. All referenced paths
are relative, nonempty files inside that directory; symlink escapes are refused.
It contains the exact `id`, `nonce`, and `database` from `case.json`,
`synthetic: true`, and `cost_usd` as a nonnegative number within the reservation.
`stages` is an ordered array of `{name, status: "passed", evidence: "path"}`:
security_validation, enroll, module_selection, sync, answer_handoff, plan, build,
check, checkpoint, local_qualify, teach_qualify, submit, teach_receipt,
student_receipt, and grade. Logs must be actual native outputs. A passed label
with an empty file is insufficient. Any missing, duplicated, reordered, or
skipped stage fails.

Additional fields name these files:

| Field | Required evidence |
|---|---|
| `answers` | JSON mapping every required question ID to its fabricated text; minimum word counts apply. |
| `shape` | Normalized native shape output with numeric `errors: 0`. |
| `local_qualify` | Array `{feature, name, result}` covering exactly the pinned `local_scenarios`, all `passed`. Keep raw local/stub output. |
| `teach_qualify`, `grade` | Arrays `{feature, name, result}` covering exactly the pinned protected `scenarios`, all `passed`. Keep raw outputs as stage evidence. |
| `submission_manifest` | Actual native manifest, bound to course, assignment, cutout, slice, and owned files; never partial. |
| `teach_public_key` | Fresh scratch Teach RSA public key; never a private key. |
| `submission_id` | Nonempty native submission ID. |
| `receipts` | `{ingest: {teach: "path", student: "path"}, grade: {teach: "path", student: "path"}}`. |

The security_validation stage's JSON must contain native `phase: "passed"` and
the signed `receipt` bound to this course. The module_selection stage's JSON
normalizes the native result as `{course, mode, modules}`. The student_receipt
stage is the agent's actual student-facing message containing the ingest receipt
number. Both Teach/Reach receipt copies must match, carry valid RSA-PSS signatures,
match student/assignment/cutout/slice/submission, and be issued during this run.
The signed grade must contain all expected scenario names with `passed` and
score 1. A self-signed fixture can test this verifier; it does not prove that
Teach ran. Native stage evidence and trusted adapter execution remain necessary.

`course_matrix_check.rb` is the verifier's offline Minitest regression suite,
written at Sven's request:

```sh
ruby tools/smoke/course_matrix_check.rb
```

It needs no PostgreSQL, Docker, model, Teach, corpus, or harness. Each case
builds a fresh synthetic proof in a temporary directory with a scratch RSA key
and fixed timestamps, then changes one condition: stages, paths and symlinks,
size limits, answers, shape, the three scenario lanes, module selection,
manifest, signatures, receipt binding and copies, security-receipt time bounds,
signed grade, receipt message, and cost. It also runs `--verify-case` as a
subprocess and merges tiny synthetic shards, refusing mixed source fingerprints
and keeping failed and not_run rows. It found that the verifier accepted a
private key as `teach_public_key`; the verifier now refuses one. On 2026-10-18
it ran 52 tests and 685 assertions with no failure, error, or skip, and the
fixed verifier still verified all 280 preserved passing r8/r9 case directories
and refused the two failed ones. Fifteen deliberate verifier defects in scratch
copies were run against it; fourteen failed the suite, and the survivor
(dropping `finite?` from the cost check) is equivalent because the bounds
already refuse NaN and infinities. The suite proves the verifier's
contract, not that Teach or an agent ran a pipeline. Executable pipeline
verification uses the actual native driver and its captured artifacts; planning
is never reported as a pipeline pass.

`tools/smoke` drives real Claude sessions with rEach loaded, the way a student would,
and checks what rEach says and does. Run it before tagging any release that changes
the persona, greetings, hooks, install path or anything else a student sees
(`STD-SMOKE` in `specs/app.yml`).

It is not part of the plugin and never runs on a student's computer.

## What it does

Each scenario is a conversation:

- **install-from-link**: a student gives a plain Claude the repository's link and
  answers its questions, Claude installs rEach, and a new session meets it
- **first-run-cooperative**: a full intake interview
- **skip-and-stop**: skipped questions and an early stop
- **drift**: off-course requests during the interview
- **sensitive**: a volunteered disability
- **privacy-show-forget**: "what do you know about me?", then "forget my profile"
- **returning**: the next session's greeting
- **course-gate**: an enrolled student asks rEach to edit a read-only course file

The student is either scripted lines or a model playing a described student.
Scenarios, students and checks live in `scenarios.yml`. privacy-show-forget,
returning and course-gate start from the profile first-run-cooperative saves, so
name first-run-cooperative in the same run.

Hard checks decide pass or fail. They look at replies, tool calls and the files a
scenario leaves behind: the profile's fields and mode, the workspace files, and the
installed plugin. A model judge adds advisory notes.

## The sandbox

Every session runs in a Docker container built from `Dockerfile`. The image is
Ruby 2.6.10, the Mac floor, plus git. The container:

- runs as your user, with all capabilities dropped, no new privileges, a read-only
  root, and limits on processes, memory and CPU;
- sees a scratch home for the run, this repository read-only at `/plugin`, and the
  host's `claude` binary read-only;
- never sees your home directory, your Claude configuration, hooks, skills, memory or
  MCP servers;
- gets only the tools the scenario needs. rEach sessions have no shell and no web;
  the install scenario gets a shell, still inside the container.

For the course scenario, Teach runs on the host bound to the Docker bridge gateway
(172.17.0.1). The install scenario's link is served the same way, from a bare clone
of committed `HEAD`. **Commit before running it**, or it installs the previous commit.

## Running it

One-time setup:

1. Make a dedicated sign-in token in your own terminal. If `claude` is a shell
   function or alias, use `command claude`.

   ```
   command claude setup-token
   mkdir -p ~/.config/reach-smoke && ( umask 077; read -rsp 'Token: ' t && printf '%s\n' "$t" > ~/.config/reach-smoke/token )
   ```

2. Docker must work without sudo. The image builds itself on the first run.

Then:

```
ruby tools/smoke/run.rb --list                 # scenario ids, no API calls
ruby tools/smoke/run.rb                        # every scenario
ruby tools/smoke/run.rb skip-and-stop drift    # some scenarios
```

The course scenario also needs Teach. Without these variables it is skipped, not failed:

```
SMOKE_TEACH_DIR=~/bitbucket/paterasai/teach \
SMOKE_GROKIT_ROOT=~/bitbucket/paterasai/grokit \
SMOKE_TEACH_PATH=~/.rubies/ruby-4.0.6/bin \
ruby tools/smoke/run.rb course-gate
```

Each run writes to `~/.cache/reach-smoke/runs/<run id>/` (or `SMOKE_RUNS_DIR`):

- `summary.md`, the verdict table;
- per scenario, `transcript.md`, `result.json` and the raw event streams.

The process exits 0 when nothing failed or errored.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `SMOKE_MODEL` | `haiku` | the model playing rEach (use `sonnet` for a release run) |
| `SMOKE_STUDENT_MODEL`, `SMOKE_JUDGE_MODEL` | `haiku` | the student actor and the judge |
| `SMOKE_BUDGET_USD` | `5` | whole-run spending ceiling; the run stops when crossed |
| `SMOKE_SESSION_BUDGET_USD` | `1` | per-session `--max-budget-usd` |
| `SMOKE_TURN_TIMEOUT_S` | `180` | per-turn timeout |
| `SMOKE_TOKEN_FILE` | `~/.config/reach-smoke/token` | or set `CLAUDE_CODE_OAUTH_TOKEN` |
| `SMOKE_TEACH_PORT`, `SMOKE_GIT_PORT` | `7497`, `8479` | ports on the bridge gateway |
| `SMOKE_GATEWAY` | `172.17.0.1` | the Docker bridge gateway |
| `SMOKE_IMAGE` | `reach-smoke:ruby2.6` | the sandbox image |

## API safety

- **Upstream limits.** Calls go to Anthropic through the Claude Code CLI, on the
  token's subscription. Usage counts against that plan's limits, which Anthropic
  publishes for the plan.
- **Throttling.** One conversation at a time, one turn at a time. Each turn waits
  for its reply, so there is no fan-out and no parallel calls.
- **Retries.** None. A failed or timed-out turn ends that scenario with ERROR, and
  the run continues with the next scenario.
- **Timeouts.** Every turn has `SMOKE_TURN_TIMEOUT_S`, and every one-shot call
  (judge, Reach CLI) has a hard `timeout`.
- **Spending.** `--max-budget-usd` applies per session, and `SMOKE_BUDGET_USD`
  applies across the run, summed from each turn's `total_cost_usd`. A full Haiku
  run costs about $1.50.
- **Credentials.** The token comes from the token file or the environment. It
  reaches the container by variable name only, never on a command line, and never
  in a file inside the sandbox.
- **Kill switch.** `REACH_SMOKE_DISABLE=1` refuses to start. Creating a `STOP`
  file in the run folder stops the run before its next turn. Ctrl-C kills every
  container.
- **Failure modes.** A missing token, Docker or `claude` stops the run before any
  call. A busy port or a failed Teach start marks that scenario ERROR. A crossed
  ceiling stops the run and still writes the summary.

## Assignment one transport smoke

`ruby tools/smoke/assignment_one.rb` is a separate, deterministic run that invokes no
model. It starts a real Teach in an isolated home, installs rEach from a local
GitHub-shaped ZIP, enrolls, syncs the G1 context A1 backend workspace, writes an
implementation, checks that submit is refused before any qualification, writes the
agent's scenarios from `tools/smoke/qualify/`, qualifies locally and on Teach (with
Teach's grader running), submits, and follows the ingest and grade receipts.

It runs Teach from a clean export of the committed `HEAD` of `SMOKE_TEACH_REPO` (default
`~/bitbucket/paterasai/teach`), written to `<run dir>/teach`, so uncommitted changes in that
checkout never reach the run. `--teach-dir DIR` or `SMOKE_TEACH_DIR` runs a given tree
instead. Teach's gems come from `SMOKE_TEACH_BUNDLE` (default that checkout's `vendor/bundle`).

Enrollment follows the Teach 0.17 flow in both drivers: `teach roster import --course ID
FILE.csv` (columns `student_id,username,display_name,group`), `teach course code mint
--course ID` for the class-wide course code, then `reach enroll --course-code C --username U
--student-id I --password-stdin` with an 8 to 256 character password on stdin. The synthetic
student is `smok001` with ID `1000001` (chosen to fit the course's identity rules). The step
`enroll-wrong-student-id-refused` enrolls the same username with a different ID from a second Reach home and expects the refusal and no
second install. The course code and password are kept in the drivers' redaction list. It writes `summary.json`
and `summary.md` under `~/.cache/reach-smoke/a1/<timestamp>/`. Its reference steps are
`reference-pack`, `reference-locked-before-enroll`, `reference-after-sync` and
`reference-tamper-refused`; the smoke packs the reference blob before releasing, so the key
exists when Teach builds the guardrails package. The manual Codex
dialogue and the same-WiFi test are in `docs/smoke-assignment-1.md`.

## Slice-build smoke

`ruby tools/smoke/slice_build.rb` runs the course path once per Grokit module with real models: a model-played student and a real Claude agent with rEach loaded build that module's panel cutout on Dovetail from a clean cafe workspace, inside the same Docker sandbox, against a scratch Teach. Each run is graded by Teach's grade, the Dovetail strict shape findings, the qualification attempts, wall time and cost. The harness never calls `reach part record` or `reach submit`; everything goes through the plugin, so a stall is a finding.

Teach serves only its current assignment, so a run has one phase per assignment (A3, then A4). Each phase gets its own throwaway clone of Teach at the `origin/main` sha, its own PostgreSQL database (`reach_smoke_<run id>_<assignment>`, created with `createdb` and never dropped), its own `TEACH_HOME`, a Teach grader, and a `teach.spec.yml` whose due dates are shifted in the clone only so that the phase's assignment is current. Grokit is cloned at `v0.10.1` (`SMOKE_SLICE_GROKIT_TAG`).

Prerequisites: everything the Reach smoke needs (Docker, the token file, the `reach-smoke:ruby2.6` image), plus Ruby 4.0.6 at `~/.rubies/ruby-4.0.6/bin`, a Teach checkout at `~/bitbucket/paterasai/teach` whose `vendor/bundle` holds the `pg` gem, a Grokit checkout at `~/bitbucket/paterasai/grokit`, Dovetail built at `~/github/foss/dovetail`, PostgreSQL reachable with `createdb` and `psql` as your user, and the Docker images `teach-grader:ruby-4.0.7` (Teach's grader runs Chrome from /opt/chrome) and `teach-grader:ruby-2.6.10`. It never touches the live Teach.

```
ruby tools/smoke/slice_build.rb --list              # the ten targets
ruby tools/smoke/slice_build.rb --dry-run           # provision, enroll, sync, check workspaces; no model calls
ruby tools/smoke/slice_build.rb assurance           # one module
ruby tools/smoke/slice_build.rb                     # all ten, A3 then A4
```

Limits, all overridable: `SMOKE_SLICE_MODEL` (sonnet), `SMOKE_STUDENT_MODEL` (haiku), `SMOKE_SLICE_SESSION_BUDGET_USD` (4), `SMOKE_SLICE_BUDGET_USD` (30, whole run), `SMOKE_SLICE_TURN_TIMEOUT_S` (900), `SMOKE_SLICE_MAX_TURNS` (40), `SMOKE_SLICE_MODULE_TIMEOUT_S` (2700), `GRADER_TIMEOUT_S` (900), `SMOKE_SLICE_TEACH_BUNDLE`, `SMOKE_SLICE_RUNS_DIR`, `SMOKE_SLICE_AGENT_MEMORY` (4g for the agent container). If the agent's `claude` process dies (it has crashed with a Bun segfault), the session is resumed once with `--continue` and the student's message resent; the report notes it. A run stops cleanly on the spend ceiling, on SIGINT and when `<run dir>/STOP` exists; Teach and the grader are stopped on every exit. A failed turn is not retried. Cost is about one to two dollars per module; the whole run is budgeted at 30 dollars.

Reports land in `~/.cache/reach-smoke/slice-build/<run id>/`: `report.md` (a verdict table, the run total, then per module the failing scenarios, shape findings and the last three agent replies), `report.json`, and per module the session JSONL, transcript and shape-check files.
