# fake_teach

A local development fixture of the Teach half of enrollment v2 (specs/wire.yml, revision 2026-10-01b). It is not Teach: it serves only health, enrollment preview, enroll shape v2, an install-signed status and, since rEach 0.17.0, submissions and, since rEach 0.19.0, hands and grades, and answers every other route 404 not_found. It carries no assertions and is not a test suite.

It serves wire revision 2026-10-01b only and is superseded by Teach 0.16.0 for anything newer (device moves, per-course codes, the roster).

## Start

    ruby tools/fake_teach/server.rb [--port 9480] [--home DIR]

It binds 127.0.0.1 only. State lives under `--home` (default a fresh temporary directory): `installs.json` and `keys/` (an RSA-4096 signing key `fake-sign-1` and encryption key `fake-enc-1`, generated on first start and reused when `--home` is reused). Nothing is written outside `--home`. Stop it with SIGTERM or Ctrl-C.

## Behaviour

- `GET /api/v1/health`
- `GET /api/v1/enrollment/preview?course_code=...`: course, expires_at, identity rules.
- `POST /api/v1/enroll` shape v2 only (shape v1 answers 400 invalid_request). Checks reach_version against minimum 0.12.0, resolves the code (W-ENR-1: secret lookup, course id within Damerau-Levenshtein distance 2, did_you_mean), finds the roster entry matching both username and student_id, and answers with a signed W-ENR-5 stamp. Enroll and preview share a limit of 30 per minute per IP (429 with Retry-After).
- `GET /api/v1/status` verifies the W-AUTH request signature against the stored install key, compares X-Reach-Fingerprint with the stored digest (403 fingerprint_mismatch) and answers a minimal body with no slices and no packages.
- `wire_contract_sha256` is the SHA-256 of specs/wire.yml in this checkout.
- `POST /api/v1/submissions` (since rEach 0.17.0, W-SUB-1) verifies the install signature, honours Idempotency-Key, numbers attempts per student, cutout, slice and assignment, and answers a signed ingest receipt carrying `attempt` with `due` and `resubmit`. `FAKE_TEACH_DUE` (a W-CONV-3 time) sets the due time, also shown as `current_assignment` in status; after it, a slice already on record answers 403 deadline_passed. The package is not opened or checked.

- `POST /api/v1/hands` and `GET /api/v1/hands/:id` (since rEach 0.19.0, W-HAND-TYPES) verify the install signature, honour Idempotency-Key and record each hand (student, cutout, slice, trigger, originator, summary) in `hands.jsonl` under `--home`. Every trigger of specs/wire.yml is accepted; `FAKE_TEACH_HANDS_LEGACY=1` accepts only attempt_gate, attempt_ladder, student_request, check_gate and wellbeing and answers 400 invalid_request to the rest, like a Teach that predates revision 2026-10-02e; `FAKE_TEACH_HANDS_DISABLE=1` answers 403 hands_disabled. The reply is always state open with no reply.
- `GET /api/v1/grades` (since rEach 0.19.0, W-API-GRADES) answers from `grades.json` under `--home`, read on every request: `{"mode": "404"}` answers 404 not_found, `{"mode": "disabled"}` answers 403 grades_disabled, and `{"grades": [{"student_id", "assignment", "points", "points_possible", "recorded_at"}]}` answers the rows of the asking install's student (a row without student_id is for everyone) with their total; no file or no rows answers available false.
- `FAKE_TEACH_DELAY_S` (seconds, fractions allowed) delays every response by that long before it is routed, to act as a slow Teach.
- `FAKE_TEACH_WIRE_SHA` overrides the advertised `wire_contract_sha256`, to act as a Teach on another wire revision.
- Every request is appended to `requests.jsonl` under `--home` (method, path, status, time); no body, header or key is logged.

## Fixtures

Courses (`fixtures/courses.yml`):

| Course | Code | Ends | State |
| --- | --- | --- | --- |
| MGMT327 | MGMT327-K7QX-94TD | 2026-12-18 | live |
| ACCT201 | ACCT201-2M8R-QW3Z | 2026-06-01 | ended (course_code_expired) |

Identity rules: institution La Sierra, domain lasierra.edu, username `^[a-z]{4}[0-9]{3}$`, student id `^[0-9]{7}$`.

MGMT327 roster (`fixtures/roster.yml`, fictional people):

| Username | Student id | Name |
| --- | --- | --- |
| mdel101@lasierra.edu | 1040217 | Maria Delgado |
| joka204@lasierra.edu | 1040358 | James Okafor |
| pram317@lasierra.edu | 1040471 | Priya Raman |
| hwhi418@lasierra.edu | 1040592 | Hannah Whitfield |
| tbre529@lasierra.edu | 1040634 | Tomas Brennan |

## Point Reach at it

    export REACH_HOME="$(mktemp -d)"
    export REACH_TEACH_URL=http://127.0.0.1:9480
    ruby exe/reach enroll --course-code MGMT327-K7QX-94TD --username mdel101 --student-id 1040217 --password-stdin --teach-url "$REACH_TEACH_URL" <<< "choose-a-password"

The fake refuses a shape v2 enrollment whose password is missing or not 8 to 256 characters, and never stores or logs it.

Use a scratch `REACH_HOME` each time so no real install is touched.
