# Smoke tests

`polispec smoke record` writes this file; edit nothing by hand.

| Subject | Verdict | Recorded | ID | Summary |
| --- | --- | --- | --- | --- |
| enroll-email-extract | pass | 2026-11-22T07:52:00Z | smk_400e637b824a | On test (rEach 0.80.1, ac356e25) Reach::Identity.normalize_username from the test checkout took the one address out o... |
| local-run-cause | pass | 2026-11-22T10:07:46Z | smk_923c6ee7ef23 | On test (rEach 0.80.2, 2655d9b1, run from a git archive of the promoted tag) a local Cucumber run with no report name... |
| gate-path-lookups | pass | 2026-11-22T11:01:26Z | smk_1f8495cdbc84 | rEach 0.80.3 (f1992045, on test) through the real reach gate hook in a scratch enrolled home: realpath and PowerShell... |
| consent-latest-question | pass | 2026-11-22T11:49:58Z | smk_a8252f76c7ee | rEach 0.80.4 (b8464db9, on test) through Reach::Consent in a scratch enrolled home: a later plain yes to an unrelated... |
| part-answers-any-course | pass | 2026-11-22T12:00:26Z | smk_46119bd778ff | rEach 0.80.5 (88d48482, on test) through Reach::Part in a scratch enrolled home: with no current slice for the assign... |

## Ledger

```yaml
schema: polispec.smoke/v1
entries:
- id: smk_400e637b824a
  recorded_at: '2026-11-22T07:52:00Z'
  proves:
    feature: enroll-email-extract
  verdict: pass
  summary: On test (rEach 0.80.1, ac356e25) Reach::Identity.normalize_username from
    the test checkout took the one address out of 12 decorated inputs (trailing period,
    sentence, quotes, angle brackets, NBSP, zero-width space, markdown mail link,
    bold, mailto:, full-width @) and refused 5 (other domain, subdomain, two addresses,
    local part outside the pattern, 300 characters). Not run through a live enrollment
    against Teach.
  steps: []
  evidence:
  - path: ".scratch/smoke/enroll-email-extract/run.txt"
    sha256: 5efabec0ba0ded951d53b8c3f32edc4480ae61a3b253e8cbf907bbbd6566a865
    bytes: 1026
    kind: log
  runner:
    kind: agent
    harness: claude-code
    harness_version: 2.1.330
    model: claude-opus-5-5
    effort:
  runtime:
    os:
      id: ubuntu
      name: Ubuntu
      version: '26.04'
    kernel: 7.0.0-42-generic
    arch: x86_64
    platform: x86_64-linux
    container: false
    wsl: false
    tz: PST
    locale: en_US.UTF-8
    ruby:
      engine: ruby
      version: 4.0.6
      platform: x86_64-linux
    polispec:
      version: 0.59.1
      edition: standard
      commit: d33cbc1f4d71ecc0bef13c925eb361febbb9a38a
      dirty: false
      install: pinned
    rplugin: 1.20.1
    enforce: enforce
  target:
    commit: ac356e256ed2760309aca47f0b1175405779e01c
    branch: main
    dirty: false
    project: reach
    env: dev
    policy_digest: sha256:90f7b8ae98bbe4c1edd2466ebdde5b0f511b746e10d4263c5c5d02403be846e8
  prev:
  digest: 6e2c5e970113eaaf360b1f3935aea2142f8c1b425d123b5e442adbf4734d55fc
- id: smk_923c6ee7ef23
  recorded_at: '2026-11-22T10:07:46Z'
  proves:
    feature: local-run-cause
  verdict: pass
  summary: 'On test (rEach 0.80.2, 2655d9b1, run from a git archive of the promoted
    tag) a local Cucumber run with no report names its cause: exit status plus a scrubbed
    stderr tail for a crash, a timeout as a timeout; one fault event per cause (passes:local_run).
    Unproven: a real Windows kit run.'
  steps:
  - run: 'ruby3.3 drive.rb from a git archive of v0.80.2 (= origin/test 2655d9b1),
      fake HOME and REACH_HOME: Passes.run_rows on a Gemfile naming a missing gem'
    exit: 0
    expect: hard zero names the exit status and the bundler error; one no_report fault
      with the exception class
    observed: 'exit status 1 and the bundler ''failed to load command: cucumber ...
      Could not find gem'' lines; fault passes:local_run cause no_report error Bundler::GemNotFound
      reach_version 0.80.2'
  - run: same, a cucumber on PATH that prints a LoadError under the home and exits
      1
    exit: 0
    expect: stderr tail shown with the home as ~; no second fault for the same cause
    observed: "'~/reach-work/vault/x.rb:3:in require: cannot load such file -- grokit/advisor
      (LoadError)'; no extra fault event"
  - run: same, a cucumber that sleeps 30 s with RUN_TIMEOUT_S set to 3
    exit: 0
    expect: named as a timeout; one timeout fault
    observed: "'the local run took longer than 3 seconds and was stopped'; fault cause
      timeout"
  evidence:
  - path: out-test.txt
    sha256: 139c1c9c96bfacd8adc1f077f26ef036f57957048fb95dbe79f3c1cda3efb323
    bytes: 810
    kind: file
  runner:
    kind: agent
    harness: claude-code
    harness_version: 2.1.330
    model:
    effort:
  runtime:
    os:
      id: ubuntu
      name: Ubuntu
      version: '26.04'
    kernel: 7.0.0-42-generic
    arch: x86_64
    platform: x86_64-linux
    container: false
    wsl: false
    tz: PST
    locale: en_US.UTF-8
    ruby:
      engine: ruby
      version: 4.0.6
      platform: x86_64-linux
    polispec:
      version: 0.59.1
      edition: standard
      commit: d33cbc1f4d71ecc0bef13c925eb361febbb9a38a
      dirty: false
      install: pinned
    rplugin: 1.20.1
    enforce: enforce
  target:
    commit: 2655d9b102cf511c581f6d40c91791a75f48dca5
    branch: main
    dirty: false
    project: reach
    env: dev
    policy_digest: sha256:90f7b8ae98bbe4c1edd2466ebdde5b0f511b746e10d4263c5c5d02403be846e8
  prev: 6e2c5e970113eaaf360b1f3935aea2142f8c1b425d123b5e442adbf4734d55fc
  digest: 2cb6e7c88a8e818ee99d9dbdf153de8e48fe0bf902813dd8419ed5217a270c35
- id: smk_1f8495cdbc84
  recorded_at: '2026-11-22T11:01:26Z'
  proves:
    feature: gate-path-lookups
  verdict: pass
  summary: 'rEach 0.80.3 (f1992045, on test) through the real reach gate hook in a
    scratch enrolled home: realpath and PowerShell Get-Item and Resolve-Path of the
    student''s own files now pass from the slice and the course root under Claude
    Code and Codex, a root write answers M-WRITE-ROOT with the cd route, and every
    outside lookup, outside read and outside or non-owned write stays refused. Unproven:
    a Windows or macOS host, and real students'' sessions.'
  steps:
  - run: ruby exe/reach gate shell --harness claude-code with Bash realpath <slice>
      from the slice and from the course root, in a scratch enrolled REACH_HOME (f1992045)
    exit: 0
    expect: the lookup of the student's own slice is allowed in both folders
    observed: allow in both; before the fix the course-root run was M-SHELL-BLOCKED
      at gate.rb:1208
  - run: reach gate shell for PowerShell Get-Item and Resolve-Path of the slice README,
      claude-code PowerShell tool and codex (tool and powershell.exe -Command wrapper),
      from slice and root
    exit: 0
    expect: allowed; (Get-Item .).FullName still refused
    observed: all Get-Item and Resolve-Path rows allow; (Get-Item .).FullName M-SHELL-UNMODELED
      in every row
  - run: reach gate shell Set-Content <slice file> x and touch of a slice file from
      the course root
    exit: 2
    expect: still refused, now with M-WRITE-ROOT naming the cd route
    observed: M-WRITE-ROOT for both; from the slice Set-Content of the owned file
      is allowed
  - run: 'controls: realpath, readlink -f, Resolve-Path, Get-Item and gi of paths
      outside the course; Write, Read, cat, Get-Content and Set-Content outside the
      slice or course; Write to a non-owned slice file'
    exit: 2
    expect: every control refused
    observed: M-GATE-OUTSIDE for every outside lookup and read, M-WRITE-OUTSIDE or
      M-WRITE-ROOT for the writes
  evidence:
  - path: ".scratch/smoke/0.80.3/after-case2.out"
    sha256: 70f5f103271b7e5f3bffc27b4391cf0f6180a6a7e305f3747468e97be56c3170
    bytes: 8934
    kind: file
  - path: ".scratch/smoke/0.80.3/after-case3.out"
    sha256: ddbb53242399ae5e5b984d64e2197b47f1991bb8601f82f99df16df41be3756a
    bytes: 8996
    kind: file
  - path: ".scratch/smoke/0.80.3/after-case5.out"
    sha256: '01752558cc0797ee94ec2abc0e8e13d969832984c9ba64a836e96b4b4d572f15'
    bytes: 9225
    kind: file
  - path: ".scratch/smoke/0.80.3/after-case6.out"
    sha256: 7974466f0c82fe10ecb3d5f81694e10885158833584687975d04128725a58c4d
    bytes: 5858
    kind: file
  - path: ".scratch/smoke/0.80.3/drive.rb"
    sha256: ae329fbc240c31560926fbb0b2ac7b697ae1c6f5d933d62b6a36b2cd8375ae6c
    bytes: 1588
    kind: file
  runner:
    kind: agent
    harness: claude
    harness_version:
    model: claude-opus-5-5
    effort:
  runtime:
    os:
      id: ubuntu
      name: Ubuntu
      version: '26.04'
    kernel: 7.0.0-42-generic
    arch: x86_64
    platform: x86_64-linux
    container: false
    wsl: false
    tz: PST
    locale: en_US.UTF-8
    ruby:
      engine: ruby
      version: 4.0.6
      platform: x86_64-linux
    polispec:
      version: 0.59.1
      edition: standard
      commit: d33cbc1f4d71ecc0bef13c925eb361febbb9a38a
      dirty: false
      install: pinned
    rplugin: 1.20.1
    enforce: enforce
  target:
    commit: f19920450b6e57df378f5cc17d788c1eda9f38fb
    branch: fix/slice-path-lookup
    dirty: false
    project: reach
    env: dev
    policy_digest: sha256:90f7b8ae98bbe4c1edd2466ebdde5b0f511b746e10d4263c5c5d02403be846e8
  prev: 2cb6e7c88a8e818ee99d9dbdf153de8e48fe0bf902813dd8419ed5217a270c35
  digest: b9b3e8ecdbb5e17c187008336930553d9d365b65b679afd5fe66bb98965709c9
- id: smk_a8252f76c7ee
  recorded_at: '2026-11-22T11:49:58Z'
  proves:
    feature: consent-latest-question
  verdict: pass
  summary: 'rEach 0.80.4 (b8464db9, on test) through Reach::Consent in a scratch enrolled
    home: a later plain yes to an unrelated question no longer authorizes a partial
    submission the student declined in a sentence, with a transcript, recorded replies
    only, or recorded prompts, while a yes right after the question still authorizes
    and a bare no still declines; on 0.80.2 the same sequence authorized it. Unproven:
    a live harness session through the prompt hook.'
  steps:
  - run: Reach::Consent.ask! for submission_partial, then capture of a decline written
      as a sentence starting with no, then capture of a plain yes after an unrelated
      plan question, then take!; at 7e6c3311 (0.80.2 main checkout) and at b8464db9
      (0.80.4), with a transcript, recorded replies only, and recorded prompts
    exit: 0
    expect: 'before: the later yes authorizes the partial submission; after: the sentence
      declines and nothing authorizes it'
    observed: 0.80.2 authorized=true in all three modes; 0.80.4 the sentence is captured
      as no and authorized=false in all three modes
  - run: the same with no first answer, then a plain yes after an unrelated plan question
    exit: 0
    expect: not authorized
    observed: 0.80.2 authorized=true; 0.80.4 authorized=false in all three modes
  - run: 'controls: yes right after the question, and a bare no then a later yes'
    exit: 0
    expect: yes right after the question authorizes; bare no declines
    observed: authorized=true and authorized=false respectively, in all three modes,
      before and after
  - run: Reach::Consent.no? and decline? on a written answer that starts with No,
      a bare no, Yes and a sentence starting with don't
    exit: 0
    expect: no? unchanged for the part recorder; decline? true for the sentences
    observed: no? true only for the bare no; decline? true for all three no-led texts;
      yes? true only for Yes
  evidence:
  - path: ".scratch/smoke/0.80.4/consent-after.out"
    sha256: 5daf3bff51c38387fa406d68409b0d58e8abd64499be58b06d1fb42ed1ce9411
    bytes: 1539
    kind: file
  - path: ".scratch/smoke/0.80.4/consent_drive2.rb"
    sha256: ab3dc534e013ffb0e7518425f90706fbc8ce0807134a9746e432a82a7151aef0
    bytes: 2955
    kind: file
  runner:
    kind: agent
    harness: claude
    harness_version:
    model: claude-opus-5-5
    effort:
  runtime:
    os:
      id: ubuntu
      name: Ubuntu
      version: '26.04'
    kernel: 7.0.0-42-generic
    arch: x86_64
    platform: x86_64-linux
    container: false
    wsl: false
    tz: PST
    locale: en_US.UTF-8
    ruby:
      engine: ruby
      version: 4.0.6
      platform: x86_64-linux
    polispec:
      version: 0.59.1
      edition: standard
      commit: d33cbc1f4d71ecc0bef13c925eb361febbb9a38a
      dirty: false
      install: pinned
    rplugin: 1.20.1
    enforce: enforce
  target:
    commit: b8464db9278e1c7e1739161ff85ba308369373fc
    branch: fix/slice-path-lookup
    dirty: false
    project: reach
    env: dev
    policy_digest: sha256:90f7b8ae98bbe4c1edd2466ebdde5b0f511b746e10d4263c5c5d02403be846e8
  prev: b9b3e8ecdbb5e17c187008336930553d9d365b65b679afd5fe66bb98965709c9
  digest: 3a216bcfb1915c38e5feb957caa841e361b593b33196e1bee3ae0f4cafa92b22
- id: smk_46119bd778ff
  recorded_at: '2026-11-22T12:00:26Z'
  proves:
    feature: part-answers-any-course
  verdict: pass
  summary: 'rEach 0.80.5 (88d48482, on test) through Reach::Part in a scratch enrolled
    home: with no current slice for the assignment and an install course id that differs
    from the course the answer was recorded under, the student''s recorded answer
    now reads as answered (0.80.2 read none), while another student''s answer, another
    assignment''s file and a file whose recorded assignment differs stay out. Unproven:
    a student''s real state, and reach submit end to end.'
  steps:
  - run: Reach::Part.stored_answers(A9) in a scratch enrolled home whose install course
      id is CRS101 and which has no current slice for A9, with the student's answer
      q1 in SLICECOURSE-A9.json, another student's answer q2 in the same file, an
      A99 file and a file named for A9 whose recorded assignment is B9; at 7e6c3311
      (0.80.2) and 88d48482 (0.80.5)
    exit: 0
    expect: 'before: no answers; after: only the student''s own q1'
    observed: 0.80.2 keys []; 0.80.5 keys ["q1"]
  evidence:
  - path: ".scratch/smoke/0.80.5/part-after.out"
    sha256: d5563985dd4e75e0881cc0fdf5a26bcd94be0ea8542e299f62477787bc3b5738
    bytes: 189
    kind: file
  - path: ".scratch/smoke/0.80.5/part_drive.rb"
    sha256: a77f8c9b9b9490e2af7bae56a7054f9b3898a9d54709e0ab739cf6194bc211af
    bytes: 1371
    kind: file
  runner:
    kind: agent
    harness: claude
    harness_version:
    model: claude-opus-5-5
    effort:
  runtime:
    os:
      id: ubuntu
      name: Ubuntu
      version: '26.04'
    kernel: 7.0.0-42-generic
    arch: x86_64
    platform: x86_64-linux
    container: false
    wsl: false
    tz: PST
    locale: en_US.UTF-8
    ruby:
      engine: ruby
      version: 4.0.6
      platform: x86_64-linux
    polispec:
      version: 0.59.1
      edition: standard
      commit: d33cbc1f4d71ecc0bef13c925eb361febbb9a38a
      dirty: false
      install: pinned
    rplugin: 1.20.1
    enforce: enforce
  target:
    commit: 88d48482944b527efc528b5a584998baf38dd783
    branch: fix/slice-path-lookup
    dirty: false
    project: reach
    env: dev
    policy_digest: sha256:90f7b8ae98bbe4c1edd2466ebdde5b0f511b746e10d4263c5c5d02403be846e8
  prev: 3a216bcfb1915c38e5feb957caa841e361b593b33196e1bee3ae0f4cafa92b22
  digest: d6179da3b2b0c16cf9e4dc2527151fcf09348deb96597ebea15f14ef4d1f0874
```
