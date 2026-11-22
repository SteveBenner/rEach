# Smoke tests

`polispec smoke record` writes this file; edit nothing by hand.

| Subject | Verdict | Recorded | ID | Summary |
| --- | --- | --- | --- | --- |
| enroll-email-extract | pass | 2026-11-22T07:52:00Z | smk_400e637b824a | On test (rEach 0.80.1, ac356e25) Reach::Identity.normalize_username from the test checkout took the one address out o... |

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
```
