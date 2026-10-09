# Engineering directives

The source of these public directives is `specs/polispec/behavior.yml`. The Markdown files in this directory are generated readable views; their full text is preserved in the compiled runtime policy.

Edit the source, then run `ruby tools/policy.rb build` with Polispec on PATH. An explicit compiler path is accepted as the final argument. Run `ruby tools/policy.rb check` before committing. `reach doctor` and the pre-push gate report drift, missing bindings, and a changed instructor-control baseline.

Each opcode directive keeps its ID, alias, tier, slice, spaces, short rule, loading conditions, enforcement pointer, and body. Rule summaries remain limited to 88 characters. Native enforcement, declarative deny rules, and advisory guidance are labeled separately; a code binding is not a claim that every sentence is mechanically enforced.

Teach owns course directives. They reach rEach through its authenticated guardrails package; private bodies are retrieved on demand and never copied into this public repository. Instructor-controlled precedence, wellbeing, and control framing remain in the pinned `agent-control/agent-control.yml` contract.
