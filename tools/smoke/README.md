# Reach smoke test

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
GitHub-shaped ZIP, enrols, syncs the G1 context A1 backend workspace, writes and submits
an implementation, and follows the ingest and grade receipts. It writes `summary.json`
and `summary.md` under `~/.cache/reach-smoke/a1/<timestamp>/`. Its reference steps are
`reference-pack`, `reference-locked-before-enrol`, `reference-after-sync` and
`reference-tamper-refused`; the smoke packs the reference blob before releasing, so the key
exists when Teach builds the guardrails package. The manual Codex
dialogue and the same-WiFi test are in `docs/smoke-assignment-1.md`.
