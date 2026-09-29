---
id: R-RUBY
opcode: RUBY
alias: B
tier: public
slice: backend
rule: "plain Ruby that runs on 2.6.10 and 4.0: one class per file, frozen literal, no gems"
when: [path:**/*.rb]
enforce: check:CK-RUBY
---
# RUBY: one dialect for every module

Your behaviour runs inside Grokit on Ruby 4.0 and inside `reach qualify` on the
student's own Ruby, which on a Mac is the built-in 2.6.10. Write the
intersection, and nothing else:

- No endless methods (`def x = 1`), no pattern matching (`case ... in`), no
  numbered block parameters (`_1`), no `it`, no hash shorthand (`{x:}`), no
  argument forwarding (`...`), no `filter_map`, no `Hash#except`.
- `require "set"` before using `Set`. Only `bigdecimal`, `date`, `json`,
  `set` and `time` may be required at all; never `require_relative`.
- Line 1 is `# frozen_string_literal: true`; line 2 is the `# reach` header
  Reach wrote. Keep both exactly as they are.
- One file, one class: `Grokit::<Module>::Behaviours::<Name>`, a plain class
  with no superclass, with `def call(input, ports)` (`_input` or `_ports` when
  the argument is unused). Nothing else at the top level.
- `snake_case` methods and variables, `CamelCase` for the class, two-space
  indentation, double-quoted strings, no trailing whitespace.
- The hash you return uses string keys exactly as `contract/README.md` names
  them; a missing value is `nil` with the status the contract prescribes,
  never an exception.
- Money is a `BigDecimal` with a currency, never a `Float`; never divide
  without checking for zero; never compare floats for equality.
- Small private methods for each step of the plan; no method longer than
  about twenty lines; no metaprogramming of any kind.

`reach check` runs `ruby -wc` and looks for every construct above. Fix what
it names before anything else.
