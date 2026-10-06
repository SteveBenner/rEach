# rEach design decisions

The standing decisions behind rEach, as the product owner gave them. Only the latest form of each decision is kept;
when one is revised, its entry is rewritten rather than appended. Dates are 2026. Where a decision constrains Teach,
Grokit or Dovetail, it is listed here only for its effect on rEach. The system these decisions produced is drawn in
[`architecture.md`](architecture.md).

## Purpose and how rEach talks to students

- **Coding is abstracted away from the student entirely** (09-29). Students work with business, software, process,
  people and data concepts from the syllabus. Inside a slice rEach never talks code with them; the AI partner writes
  100% of the code and guides the student as it goes.
- **Guide, never hand over answers** (09-25). The tutor leads students to the solution instead of giving direct
  answers, and does not do the student's thinking for them.
- **No tips** (09-29). rEach gives no tips; the agent guides the student through the work itself.
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
- **Four inputs** (10-02): the class-wide course passkey handed out in class or on the course's learning system, the
  institutional email, the institutional student ID, and a password the student chooses (at least 8 characters, typed
  twice). Teach owns the roster they are checked against and keeps only a hash of the password.
- **A course passkey links to exactly one course** (10-01), is class-wide, expires when the course ends, and is
  normalized loosely ("bus-101" and "bus 101" both resolve).
- **Instructor unlock** (10-01). An instructor can lift the enrollment lock on one install with a signed code,
  minted, revoked and rotated on the Teach console and checked against the instructor keyring Teach publishes. The
  code is pasted into the locked prompt, which the hook intercepts so the agent never sees it, or given to
  `reach instructor unlock` in a terminal. An unlocked, unenrolled install allows prompts without guardrails and
  captures nothing.
- **Machine fingerprint** (10-01). After enrollment rEach keeps a stamp of machine, harness and account that must
  match Teach's.
- **Sign-in each session** (09-30): the student ID, then "Am I speaking with <name>?", then the student's password,
  enforced by hooks.

## Data capture and privacy

- **The record is whole and sent in the background** (10-04). Inside the same bounds as below, rEach also records
  what each tool returned to the AI and each subagent's work, splits a long text across entries instead of cutting it,
  and sends on a timer the course sets in Teach (600 s by default) from the open session and the background job, so
  instructors do not wait for a turn end or a submission.
- **Signed-in assignment work is recorded** (10-03). While a session is signed in, the
  course has a current assignment and the session runs in a slice or the course folder root, rEach records every
  prompt, the AI's replies, reasoning and actions, and the assignment code, and sends them to Teach, where the
  instructors read them. Nothing is recorded before sign-in, in the extracurricular folder, outside the course folder
  or in instructor mode, and recording never reaches back before a session's first recorded prompt. The microbrain is
  separate: it stays on the student's computer and is never sent. Students learn this from the docs, the privacy
  policy and their AI partner's answer when they ask; there is no in-session notice. The student can export their own
  copy (`reach transcripts export`). The record leaves the computer
  de-identified: a random pseudonym, placeholders for the identifiers rEach knows, and an identity index only the
  holder of the course's key can open.
- **What reaches Teach** (10-03). rEach does not capture the student's local workspace material, all
  the more because students are encouraged to import their personal contexts. Only these go to the instructors:
  - completed work and assignment material (the slice's owned files and submissions);
  - material the student explicitly approves or names to be sent, including their own-part answers;
  - metadata, analytics and usage data.
  - the recorded conversation of signed-in assignment work (10-03; see above).
- **Extracurricular files stay on the student's computer** (10-01). They are never scanned, mirrored
  or sent. Teach's rule G-EXTRA-2 and rEach's own notices say so.
- **Analytics are tied to the enrollment** (10-01). Usage analytics are identified by the enrolled student ID (see
  TODO.md).
- **The brain stays local and learns from everything the student types** (10-02).
  rEach keeps a private microbrain on the student's computer: every prompt the student types that the gate allows,
  in any folder, becomes a private source as it arrives; the agent distils durable findings about the student and
  their work with `reach remember`; and rEach injects a profile at session start and matching memories on each prompt.
  Prompts the gate blocks (login, enrollment, passwords) never enter it. Nothing in it is sent to Teach; events carry
  ids and counts only; the student can ask what is remembered and have it forgotten, which scrubs rEach's own spool.
- **Fault reports carry no content** (10-02). When rEach shows a plain message in place of an error, or the Teach connection
  changes, it records a fault or link event and sends it to Teach even while debug mode is off: where it happened, the
  exception class, the errno name, a few plugin-relative frames and the id of what the person was shown, never the
  error message, a prompt, a reply or a file. At most 60 an hour are kept and the rest are counted.
- **The interview profile stays local** in the profile file and reaches instructors only if the student agrees when
  asking for help.
- **No test data or answers in a workspace** (09-30). rEach refuses test data; Teach does not provision fixtures.

## Course material

- **No course material in this repository** (10-01). rEach pulls course material from Teach.
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
- **A sandboxed install that cannot leave the sandbox** (10-01). The install needs the network and
  writes outside the chat's folder, so it runs outside the sandbox once. If the agent cannot ask for that (Codex on
  Windows), it tells the student to switch the chat's permissions to Full access and ask again. It never improvises
  another folder or workaround, and never asks the student to paste commands.
- **Migration loses nothing** (10-01). Moving an existing install into `~/reach-work/.reach-home` must have zero chance of losing
  student data: copy and verify before anything is removed, keep the old location until the new one is proven, and
  resume or roll back cleanly if interrupted.
- **Inside reach-work** (10-03). rEach's own files live in
  `~/reach-work/.reach-home`; the workspace stays where it is, so a student has one folder to open in the harness and no
  second one to find. The home is refused in every kind of space (reads, writes, listings, searches, redirects, cds)
  and pruned from every walk of the student's work, so the student's agent cannot read keys or the stamp and a
  submission never carries the home. A root-kind session judges writes by their target slice and asks which slice when
  it cannot choose. Existing installs relocate by copy, hash verification and rename; the earlier location is left
  untouched apart from `RELOCATED.json`, because losing student data has no acceptable odds.
- **rEach edits the student's own Codex settings** (10-03). Codex reads its sandbox keys from the user-level
  `$CODEX_HOME/config.toml`, so rEach writes the few keys it needs there, from outside the sandbox and only after the student's yes, keeps a backup beside the file and puts the
  keys back when they were removed. It refuses rather than guess, because a second definition of a key stops Codex
  from starting. Windows defaults to turning the sandbox off, because Codex's writable roots are not reliable on Windows. rEach never writes Codex hook trust.

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
