# Known-answer envelope

`envelope.json` is a `teach.package/v1` guardrails envelope for student `test0000000`, sealed by Teach's own sealing code over a package archive holding one entry, `hello.txt`, with the text `known answer from Teach`. It exists so every platform smoke leg proves that Reach opens what Teach actually produces, not only what Reach itself seals.

| File | What it is |
| --- | --- |
| `recipient-test-key.pem` | throwaway RSA-4096 private key the envelope is sealed for; a public test key, never used for anything else |
| `signing-test-key.pub.pem` | public half of a throwaway RSA-4096 signing key; the private half was discarded |
| `envelope.json` | the sealed envelope, signing key id `known-answer-sign-1` |
| `expected.json` | the plaintext `content_digest`, the entry list and the SHA-256 of `hello.txt` the smoke compares against |

Made once with Teach's own sealing and archive code under Ruby 4.0.6 and OpenSSL 3, with no database and no Teach state read or written. Both keys are public test material and protect nothing. The content is generic and names no institution, instructor, course material or student.
