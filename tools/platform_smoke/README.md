# Platform smoke

`run.rb` installs Reach from the checkout's HEAD into a scratch directory whose path contains a space, starts the fixture Teach (`tools/fake_teach/server.rb`), and runs Reach's own commands and its harness hook command lines against it. It starts no agent session and needs no secret. It uses only the Ruby standard library and runs on Ruby 2.6.10 through 4.0.x on Linux, macOS and Windows.

    ruby tools/platform_smoke/run.rb [--skip-runtime] [--report PATH] [--leg NAME] [--keep]

Every step prints `PASS <step> <detail>`, `FAIL <step> <detail>` or `SKIP <step> <reason>`, then `platform smoke: N passed, M failed, K skipped`. The exit status is 0 only when no step failed. `--report` also writes a JSON report (`reach.platform-smoke/v1`) with the platform, Ruby version, OS version and each step's name, result, detail and duration. `--keep` leaves the scratch directory in place. `--leg NAME` labels the run in the report (default the Ruby `host_os` and `host_cpu`).

The report also carries `leg`, `reach_version` (the checkout's `VERSION`), `commit` (`GITHUB_SHA`, else `git rev-parse HEAD`, else `unknown`) and `environment`: the installed copy's `Reach::Environment.fields` (harness, os, os_release, arch, ruby), read by running the installed copy's Ruby lib, or the `os_version` string when that fails. The existing keys are unchanged.

The fixture Teach needs the `webrick` gem, which Ruby 3.0 and later no longer bundle. When `require "webrick"` fails, the script runs `gem install --no-document --install-dir <scratch>/gems webrick` (one attempt and one retry, each with a timeout) and starts the fixture with `GEM_PATH` including that directory and `GEM_HOME` unset. The outcome is part of the fake_teach step detail, so the machine needs network access to rubygems.org in that case.

The scratch workspace root is `<scratch>/work` (`REACH_WORKSPACE_ROOT`), so provisioning never writes to the real `~/reach-work`. The script starts from a copy of the environment with every `TEACH_*` and `REACH_*` variable removed, sets `REACH_HOME` to the scratch home, `RPLUGIN_HOME` to an empty `<scratch>/rplugin`, `XDG_STATE_HOME` to `<scratch>/state` and `REACH_UPDATE_DISABLE=1`, and never touches the real `~/.reach`, `~/.rplugin`, rplugin state or corpus. Without the rplugin overrides, a machine with rplugin installed ran the smoke with brain planes in process against its real `~/.corpora/reach`. The scratch root sits directly under the system temp directory with a short name, because Chrome cannot start when its socket path is long. Set no long `TMPDIR` when you run it.

## Steps

| Step | What it proves |
| --- | --- |
| install | `scripts/reach-install --archive` of a `git archive` of HEAD installs the same VERSION and an `exe/reach` |
| package_known_answer | the installed copy's `Reach::Crypto.open_envelope` and `Reach::Tarball.read` open `fixtures/known-answer/envelope.json`, sealed by real Teach's crypto, with the committed test keys; the content digest and the `hello.txt` digest equal `expected.json`; a failure prints the exception class and message |
| fake_teach | the fixture answers `GET /api/v1/health` with 200 |
| hook_session_start | the SessionStart command from the installed `hooks/hooks.json` exits 0 |
| hook_prompt_locked | the UserPromptSubmit gate blocks before enrollment: exit 2, a message on stderr, nothing on stdout |
| hook_codex | the same block through the command from `hooks/codex.json`: exit 0 and `{"decision":"block","reason":...}` on stdout (STD-CODEX-PROMPT-JSON-BLOCK) |
| enroll | `reach enroll` against the fixture connects the student to the course |
| machine_id | `Reach::Fingerprint.machine_id` is not `unknown` and has the platform's form |
| sync_packages | `reach sync` exits 0 with no package fetch, course rules or workspace warning; `packages/guardrails/1.pkg` and `packages/workspace/1.pkg` are stored under the scratch `REACH_HOME`; a second `reach sync` makes the fixture answer 304 to both kinds, counted from its `requests.jsonl`; it then waits for Reach's local request budget to refill so doctor's health check is not rate limited |
| hook_prompt_open | the same gate command exits 0 and does not block once enrolled |
| status | `reach status` names the enrolled student and does not report `fingerprint_mismatch` |
| runtime | `reach runtime install` and `status` show the pinned runtime and its Ruby 4.0.7; on a platform with no kit the unsupported message is the pass |
| doctor | runs after runtime so it sees the runtime Chrome; every finding code `reach doctor` prints is in `EXPECTED_DOCTOR_FINDINGS`; with the packages stored, `R-DOC-GUARD` is no longer expected |

Hook commands run through `sh -c` on Linux and macOS and through Git for Windows' `bash.exe` (found next to `git.exe`, never WSL's) on Windows.

## Expected doctor findings

`EXPECTED_DOCTOR_FINDINGS` in `run.rb` holds only findings caused by the fixture Teach.

| Code | Reason |
| --- | --- |
| R-DOC-HARNESS | the smoke installs no agent harness by design (commands-only smoke) |

`EXPECTED_DOCTOR_LINES` in `run.rb` holds codes that are expected only in one exact wording; any other wording of the same code fails the step.

| Code | Tolerated wording | Reason |
| --- | --- | --- |
| R-DOC-BRAIN-PLANES | `planes: spool mode (SDK not installed)` | doctor prints this status line on every run; the smoke installs the runtime kit but not the pinned SDK kit, so spool mode is the correct state. `could not be checked` fails |
| R-DOC-SUBSCRIBE | `background job installed; last check never` | doctor prints this status line on every run; a fresh runner has installed the job and has not yet checked. `not installed` and `not checked` fail |
| R-DOC-CODEX | `Codex's sandbox blocks rEach (internet ..., folder ...) - run reach codex configure` | macOS runners ship Codex and the smoke never runs `reach codex configure`, so its sandbox correctly blocks rEach. `settings no longer hold what rEach set` fails |

`NO_KIT_DOCTOR_LINES` adds one wording that is tolerated only when the runtime step did not install a kit: `R-DOC-BRAIN-PLANES` `planes: spool mode (no runtime kit)`, which Windows arm64 prints because it has no runtime kit and so no Ruby for the planes. With a kit installed that wording fails.

`R-DOC-CHROME` is expected only when the runtime step did not install a kit: with `--skip-runtime`, or on a platform outside `Reach::RuntimeKit::PLATFORMS` such as Windows arm64. When a kit was installed, doctor must find the runtime's Chrome (`check_chrome` reads `chrome_exe` from the active runtime) and the finding fails the step.

Any other finding fails the step and is printed in full.

## Windows VM runners

`windows-runner/bootstrap.ps1` prepares a fresh Windows 10 or 11 VM once, from an elevated Windows PowerShell 5.1: OpenSSH Server with a firewall rule for port 22 and PowerShell as the default SSH shell, Git for Windows 2.56.0 (Git Bash included), RubyInstaller 4.0.7-1 x64 for all users with its bin directory on the machine PATH, and the GitHub Actions runner 2.337.0 for win-x64 in `C:\actions-runner`. Each download is checked against a pinned SHA-256 and retried up to three times.

`windows-runner/register.ps1 -Url <repository url> -Token <registration token> -Label win10|win11 -Name <runner name>` registers the runner as a service. The token is passed at run time and never written to disk.

## Groups and the tested matrix

`matrix.rb` groups the steps. `claude-code` is hook_session_start, hook_prompt_locked and hook_prompt_open; `codex` is hook_codex and codex_sandbox_decrypt; every other step belongs to `core`. A group passes when none of its steps failed and at least one passed. `claude-code` and `codex` also need `core` to pass.

    ruby tools/platform_smoke/matrix.rb --out DIR REPORT.json...

reads one or more reports and writes `DIR/compat-tested.json` (`reach.compat-tested/v1`: `reach_version`, `commit`, `generated_at`, `scope`, and one cell per leg and group with `leg`, `os`, `os_release`, `arch`, `ruby`, `harness`, `result` and `failed_steps`) and `DIR/compat-tested.md`, a table of legs and OS releases against the three groups. It exits 0 even when cells fail and 2 only on unreadable input. The scope is stated in both files: commands and hook command lines, no live agent session.

The `matrix` job in `.github/workflows/platforms.yml` runs after `hosted` and `vm` (always, so it still runs when the VM legs are skipped), downloads every `platform-smoke-*` artifact into one directory, runs `matrix.rb` with the system Ruby, uploads `compat-tested-<reach_version>` for 14 days and appends `compat-tested.md` to the job summary.

## Called by the stable workflow

`platforms.yml` is also a reusable workflow (`workflow_call` with `ref` and `vms` inputs). `.github/workflows/stable.yml` calls it once a day with `ref` set to the Latest tag when `tools/stable_promote.rb plan` answers promote, and with `vms` on when `vars.REACH_VM_RUNNERS` is `on`. When every leg succeeds the workflow moves `stable` to the tag and closes any open `stable-hold` issue; when a leg fails or is cancelled it leaves `stable` where it is and opens, or comments on, one `stable-hold` issue naming the tag and the run.
