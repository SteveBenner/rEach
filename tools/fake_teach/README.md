# fake_teach

A local development fixture of the Teach half of enrollment v2 (specs/wire.yml, revision 2026-10-01b). It is not Teach: it serves only health, enrollment preview, enroll shape v2 and an install-signed status, and answers every other route 404 not_found. It carries no assertions and is not a test suite.

## Start

    ruby tools/fake_teach/server.rb [--port 9480] [--home DIR]

It binds 127.0.0.1 only. State lives under `--home` (default a fresh temporary directory): `installs.json` and `keys/` (an RSA-4096 signing key `fake-sign-1` and encryption key `fake-enc-1`, generated on first start and reused when `--home` is reused). Nothing is written outside `--home`. Stop it with SIGTERM or Ctrl-C.

## Behaviour

- `GET /api/v1/health`
- `GET /api/v1/enrollment/preview?course_code=...`: course, expires_at, identity rules.
- `POST /api/v1/enroll` shape v2 only (shape v1 answers 400 invalid_request). Checks reach_version against minimum 0.12.0, resolves the code (W-ENR-1: secret lookup, course id within Damerau-Levenshtein distance 2, did_you_mean), finds the roster entry matching both username and student_id, and answers with a signed W-ENR-5 stamp. Enroll and preview share a limit of 30 per minute per IP (429 with Retry-After).
- `GET /api/v1/status` verifies the W-AUTH request signature against the stored install key, compares X-Reach-Fingerprint with the stored digest (403 fingerprint_mismatch) and answers a minimal body with no slices and no packages.
- `wire_contract_sha256` is the SHA-256 of specs/wire.yml in this checkout.

## Fixtures

Courses (`fixtures/courses.yml`):

| Course | Code | Ends | State |
| --- | --- | --- | --- |
| BUS101 | BUS101-K7QX-94TD | 2026-12-18 | live |
| ACCT201 | ACCT201-2M8R-QW3Z | 2026-06-01 | ended (course_code_expired) |

Identity rules: institution school, domain school.example, username `^[a-z][a-z0-9._-]{1,31}$`, student id `^[0-9]{5,10}$`.

BUS101 roster (`fixtures/roster.yml`, fictional people):

| Username | Student id | Name |
| --- | --- | --- |
| mdel101@school.example | 1040217 | Maria Delgado |
| joka204@school.example | 1040358 | James Okafor |
| pram317@school.example | 1040471 | Priya Raman |
| hwhi418@school.example | 1040592 | Hannah Whitfield |
| tbre529@school.example | 1040634 | Tomas Brennan |

## Point Reach at it

    export REACH_HOME="$(mktemp -d)"
    export REACH_TEACH_URL=http://127.0.0.1:9480
    ruby exe/reach enroll --course-code BUS101-K7QX-94TD --username mdel101 --student-id 1040217 --teach-url "$REACH_TEACH_URL"

Use a scratch `REACH_HOME` each time so no real install is touched.
