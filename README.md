# Relay

**Offline-first group chat for crowds.**

Relay carries messages between phones over Bluetooth Low Energy and the local
network, with no servers, no accounts and no phone numbers. Each phone passes
on what it hears, so a message can cross a room — or a festival — by hopping
through people who never read it.

---

## Status

**Pre-release. Not reviewed by anyone outside the project.**

> Relay must not be described as safe for activism, journalism or protest until
> the external security review in [docs/SECURITY.md](docs/SECURITY.md) is
> complete. This is not modesty: the threat model has known gaps that are
> written down there, and a crowd is not the same adversary as a state.

What works today: the mesh, the cryptography, the app, and 1,300+ automated
tests across Dart, Kotlin and Swift. What has not happened yet: a security
review, battery measurement on real hardware, an OEM device matrix, and a field
test with more than a handful of people. See
[docs/RELEASE.md](docs/RELEASE.md) for the full gate list.

---

## How it works, in one paragraph

Every phone both speaks and listens over BLE. A frame that arrives is passed on
with its time-to-live reduced by one, up to seven hops, whether or not this
phone can read it — relaying is deliberately blind to who sent a frame, so a
device that has blocked someone still carries their traffic and cannot be
detected as having blocked them. Direct messages are end-to-end encrypted with
a Noise XX handshake; group messages are encrypted to a key derived from the
room code, which never leaves the device. When Wi-Fi is available the same
frames also travel over the local network, and the two radios are presented to
everything above as a single mesh.

The full design is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Getting started

Requires the Flutter SDK 3.41.1 (Dart 3.11).

```bash
dart pub get                 # resolves the whole workspace at once
flutter run -d <device>      # from app/
```

The app needs two real devices to do anything interesting. A single device
shows an empty mesh, which is correct but dull. `packages/transport_fake`
simulates an N-node mesh in tests, so most development needs no hardware at
all.

### Running the tests

```bash
dart pub get

# Pure Dart packages
for p in core_protocol core_crypto core_identity data messaging \
         transport_api transport_fake transport_nostr; do
  dart test "packages/$p"
done

# Flutter packages and the app
flutter test packages/transport_ble
flutter test packages/transport_wifi
flutter test app

# Formatting and lints, exactly as CI runs them
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
```

The relay logic exists three times — in Dart, Kotlin and Swift — because each
platform relays in the background where Dart is not running. The three are
pinned to shared JSON vectors under `testvectors/`, and CI compiles and runs the
Kotlin and Swift copies against them. If you change one, change all three:

```bash
dart run tools/generate_vectors.dart
```

---

## Repository layout

| Path | What lives there |
|---|---|
| `app/` | The Flutter application and its Kotlin and Swift mesh code |
| `packages/` | Ten workspace packages: protocol, crypto, identity, storage, messaging, transports |
| `docs/` | Architecture, plan, threat model, release gates, field-test guide |
| `brand/` | Source artwork and the rules for using it |
| `testvectors/` | Shared JSON contracts consumed by Dart, Kotlin and Swift |
| `tools/` | Vector generation and the native parity runners |

`app/lib/src` is split into `domain/`, `runtime/`, `ui/` and `app/` by what each
file is allowed to depend on. The reasoning is in
[docs/ARCHITECTURE.md §2](docs/ARCHITECTURE.md).

---

## Documentation

| Document | Read it when |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | You want to know how any of it works |
| [PLANNING.md](docs/PLANNING.md) | You want to know what was built and why, phase by phase |
| [SECURITY.md](docs/SECURITY.md) | You are reviewing the cryptography, or deciding whether to trust it |
| [RELEASE.md](docs/RELEASE.md) | You are getting ready to ship |
| [FIELD-TEST.md](docs/FIELD-TEST.md) | You are running a real-world test with real people |
| [brand/README.md](brand/README.md) | You are putting the mark or the name on something |
| [CONTRIBUTING.md](CONTRIBUTING.md) | You are about to open a pull request |

---

## Licence

[The Unlicense](LICENSE). This code is in the public domain. Copy it, change it,
sell it, ship it closed-source, strip every mention of where it came from —
no permission needed and no attribution owed.

A tool for talking without infrastructure should not itself be encumbered. The
people most likely to need a mesh like this are the least able to negotiate over
a licence.

Two things the licence does **not** cover:

- **Patents.** Public-domain dedication waives copyright, not patent rights.
- **The name and the mark.** Fork the code freely; call it something else. See
  [brand/README.md](brand/README.md).

---

Built by [kishorek.dev](https://kishorek.dev). The code is public domain; the
name and the mark are not.
