# Changelog

All notable changes to Relay are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Nothing has shipped yet. The gates that must be passed before anything can are
listed in [docs/RELEASE.md](docs/RELEASE.md); the phase-by-phase record of what
was built is in [docs/PLANNING.md](docs/PLANNING.md).

## [Unreleased]

### Added
- Bluetooth Low Energy mesh with multi-hop relaying (TTL 7) and background
  survival on Android and iOS.
- Local-network transport over mDNS and TCP, presented to the app as one mesh
  alongside Bluetooth.
- End-to-end encrypted direct messages (Noise XX) and group messages keyed from
  a room code that never leaves the device.
- Store-and-forward couriers: a trusted phone can carry a sealed message to
  someone out of range, without being able to read it.
- Contact pinning by QR, safety-code comparison, blocking, panic wipe.
- Voice notes, mentions, read receipts, history sync, cover traffic, power
  modes.
- The Relay name, mark and launch screens.

### Security
- Panic wipe leaves nothing recoverable: `PRAGMA secure_delete`, WAL truncation
  and `VACUUM`. Found by tests reading the raw bytes of the database directory,
  which showed message text and room codes surviving an earlier implementation.
- Relaying is blind to who sent a frame, so a blocked peer's traffic still moves
  and a block cannot be detected from outside the device.
