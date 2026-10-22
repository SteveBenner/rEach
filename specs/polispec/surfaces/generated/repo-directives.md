# Repo directives

Generated from specs/polispec/behavior.yml. Edit the source, never this file.

# INSTALL: installing rEach for someone

rplugin is optional: reach runs from a harness's own plugin copy (Claude Code, Claude Cowork, Codex or Antigravity installing this repository directly, see `INSTALL.md`), and `rplugin install reach` is one of several ways in. When rplugin is used, it is installed with `~/.rplugin/bin/rplugin install reach` and checked with `~/.rplugin/bin/rplugin doctor reach`, which must report zero findings. Read rplugin's own `~/.rplugin/AGENTS.md` for installing, configuring and troubleshooting any plugin.

# RPLUGIN: what reach is and where its sources live

reach is a plugin built on rplugin, the SDK for agent-harness plugins.

What reach does, the credentials it needs and its settings in `config.yml` are described in `README.md`.

Its skills are `skills/reach-course`, `skills/reach-feature`, `skills/reach-bug` (with `skills/reach-build` and `skills/reach-fix` routing to them), `skills/reach-checkpoint`, `skills/reach-submit`, `skills/reach-help` and the vendored `skills/design-taste-frontend`; its command, when installed, is `reach` on the user's `PATH`. The full design is `reach.spec.yml` at the repo root.

`specs/polispec/behavior.yml` owns the public engineering directives, the runtime policy parameters and every generated surface. `policy/behavior.json` is compiled data, and `directives/*.md` and the surfaces under `specs/polispec/surfaces/generated/` are generated views. Edit the source, run `ruby tools/policy.rb build` with Polispec available, then `ruby tools/policy.rb check`. Do not hand-edit the views. Course directives remain Teach-owned and arrive in the existing authenticated guardrails package as `course_policy.json` beside the legacy `directives.yml`; private bodies stay in protected retrieval.

Development policy and persona routing are in `specs/polispec/policy.yml` and `roster.yml`. They take effect through the host's trusted ledger, separately from student runtime policy. Stable moves only when the operator runs `polispec promote reach --to stable`; the agent never runs that operator action.

# CORPUS: the corpus is not a folder to edit

If it owns a corpus, rplugin created it for the plugin. Read and write it only through the plugin or `rcorpus`, never by editing its files.

# COURSEMAT: no course material in this repository

This repository carries no course material, encrypted or not. Course reference blobs reach an install only from Teach, as `reference/<name>.rref` entries in the encrypted guardrails package, and `reach reference` reads them from the vault. reach-course wires them in as grounding material only, never as a source of answers.

# KNOWNISSUE: known issues are not TODO.md

Known issues are not `TODO.md`. A known issue is a problem students hit, with its workaround, kept in Teach (on its console's Issues page) and shown to students' agents through `reach known-issues`; reach only reads them. `TODO.md` is this repository's code backlog. Never write a known issue or its status into `TODO.md`, and never treat a `TODO.md` item as a known issue; an unbuilt fix for a known issue may be a `TODO.md` item that names the issue id.

# CHANGEIT: changing reach

The manifest is `reach.rplugin.yml` (schema `rplugin/v1`, `~/.rplugin/specs/plugin.yml`). `VERSION`, the manifest's `version` and `.codex-plugin/plugin.json` must agree.

Code reaches every capability (secrets, events, state, registry, schedule, corpus) through `Rplugin::Ports.for("reach", root: <plugin root>)`. Never call a host's service or read its files directly, and never copy rplugin's runtime or catalogue into this plugin.

Before calling a change done, run `rplugin check reach`, `rplugin install reach` and `rplugin doctor reach`, all at zero findings, and run the plugin for real.

Guide: `~/.rplugin/docs/guides/writing-a-plugin.md`.

