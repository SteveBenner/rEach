# rEach design decisions

The standing decisions behind rEach, as the product owner gave them. Only the latest form of each decision is kept;
when one is revised, its entry is rewritten rather than appended. Dates are 2026. Where a decision constrains Teach,
Grokit or Dovetail, it is listed here only for its effect on rEach.

## Purpose and how rEach talks to students

- **Coding is abstracted away from the student entirely** (09-29). Students work with business, software, process,
  people and data concepts from the syllabus. Inside a slice rEach never talks code with them; the AI partner writes
  100% of the code and guides the student as it goes.
- **Guide, never hand over answers** (09-25). The tutor leads students to the solution instead of giving direct
  answers, and does not do the student's thinking for them.
- **No tips** (09-29). Tips were removed in the autonomous-agent redesign.
- **rEach introduces itself** as soon as it is installed and whenever it comes online ("Hi, I'm rEach, your academic
  assistant! ...") (09-27).
- **Intake interview** (09-27, 09-28). A personal, curious conversation that stays relevant to the course plan and
  collects just enough to understand what is unique about the student, which feeds their chosen path. Questions ask one
  thing each, at most twelve.
- **Slices are thin microbuilds** (09-26). The work is cut into very small builds so the student carries none of the
  non-build overhead.
- **American English everywhere** (09-28, restated 09-30): enroll, enrollment, behavior, color. Hidden compatibility
  aliases such as `reach enrol` stay.

## Qualification, attempts and submission

- **The agent writes and runs its own scenarios** (09-29). They must fail on the untouched starting copy, cover every
  graded scenario name, and travel with each submission as ungraded evidence.
- **Qualification** (09-29) means: `reach check` clean, every graded scenario name covered, the agent's scenarios pass
  and fail on the stub, and the instructors' suite passes as a hidden gate (the agent sees only scenario name,
  pass/fail and a reason). Submit is refused without a current pass.
- **Attempt ladder per slice** (09-29). Attempt 1 is silent; attempts 2 and 3 tell the student in plain words why
  another pass is needed; after the third failure rEach raises a hand itself; one student yes covers attempts 4 to 10;
  at 10 rEach waits for an instructor, whose reply resets the count.
- **A raised hand is a structured object** (09-29): the failing code (owned files only), task, assignment, course,
  slice, attempt history, timestamps and metadata.
- **Embedded flows, no git yet** (09-29). Whenever the agent writes code its directives require the feature or bug
  flow. Git is refused in slices and the workspace root, allowed in extracurricular, and planned for 2.0.
- **Receipts** (09-29). rEach keeps a receipt for every submission and Teach's acknowledgment, and links it with
  Teach's own copy.
- **Asynchronous submission, no Grokit runtime** (09-26). Students never need the Grokit build; their agent builds the
  slice and submits it to Teach over the network, where it only has to pass that module's acceptance tests.
- **The student's own part is required** (09-30). Their answers are recorded verbatim from what they type, and submit
  is refused until every question is answered.
- **Module choice is locked**; a change goes through a transfer request the instructor approves (09-30).
- **Capacity guard** (09-30). Either end warns when a host is close to full (5% disk left).

## Enrollment and identity

- **Enrollment is fail-closed** (10-01). After installing, the student must enroll; until then rEach refuses all input.
- **Three inputs** (10-01): the course code handed out in class or on Blackboard, the school email, and the
  7-digit school ID. Teach owns the roster they are checked against.
- **A course code links to exactly one course** (10-01), is class-wide, expires when the course ends, and is
  normalized loosely ("bus-101" and "bus 101" both resolve).
- **Machine fingerprint** (10-01). After enrollment rEach keeps a stamp of machine, harness and account that must
  match Teach's.
- **Sign-in each session** (09-30): the student ID, then "Am I speaking with <name>?", enforced by hooks.

## Data capture and privacy

- **What reaches Teach** (10-01). rEach does not capture the student's local workspace material, all the more because
  students are encouraged to import their personal contexts. Only these go to the instructors:
  - completed work and assignment material (the slice's owned files and submissions);
  - material the student explicitly approves or names to be sent;
  - the captured conversation in course folders (prompts, replies, readable reasoning, actions, and code blocks the AI
    puts in a reply), which is the exception to the rule above;
  - metadata, analytics and usage data.
- **Extracurricular files stay on the student's computer** (10-01, Reach 0.16.12). The turn-end scan and the AI-write
  capture cover only slice workspaces; the extracurricular folder is never scanned or mirrored. Teach's rule G-EXTRA-2
  and rEach's own notices say so.
- **Analytics are tied to the enrollment** (10-01). Usage analytics are identified by the enrolled student ID (see
  TODO.md).
- **The interview profile stays local** in the profile file and reaches instructors only if the student agrees when
  asking for help.
- **No test data or answers in a workspace** (09-30). rEach refuses test data; Teach does not provision fixtures.

## Course material

- **No course material in this repository** (10-01). rEach pulls course material from Teach; the history was
  rewritten to remove what had been committed.
- **No answer keys or instructor files** (09-28) ever reach the student's corpus; only the reference material Teach
  delivers does.
- **The slice API belongs to Grokit** (09-29); rEach and Teach consume it through its spec, never a copy.

## Installation and harnesses

- **Install from a link** (09-27, 10-01). The student types nothing but "install reach for me" and the repository link;
  host-forced steps (trusting hooks in Codex, a new chat) are the only exceptions.
- **No git for the install** (09-30): the agent downloads the GitHub archive and unpacks it with Ruby.
- **Harnesses** (09-30): Codex for GPT, Claude (Claude Code, the desktop app, Cowork) for Claude, Antigravity for
  Gemini, and Hermes Agent in its own profile, on macOS, Windows and Linux. The Gemini app and DeepSeek are not
  supported.
- **A sandboxed install that cannot leave the sandbox** (10-01, Reach 0.16.12). The install needs the network and
  writes outside the chat's folder, so it runs outside the sandbox once. If the agent cannot ask for that (Codex on
  Windows), it tells the student to switch the chat's permissions to Full access and ask again. It never improvises
  another folder or workaround, and never asks the student to paste commands.
- **One rEach folder** (10-01, Reach 0.17.0). Codex on Windows lets a sandboxed command write only inside the
  chat's folder and the temp folder, so everything rEach keeps (its program, state, keys, runtime kit and the course
  folders) lives in one rEach folder, `~/rEach`, with rEach's own files in `~/rEach/.reach-home`, and the student
  opens that folder as their Codex project. Writes there are allowed inside the Windows sandbox. The aim is that after
  the install the student can switch Codex back to its default permissions; that is not proven yet (the sandbox has
  no network, and Codex ignores a project's network setting), so students keep Full access until it is.
- **Migration loses nothing** (10-01, Reach 0.17.0). Moving an existing install into the rEach folder must have zero
  chance of losing student data: copy and verify every file before switching, never delete, rename or overwrite
  anything in the old folders or anything already in the rEach folder, and resume or stop cleanly if interrupted.
  A move that would collide with a file already in `~/rEach` does not happen; the old install keeps working and
  `reach doctor` says what is in the way.

## Updates and releases

- **GitHub is canonical** (09-28): github.com/SteveBenner/rEach. Dovetail lives on GitHub too.
- **Automatic updates** (09-30). rEach checks at session start and hourly, tells the student without interrupting,
  installs when it can, and keeps a manifest so an interrupted update resumes. Course work is held only while an
  install runs.
- **Only tagged releases reach students** (10-01). An untagged patch is never offered by auto-update.
- **Smoke before tagging** a release students see (09-28), in an isolated sandbox that simulates a student install
  from the link.

## Runtime kit

- **A portable Ruby 4.0.x and a pinned Chrome for Testing** (09-29) for macOS, Linux and Windows, downloaded and
  verified once, installed in the background without asking the student.
- **The local pass predicts the Teach pass** (09-29): runtime, gem lock and Chrome match Teach's grader.

## Testing

- **Sandboxed smoke tests** (09-28) load rEach through a real agent in isolation, including the Teach handshake and
  Assignment 1.
- **Acceptance scenarios use a coffee shop** (09-29) with barista, staff, manager and owner, in Cucumber with Capybara.
