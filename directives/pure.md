---
alias: C
enforce: check:CK-PURE
id: R-PURE
opcode: PURE
rule: 'a behaviour is a pure function of input and ports: no I/O, clock, randomness
  or globals'
slice: backend
tier: public
when:
- path:**/*.rb
---
# PURE: the same input always gives the same output

A behaviour receives `input` and `ports` and returns a hash. That is its
whole world. The instructors' suite runs it with a frozen clock and fixture
data on ten different computers and expects the identical answer every time,
and the shell reruns it whenever a record changes. Anything that reaches
outside breaks both.

Never use, in any owned `.rb` file:

- `File`, `IO`, `Dir`, `open`, backticks, `system`, `spawn`, `exec`
- `Net::`, `Socket`, `URI.open`, anything that talks to a network
- `ENV`, `ARGV`, `$stdin`, `$stdout`, `puts`, `print`, `p`, `warn`
- `Time.now`, `Date.today`, `Process.clock_gettime`: a date or time is an
  input, or it comes from a port
- `rand`, `Random`, `SecureRandom`: an identifier is an input, or it comes
  from a port
- `sleep`, `Thread`, `Process`, `at_exit`, `trap`
- global variables (`$x`), class variables (`@@x`), constants that hold state,
  instance variables that survive between calls
- `eval`, `send`, `define_method`, `alias_method`, `instance_variable_set`,
  or reopening `String`, `Hash`, `Array`, `Integer`, `Float`, `Object`,
  `Kernel` or `Module`

Everything the behaviour needs beyond `input` comes through the ports the
slice was granted (`api/README.md`). When a port says something is
unavailable, return the status the contract prescribes; never retry, wait or
work around it.

`reach check` names every violation with the line. There is no exception
for "just this once".
