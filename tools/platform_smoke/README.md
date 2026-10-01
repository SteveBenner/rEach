# Platform smoke

`run.rb` installs Reach from the checkout's HEAD into a scratch directory whose path contains a space, starts the fixture Teach (`tools/fake_teach/server.rb`), and runs Reach's own commands and its harness hook command lines against it. It starts no agent session and needs no secret. It uses only the Ruby standard library and runs on Ruby 2.6.10 through 4.0.x on Linux, macOS and Windows.

    ruby tools/platform_smoke/run.rb [--skip-runtime] [--report PATH] [--keep]

Every step prints `PASS <step> <detail>`, `FAIL <step> <detail>` or `SKIP <step> <reason>`, then `platform smoke: N passed, M failed, K skipped`. The exit status is 0 only when no step failed. `--report` also writes a JSON report (`reach.platform-smoke/v1`) with the platform, Ruby version, OS version and each step's name, result, detail and duration. `--keep` leaves the scratch directory in place.

The fixture Teach needs the `webrick` gem, which Ruby 3.0 and later no longer bundle. When `require "webrick"` fails, the script runs `gem install --no-document --install-dir <scratch>/gems webrick` (one attempt and one retry, each with a timeout) and starts the fixture with `GEM_PATH` including that directory and `GEM_HOME` unset. The outcome is part of the fake_teach step detail, so the machine needs network access to rubygems.org in that case.

The script starts from a copy of the environment with every `TEACH_*` and `REACH_*` variable removed, sets `REACH_HOME` to the scratch home and `REACH_UPDATE_DISABLE=1`, and never touches the real `~/.reach`. The scratch root sits directly under the system temp directory with a short name, because Chrome cannot start when its socket path is long. Set no long `TMPDIR` when you run it.

## Steps

| Step | What it proves |
| --- | --- |
| install | `bin/reach-install --archive` of a `git archive` of HEAD installs the same VERSION and an `exe/reach` |
| fake_teach | the fixture answers `GET /api/v1/health` with 200 |
| hook_session_start | the SessionStart command from the installed `hooks/hooks.json` exits 0 |
| hook_prompt_locked | the UserPromptSubmit gate blocks before enrollment: exit 2, a message on stderr, nothing on stdout |
| hook_codex | the same block through the command from `hooks/codex.json` |
| enroll | `reach enroll` against the fixture connects the student to the course |
| machine_id | `Reach::Fingerprint.machine_id` is not `unknown` and has the platform's form |
| hook_prompt_open | the same gate command exits 0 and does not block once enrolled |
| status | `reach status` names the enrolled student and does not report `fingerprint_mismatch` |
| runtime | `reach runtime install` and `status` show the pinned runtime and its Ruby 4.0.7; on a platform with no kit the unsupported message is the pass |
| doctor | runs after runtime so it sees the runtime Chrome; every finding code `reach doctor` prints is in `EXPECTED_DOCTOR_FINDINGS` |

Hook commands run through `sh -c` on Linux and macOS and through Git for Windows' `bash.exe` (found next to `git.exe`, never WSL's) on Windows.

## Expected doctor findings

`EXPECTED_DOCTOR_FINDINGS` in `run.rb` holds only findings caused by the fixture Teach.

| Code | Reason |
| --- | --- |
| R-DOC-GUARD | the fixture releases no guardrails package, so `reach sync` has nothing to verify and the guardrails package never becomes the latest known |

| R-DOC-HARNESS | the smoke installs no agent harness by design (commands-only smoke) |

`R-DOC-CHROME` is expected only when the runtime step did not install a kit: with `--skip-runtime`, or on a platform outside `Reach::RuntimeKit::PLATFORMS` such as Windows arm64. When a kit was installed, doctor must find the runtime's Chrome (`check_chrome` reads `chrome_exe` from the active runtime) and the finding fails the step.

Any other finding fails the step and is printed in full.

## Windows VM runners

`windows-runner/bootstrap.ps1` prepares a fresh Windows 10 or 11 VM once, from an elevated Windows PowerShell 5.1: OpenSSH Server with a firewall rule for port 22 and PowerShell as the default SSH shell, Git for Windows 2.56.0 (Git Bash included), RubyInstaller 4.0.7-1 x64 for all users with its bin directory on the machine PATH, and the GitHub Actions runner 2.337.0 for win-x64 in `C:\actions-runner`. Each download is checked against a pinned SHA-256 and retried up to three times.

`windows-runner/register.ps1 -Url <repository url> -Token <registration token> -Label win10|win11 -Name <runner name>` registers the runner as a service. The token is passed at run time and never written to disk.
