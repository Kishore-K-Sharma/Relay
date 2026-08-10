# Contributing to Relay

## The short version

1. Write the failing test first. Watch it fail. Then write the code.
2. `dart format .` and `dart analyze --fatal-infos` must both be clean.
3. Change the relay rules in one language, change them in all three.
4. Explain *why* in the comment, not *what*. The code already says what.

---

## Test-driven, and not loosely

Every behaviour in this repository was written test-first, and the tests are
the reason the mesh can be changed at all. A pull request that adds behaviour
without a test that failed before it is not accepted, however small.

This matters more here than in an ordinary app because most of what Relay does
is invisible: a frame that should have been dropped and was not, or a message
that was reported delivered when nothing acknowledged it, looks exactly like
success from the outside.

**Watch the test fail before you make it pass.** A test written after the code
passes immediately, and a test that has never failed has never proved anything.

### Guards must be shown to bite

Several tests exist to stop a specific mistake coming back — the cryptographic
domain separators, the launch screens, the relay's blindness to blocking,
`reachable_test.dart`. When you add one, break the thing it guards on purpose,
confirm the test fails with a message that would tell a stranger what to do,
then put it back. A guard nobody has seen fail is a guard nobody knows works.

---

## Where code goes

`app/lib/src` is four directories, split by what a file may depend on:

| Directory | May import |
|---|---|
| `domain/` | Dart and the core packages — never `material.dart` |
| `runtime/` | `domain/`, transports, messaging |
| `ui/` | `domain/`, `runtime/`, Flutter |
| `app/` | everything, once, at startup |

Anything that is not Flutter-specific belongs in a package under `packages/`,
not in the app. `core_protocol` and `core_crypto` are pure: no file system, no
network, no platform channels, no clock reads except through an injected clock.

Intra-library imports are written `package:relay_app/src/...`, not relative.

---

## Things that must stay in step

**The relay logic exists three times** — Dart, Kotlin and Swift — because each
platform relays in the background where Dart is not running. All three are
pinned to `testvectors/relay/decisions.json`. If you change relay behaviour:

```bash
dart run tools/generate_vectors.dart
# then update RelayEngine.kt and RelayEngine.swift to match
```

CI compiles and runs the Kotlin and Swift copies against the vectors, so a
divergence fails the build rather than reaching a field test.

**The Pigeon bindings are generated and checked in.** Edit the contract, then
regenerate — CI fails if the checked-in output does not match:

```bash
(cd packages/transport_ble && dart run pigeon --input pigeons/ble_api.dart)
(cd packages/transport_wifi && dart run pigeon --input pigeons/discovery_api.dart)
```

**These five constants must never change.** They are hashed into every address,
safety number, room code and courier tag that exists on any device:

```
relay-addr-v1   relay-safety-v1   relay-room-v1   relay-roomid-v1
relay-courier-tag-v1
```

They look like ordinary descriptive strings, which is exactly why they get
edited. Changing a domain separator silently breaks every install in the field.
If one genuinely has to move, add a `-v2` beside it rather than editing it.
`app/test/brand_test.dart` pins them.

---

## A feature nobody can reach is not a feature

This has happened three times: `depositWithCouriers`, `leaveRoom` and voice
playback were each fully written, fully tested, correct — and callable by
nothing outside the test suite. The analyzer sees a public API and assumes an
external caller. The tests pass, because the tests *are* the caller.

`app/test/reachable_test.dart` now fails if a public `MeshRuntime` member has no
caller in production code. If something genuinely is a test seam, mark it
`@visibleForTesting` — that annotation is a claim, and making it explicit is the
point.

---

## Comments

Comments explain the decision, the trade-off, or the bug that made the code look
the way it does. They do not restate the code, and they do not apologise.

A comment that says "the play arrow used to be decorative and pressing it did
nothing" earns its place. A comment that says "increment the counter" does not.

---

## Security

Do not open a public issue for a security problem. See
[.github/SECURITY.md](.github/SECURITY.md).

The threat model is in [docs/SECURITY.md](docs/SECURITY.md), including the parts
the authors are least confident about. If a change widens the threat model —
anything that adds a network destination, weakens an assumption, or makes the
app easier to attribute to a person — say so in the pull request and update that
document in the same change.

---

## Licensing of what you send

Relay is released under [the Unlicense](LICENSE) — public domain. Opening a pull
request means you dedicate your contribution to the public domain on the same
terms. There is no CLA to sign, but understand what you are giving up: this is
irrevocable, and you keep no rights over the code once it is merged.

Only send code you have the right to give away. Code copied from a project under
any other licence — including MIT and Apache, both of which require attribution
this repository cannot provide — cannot be accepted, however small. Nor can code
written for an employer who owns it.

If any of that is a problem, say so before you write the patch rather than after.

---

## Pull requests

- One concern per pull request.
- The full test suite green, formatting clean, `dart analyze --fatal-infos`
  clean.
- If you touched a document's subject matter, touch the document.
- If you removed or weakened a guard, say why in the description. Reviewers
  should treat that as the most interesting line in the diff.
