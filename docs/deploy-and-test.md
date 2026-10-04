# Deploying and testing rEach

Three ways to see rEach work, from the quickest to the most thorough. None of them needs a real course server, a student account or a secret, and none touches a real install: each uses a scratch home.

| Example | What it shows | Needs | Time |
| --- | --- | --- | --- |
| [1. Fixture walkthrough](#1-fixture-walkthrough) | enroll, sync, status and doctor against a local stand-in for Teach | Ruby | 2 minutes |
| [2. Platform smoke](#2-platform-smoke) | a real install from the checkout, the hook command lines and the sealed-package known answer | Ruby, network on Ruby 3.0+ | 1 to 5 minutes |
| [3. Agent smoke](#3-agent-smoke) | real Claude sessions with rEach loaded, playing scripted and model-played students | Docker, a Claude sign-in token | 15 minutes and up |

Where each piece runs is drawn in [figure 8 of `architecture.md`](architecture.md#8-deployment-topology).

## Before you start

Run everything from a checkout of this repository. If your shell carries `REACH_*` or `TEACH_*` variables from real course work, clear them first so that nothing here reaches a real install or a real course server:

    for v in $(env | grep -E '^(TEACH|REACH)_' | cut -d= -f1); do unset "$v"; done

## 1. Fixture walkthrough

`tools/fake_teach` is a local development fixture of the Teach half of the wire. It is not Teach: it serves health, enrollment, an install-signed status, the two sealed packages, submissions, hands and grades on `127.0.0.1`, and answers every other route `404`. Its roster holds five fictional students ([`tools/fake_teach/README.md`](../tools/fake_teach/README.md)).

Start the fixture in one terminal:

    ruby tools/fake_teach/server.rb --port 9480

In a second terminal, point rEach at it with a scratch home and a scratch course folder:

    export REACH_HOME="$(mktemp -d)"
    export REACH_WORKSPACE_ROOT="$(mktemp -d)"
    export REACH_TEACH_URL=http://127.0.0.1:9480
    export REACH_UPDATE_DISABLE=1
    export REACH_SUBSCRIBE=0

Check the fixture answers:

    curl -s http://127.0.0.1:9480/api/v1/health

    {"status":"ok","database":true,"blob_store":true}

Enroll the fictional student Maria Delgado. A student would be asked for these one at a time by rEach's prompt hook; the flags are the terminal form:

    ruby exe/reach enroll --course-passkey BUS101-K7QX-94TD --username mdel101 --student-id 1040217 \
      --password-stdin --teach-url "$REACH_TEACH_URL" <<< "choose-a-password"

    You're connected to Business 101: Demo Course. rEach is fetching your course materials now.
    To keep your enrollment yours, rEach records a scrambled fingerprint of this computer and computer account, never your files or passwords, and your course server checks it.
    Keep the password you chose written down somewhere safe.
    Course rules: v1 (verified)
    Workspace: <REACH_WORKSPACE_ROOT>/deliverables/DEMO101/A1/demo.a1-backend
    reach: could not fetch receipts from the course server (no such route)
    Your course workspace is ready.

The receipts line is the fixture, not a fault: it has no receipts route. `Course rules: v1 (verified)` is the sealed guardrails package arriving, its signature checking against the fixture's key and its contents landing in the vault.

Sync again and look at the status:

    ruby exe/reach sync
    ruby exe/reach status

    rEach 0.23.1 · Business 101: Demo Course (Fall 2026) · enrolled as Maria Delgado
    Current assignment: none
    Signed in: no
    Modules: not set yet
    Your slices:
      demo.a1  backend  not started yet   shape: none   checks: not run
    Receipts: 0
    Open hands: none
    Course rules: v1 (verified)   Connection: online (last checked 0 min ago)
    Next: Sign in: type your student ID.

The second sync makes the fixture answer `304` to both packages; `requests.jsonl` under the fixture's `--home` shows every request it served, with the method, path and status and no body.

Run the health check:

    ruby exe/reach doctor

    runtime: not installed
    R-DOC-SUBSCRIBE: background job not installed; last check never
    R-DOC-LIMITS corpus 0.0 MB, managed by the corpus port

Those findings belong to the scratch setup: no runtime kit was installed and `REACH_SUBSCRIBE=0` kept the background job out. `ruby exe/reach runtime install` fetches the kit (Ruby 4.0.7 and Chrome for Testing) when you want local qualification.

What rEach wrote, all of it under the two scratch folders:

| Under | Files |
| --- | --- |
| `$REACH_HOME` | `keys/` (the install key), `stamp.json` (the signed enrollment stamp), `fingerprint.json`, `packages/`, `vault/`, `receipts/`, `state/` |
| `$REACH_WORKSPACE_ROOT` | `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `deliverables/DEMO101/A1/demo.a1-backend/`, `extracurricular/` |

Try two refusals the fixture supports:

| Do this | rEach answers |
| --- | --- |
| enroll with `--course-passkey ACCT201-2M8R-QW3Z` | "That course passkey belongs to a course that has ended, so it can't be used anymore. Ask your instructor for the current passkey." |
| enroll with `--student-id 9999999` | "Your course server couldn't match that username and student ID to the class list for BUS101. ..." |

Use a fresh `REACH_HOME` for each, so the refusals do not disturb the enrollment above.

Stop the fixture with Ctrl-C and delete the two scratch folders when you are done.

## 2. Platform smoke

`tools/platform_smoke/run.rb` does the same thing end to end and unattended: it installs rEach from the checkout's `HEAD` into a scratch directory whose path contains a space, starts the fixture on a free port, and runs rEach's own commands and its harness hook command lines against it. It starts no agent session. `.github/workflows/platforms.yml` runs it on Linux, macOS and Windows on every push to `main`.

    ruby tools/platform_smoke/run.rb --skip-runtime

    PASS install version 0.23.1 at /tmp/rs.../reach smoke/plugin
    PASS package_known_answer opened Teach's sealed envelope; digest 86ab9f5adeff, entries hello.txt
    PASS fake_teach health 200 on http://127.0.0.1:34441 after 2 attempt(s); webrick present
    PASS hook_session_start exit 0
    PASS hook_prompt_locked blocked with exit 2 and a message on stderr
    PASS hook_codex blocked with exit 2 and a message on stderr
    PASS enroll You're connected to Business 101: Demo Course. ...
    PASS sync_packages guardrails and workspace fetched, stored as 1.pkg and revalidated with 304 on the second sync
    PASS hook_prompt_open signed in through the plugin hook (...), gate open
    PASS status names Maria Delgado, no fingerprint_mismatch

Three steps are the ones worth reading closely:

- `hook_prompt_locked` is the enrollment lock: before enrollment the prompt hook exits 2 with a message, which is how a harness is told to block the prompt.
- `package_known_answer` opens an envelope that the real Teach sealed, with test keys committed under `tools/platform_smoke/fixtures/known-answer/`. It is the one place this repository proves, without Teach present, that rEach reads what Teach writes.
- `hook_prompt_open` is the same hook after enrollment and sign-in, now letting the prompt through.

Drop `--skip-runtime` to also install the runtime kit and let doctor find its Chrome; `--report PATH` writes a JSON report and `--keep` leaves the scratch directory in place. The exit status is 0 only when no step failed. Commit before you run it: it installs `HEAD`, not your working tree.

The `doctor` step fails on any finding outside its expected list, so it also fails where the machine itself cannot do something rEach expects. On a machine with no systemd user manager, for example, it reports `R-DOC-SUBSCRIBE`. [`tools/platform_smoke/README.md`](../tools/platform_smoke/README.md) lists the expected findings.

## 3. Agent smoke

`tools/smoke` drives real Claude sessions with rEach loaded, the way a student would, inside Docker: an install from the repository's link, the intake interview, drift, privacy requests and the course gate. Run it before tagging any release that changes what a student sees (`STD-SMOKE`).

    ruby tools/smoke/run.rb

It needs a dedicated sign-in token and a one-time image build; [`tools/smoke/README.md`](../tools/smoke/README.md) has the setup, the scenario list and the sandbox's limits. The course-gate scenario needs a course server on the host, so only someone who runs Teach can run that one; the others run for anyone.

## With a real course server

A student never configures anything: a release of rEach carries its course server's HTTPS address in `config.yml` (`teach.url`), and rEach never asks the student or the agent for it. Deploying rEach for a course is therefore three steps on the rEach side:

1. Set `teach.url` in `config.yml` to the course server's address and tag a release.
2. Give students the repository link; they paste it into their AI agent and ask it to install rEach ([`INSTALL.md`](../INSTALL.md)).
3. Share the class-wide course passkey. Each student enrolls once, on their own computer ([figure 3](architecture.md#3-the-enrollment-handshake)).

Running the course server itself is outside this repository.

`reach doctor` is the check to run on a student's computer afterwards. It reports `R-DOC-WIRE` when the course server advertises a different wire contract from the one in `specs/wire.yml`.
