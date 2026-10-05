You are auditing a release of a public, student-facing plugin before it is published to GitHub. Nothing in the repository is yet public; this audit decides whether it may leave this computer.

Audit the release for ANY issue. Concentrate first on exposure: anything that should not be public. Cover liability, data loss prevention, security and privacy: student data, instructor data, credentials and tokens, local filesystem paths, internal hostnames and addresses, Teach internals that the public documentation deliberately keeps opaque, licensing and attribution problems, and anything that could harm a student or the instructor if published.

The release diff and the deterministic scan summary are in this directory:

{{WORKDIR}}/diff.patch
{{WORKDIR}}/scan.json

Read both first. The diff shows only added and changed lines. Read the surrounding files in the repository, with Read, Grep and Glob, whenever a changed line needs context. You are read-only: do not attempt to modify anything or run commands.

Rules for your report:

- Never quote a secret, token, password, email address or student identifier in full. Show at most the first 2 and last 2 characters and mask the rest with asterisks.
- Every finding names a file and a line when there is one, a short title, and a detail that explains why it matters and what to change.
- Severity is one of critical, high, medium, low, info. Use critical for a leaked secret or student data, high for a likely exposure or serious liability, medium for a real but contained issue, low for hygiene, info for a note.
- Report only what you can support from the files. Do not invent findings. If the release is clean, say so.

Finish your answer with exactly one fenced json block and nothing after it, in this shape:

```json
{"verdict": "pass", "summary": "one or two sentences", "findings": [{"severity": "high", "category": "exposure", "file": "path/or/null", "line": 12, "title": "short title", "detail": "explanation with any value masked"}]}
```

The verdict is "fail" when any finding is high or critical, otherwise "pass". An empty findings array is allowed.
