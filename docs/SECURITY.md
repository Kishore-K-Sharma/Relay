# Security review pack

**Status: not yet reviewed by anyone outside the project.**

This document exists to be handed to an external reviewer. It states what the
app claims, what it does not claim, where the cryptography lives, and which
parts the authors are least confident about. It is deliberately blunt about the
last of those: a review that only looks where we point it is worth little, but a
review that has to rediscover our own doubts wastes its budget.

---

## 1. What is being claimed

| Claim | Where it is enforced |
|---|---|
| Direct messages are end-to-end encrypted; relaying phones cannot read them | `packages/messaging/lib/src/session_manager.dart`, `packages/core_crypto/` |
| A pinned contact cannot be silently impersonated | `packages/core_identity/lib/src/contacts.dart`, `MeshRuntime.verifyContact` |
| A message is never reported as delivered without an acknowledgement | `packages/messaging/lib/src/message_service.dart` |
| Nothing readable ever leaves the device | `MessageService._attempt` — no plaintext path exists |
| Panic wipe leaves nothing recoverable on the device | `LocalStore.wipe`, `LocalStore.eraseForeignDatabases`, `PacketStore.wipe` (Kotlin and Swift) |
| The app sends no telemetry, ever | `app/lib/src/runtime/event_log.dart` — in memory, no upload path |
| The Wi-Fi transport is opaque to the network it runs on | `packages/transport_wifi/` — carries the same sealed frames as the radio, adds no key material |

## 2. What is explicitly **not** claimed

These are in the product's own threat-model screen, not buried here.

- **Room codes are weak.** Six characters from a 32-symbol alphabet is roughly
  31 bits. Argon2id at 64 MiB raises the cost of guessing; it does not make the
  code a strong secret. Anyone who overhears or is told a code reads that room
  permanently. Rooms have **no forward secrecy**.
- **Traffic analysis is not defended against.** An observer with radios can tell
  that a device is running this app, roughly when it transmits, and how much.
  Frame headers — type, ttl, source and destination hashes — are plaintext by
  necessity: a relay that could not read them could not relay.
- **The internet relay reveals the recipient.** A Nostr relay must know who to
  deliver a gift wrap to, so the recipient's key is in a plaintext tag. The
  sender is hidden; the recipient is not, and cannot be.
- **A seized unlocked phone gives up everything.** There is no second passphrase
  and no plausible-deniability store.
- **Presence beacons are plaintext.** Discovery between strangers is impossible
  otherwise. They carry a nickname and a public key, and are rebroadcast on a
  timer, so a stationary listener can track a device for as long as it keeps the
  same session identity.
- **The local network sees more than the air does.** When a message goes over
  Wi-Fi, the network's owner learns from ordinary router logs which two devices
  are talking and when. Contents stay encrypted. This is a strictly larger
  metadata surface than Bluetooth, disclosed in the in-app threat model, and the
  transport has its own switch so a user can decline it.
- **The mDNS advertisement is public.** It announces on the local network that
  this device runs Relay, with a random per-run name and a truncated address.
  Discovery between strangers is impossible otherwise. Stealth mode withdraws
  it.
- **Room history reaches people who were not there.** Joining a room asks its
  members for what was said before you arrived, and they answer with up to 100
  messages from the last 12 hours. Anyone who obtains the code therefore gets a
  bounded slice of the past as well as the future. This is a real widening of
  what a leaked code costs and is stated in the in-app room reminder. The
  window and the count are the only limits; there is no per-member consent.
- **Room ownership is a convention, not a control.** A signed claim stops
  somebody forging a claim in another person's name — that part is real — but
  the room's only access control is its code. An owner cannot evict anybody, and
  a client that ignores a retention request keeps the messages. `/pass` moves a
  room by *telling* its members a new code rather than re-keying them
  automatically, deliberately: an automatic re-key on a remote instruction would
  let anyone holding the owner's key move a whole group unnoticed.
- **Cover traffic is partial.** It is off by default. Turned on, it delays real
  messages by a random moment and emits occasional meaningless frames, which
  costs battery and airtime for everyone relaying them. It raises an observer's
  cost; it does not defeat one who watches a quiet mesh for long enough, because
  dummies are never replied to and a real conversation has a shape.
- **The three-tap wipe has no confirmation.** That is what makes it useful when
  somebody is reaching for the phone, and it means an accidental triple-tap is
  unrecoverable. It is off until the user turns it on.
- **iOS background discovery is crippled by the platform.** A backgrounded
  iPhone moves its service UUID into the advertising overflow area, which
  Android scanners cannot read. This is an Apple restriction, not a bug we can
  fix.

## 3. Cryptographic inventory

| Purpose | Primitive | Implementation | Verified against |
|---|---|---|---|
| Pairwise session | Noise XX (`Noise_XX_25519_ChaChaPoly_BLAKE2s`) | `core_crypto/lib/src/noise.dart` | Official cacophony vectors, `testvectors/crypto/noise_xx.json` |
| AEAD | ChaCha20-Poly1305 | `package:cryptography` | Via the Noise vectors |
| Hash / KDF | BLAKE2s, HMAC-BLAKE2s, Noise HKDF | `core_crypto/lib/src/primitives.dart` | Known-answer tests + the Noise vectors |
| Identity signing | Ed25519 | `package:cryptography` | Library |
| Room key derivation | Argon2id, 64 MiB / t=3 / p=1 | `core_identity/lib/src/room_code.dart` | RFC 9106 §5.3 known-answer test through the same public API the app calls, plus pinned derivation vectors — `core_identity/test/room_key_vectors_test.dart` |
| Relay encryption | NIP-44 v2 (secp256k1 ECDH + HKDF-SHA256 + ChaCha20 + HMAC-SHA256) | `transport_nostr/lib/src/nostr_crypto.dart` | Official NIP-44 vectors, `testvectors/nostr/nip44.vectors.json` — 35 conversation-key, 10 encrypt/decrypt, 24 padding, 12 invalid-payload |
| Relay stream cipher | ChaCha20, RFC 8439 layout | `transport_nostr/lib/src/chacha20.dart` | RFC 8439 §2.4.2 vector |
| Relay signatures | BIP-340 Schnorr over secp256k1 | `package:bip340` | Library |
| Relay metadata protection | NIP-59 gift wrap | `transport_nostr/lib/src/gift_wrap.dart` | Behavioural tests only |
| Local-network transport | None of its own | `transport_wifi/` | Carries sealed frames unchanged; see §3.6 |

### 3.1 The deliberate deviation from Noise

**This is the first thing to review.**

Noise's transport phase uses an implicit nonce counter advanced in lockstep on
both sides. Over BLE that is unusable: frames are lost and reordered routinely,
and the first loss leaves the receiver permanently a step behind, after which
every subsequent message fails authentication forever.

The mesh path therefore transmits an 8-byte nonce with each ciphertext and
applies a 64-entry sliding replay window (`NoiseSession.seal` / `open`). Points
we would like checked:

- The window update happens only after successful authentication, so a forged
  frame cannot consume a nonce the genuine message still needs. We believe this
  is correct; it is the kind of thing that is subtly wrong.
- Automatic rekeying is **disabled** on this path, because a count-triggered
  rekey desynchronises the moment a frame is lost. One key per direction lasts
  the life of the session. This is a real reduction in intra-session forward
  secrecy. We would like an opinion on whether an epoch scheme keyed on the
  nonce (`epoch = nonce / N`) is worth the complexity.
- The spec-conformant `encrypt`/`decrypt` path is retained and is what the
  published vectors exercise. The framed path is **not** covered by any external
  vector, because none exists for it. That is the largest untested surface in
  the cryptography.

### 3.2 Simultaneous handshake resolution

Two strangers reaching for each other at the same instant is the normal case in
a crowd. The rule is that the lower address hash yields and becomes the
responder (`SessionManager.receiveHandshake`). Disambiguation between "a
competing opening" and "the message 2 I was waiting for" is by **message
length** — 32 bytes means message 1.

This is now proved rather than assumed, for this pattern.
`packages/messaging/test/handshake_length_test.dart` checks that message 2 is
never 32 bytes for any payload size, and states the arithmetic: XX message 2 is
`e, ee, s, es`, so its floor is 32 + (32 + 16) + 16 = 96 bytes with nothing
carried at all. Every term is fixed by the pattern, so no payload can shrink it.

**The proof is only as durable as the pattern.** Changing the handshake, the
curve, or the AEAD tag length changes that arithmetic, and the line in
`receiveHandshake` that depends on it does not mention any of them. A reviewer
should say whether an explicit message-type byte is worth the extra byte per
handshake to make the dependency impossible to break by accident. Our view is
that it probably is, and we have not done it.

### 3.3 Room ciphers

Every room member encrypts under the same key with a **random** 8-byte nonce
(`RoomCipher`), because a room has no single sender to own a counter. Two
members drawing the same nonce would break confidentiality for both messages.
At 2^62 effective values and realistic message volumes this is not a practical
concern, but the reasoning deserves checking rather than assuming.

Replay of a room message is caught above the crypto layer, by `(senderKey,
sequence)` deduplication in `data`. There is no cryptographic replay protection
inside `RoomCipher` itself.

### 3.4 Key storage

- Ed25519 identity seed and X25519 Noise static key: platform keystore via
  `flutter_secure_storage` — Android `EncryptedSharedPreferences`, iOS Keychain
  with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Two separate keys deliberately: signing and Diffie-Hellman on one key weakens
  both.
- StrongBox / Secure Enclave are **not** used. Worth an opinion on whether that
  matters here given the keys must be readable by a background service.

### 3.5 Data at rest

`PRAGMA secure_delete = ON` and, on wipe, `wal_checkpoint(TRUNCATE)` followed by
`VACUUM`. This was added after a test reading the raw database files found that
message text, contact names and room codes all survived a "wipe" — in the
write-ahead log and in free pages. `app/test/panic_wipe_test.dart` now reads
every byte in the database directory and asserts the plaintext is gone.

**Known limit:** deletion at the filesystem level does not guarantee erasure at
the flash level. Both platforms encrypt storage at rest, which is the actual
mitigation. We have not attempted anything beyond that and do not claim to.

**Wipe reaches only the database the process has open.** That is a real hole
whenever a build stops opening a file it used to open: the orphan stays on disk
with its history intact, and the app reports a successful wipe. Intact plaintext
plus an assurance it is gone is worse than either alone.

`LocalStore.eraseForeignDatabases` closes it at startup, before the store is
opened, so an orphan cannot survive a launch and no user action is required. It
takes an allow-list of the names this build owns rather than a list of old ones,
because a list of old names has to be extended by whoever renames a database
next — the same person who has already forgotten. The `-wal` and `-shm` sidecars
go with the file; in WAL mode the most recent conversation is in the log and not
in the database at all. Files that are not databases are left alone, since that
directory is not exclusively ours. Six tests in
`packages/data/test/orphan_database_test.dart`.

The deletion is filesystem-level, with the same caveat as above: encryption at
rest is the actual defence against recovery from flash, and nothing beyond that
is claimed.

### 3.6 The local-network transport

It adds no cryptography, which is the point: it moves the same sealed frames the
radio does, and the Noise session above it is unchanged. What is worth checking
is the parsing and the connection rules, because this is the first surface in
the project that accepts a TCP connection from an unauthenticated stranger.

- The frame reader (`link_codec.dart`) checks a declared length against a 64 KiB
  cap **before** buffering, so a hostile peer cannot make the device allocate on
  demand. Any malformed byte closes the link rather than attempting resync.
- The link hello carries an address hash and nothing secret. It is a routing
  hint; the Noise handshake above is what establishes who is actually there. A
  peer claiming someone else's address gains nothing it could not gain by
  claiming it over Bluetooth.
- Two devices dialling simultaneously resolve to one link by *keep the
  connection opened by the lower address hash*. Both sides compute it from the
  hello. We would like this checked for the case where the two hashes are equal
  — currently the link is refused, on the grounds that a colliding address is
  unroutable anyway.
- A connection that never says hello is dropped after five seconds, so a port
  scanner costs one socket rather than one forever.

The DNS-SD service type is `_kishorek-relay._tcp`. Two things follow, and the
second is a real cost rather than a footnote.

- It is vendor-prefixed so that Relay cannot pair with an unrelated service that
  happened to choose the same generic name on the same LAN. A bare one-word type
  is generic enough to collide.
- **Anyone on the network can see it.** mDNS advertisements are broadcast in the
  clear, and this one names both the product and the publisher. That is worse
  for the user than a generic string: it turns "some device is running an app
  that does peer discovery" into "this device is running Relay, published from
  kishorek.dev". No message content leaks, but participation does, and on a
  network with logging it is attributable and retained.

  The prefix names an individual rather than a company, which is a change in
  kind worth stating plainly: it does not identify the *user*, only the author,
  and an observer who recognises the string learns the same thing either way.

  This is not a bug we intend to fix by renaming — a generic service type is
  equally visible and merely slower to identify, which is obscurity, not
  privacy. The right answer is that Wi-Fi is off by default and the user is told
  what turning it on means. A reviewer should judge whether the in-app wording
  is honest enough about it.

### 3.7 Reaching relays through Tor

`transport_nostr/lib/src/socks5.dart` implements a SOCKS5 client and a relay
socket factory that tunnels the WebSocket through it, so relay traffic can be
routed through a Tor daemon. The rule the tests pin hardest: the relay's **name**
is handed to the proxy, never an address this device resolved. Resolving locally
would send a DNS query to precisely the network the proxy exists to avoid, which
is the classic way a proxied application is deanonymised. TLS is negotiated
inside the tunnel against the relay's own name, so the proxy sees nothing.

**Relay does not ship a Tor daemon.** Bundling one means vendoring a binary per
platform — a static library on iOS — and neither the bundling nor its behaviour
can be verified in this repository today. Without a daemon running, a proxied
relay connection fails and the relay reports as unavailable; it never silently
falls back to a direct connection, which would be worse than not offering the
feature. The app does not currently enable the internet relay at all, so this
path is exercised by its own tests rather than in production.

### 3.8 Couriers

`CourierSeal` seals a message with one-way Noise X (`-> e, es, s, ss`) to the
recipient's static key. A courier carrying it learns nothing: the sender's
identity is encrypted inside, and the only routing information is a 16-byte
HMAC-BLAKE2s tag over the recipient's static key and the UTC day, so envelopes
for one person on different days do not correlate for anybody who does not
already know that key. Yesterday and tomorrow are both accepted, or mail sealed
near midnight would be silently undeliverable.

**Not forward secret.** The seal is to a long-term static key, so somebody who
later obtains that key opens every envelope they captured. bitchat's v2 solves
this with one-time prekeys; Relay does not implement them yet, and the 24-hour
envelope lifetime is the only thing limiting the window.

**Carrying other people's traffic is a threat-model change**, and it is bounded
accordingly: 40 envelopes total, 20 from merely-verified depositors, 5 per
favourite and 2 per verified depositor, 24 hours plus an hour of clock slack,
16 KB each. A spray budget of at most 8 halves on every handover, so one
envelope reaches a bounded number of carriers rather than flooding a city — and
a replayed deposit cannot refill a spent budget, which is tested explicitly.
Everything a courier holds is destroyed by a panic wipe along with everything
else.

**Who is asked to carry, and who is refused.** Mail is offered only to a
favourite or a verified contact, and accepted only from one. Handing envelopes
to any passer-by would tell them this device is carrying traffic and roughly for
whom; taking mail from anyone in range would be a free disk-filling attack on
every phone in a crowd. Delivery runs before spraying on each encounter, so
meeting the recipient never spends a copy. Nothing is offered or accepted in
stealth mode — handing mail over is transmitting.

**The announce now publishes an X25519 key.** This is new exposure and worth
being explicit about. Before couriers, a device broadcast a nickname and an
Ed25519 identity; it now also broadcasts the X25519 static key Noise uses. That
key is public by construction — every handshake already reveals it to whoever
this device speaks to — so it grants no new *cryptographic* capability. What it
does grant is a second stable identifier visible to a passive listener who never
speaks to the device. Anyone already tracking the Ed25519 key learns nothing
new, since the two travel in the same frame; the cost is that a build which
withheld the Noise key would be harder to correlate, and Relay no longer offers
that. Stealth mode suppresses the announce entirely, as before.

**Mail from an unknown sender is dropped, not shown.** A courier envelope names
its sender by X25519 key. If this device has never heard that person announce,
there is nobody to attribute the message to, and it is discarded rather than
displayed under a placeholder — consistent with never showing a state the design
cannot substantiate.

**The user can now see and refuse this.** Until recently the whole mechanism
was invisible: the device carried other people's mail, spent storage and
battery on it, and said nothing. There is now a switch (on by default), a count
of what is held, and a confirmed way to drop it. Two properties a reviewer
should check:

- Turning carrying **off** stops accepting new envelopes and stops spraying,
  but still delivers what is already held to its addressee. The reasoning is
  that the copy is already on the device and withholding it only harms a third
  party who is never told. A reviewer may disagree: it means the switch is not
  a complete stop, and a user reading the label might expect one.
- Dropping held mail is silent to everybody else. There is no "carrier gave up"
  signal, by design — such a signal would tell an observer who was carrying
  what for whom. The cost is that a sender cannot distinguish "still in
  transit" from "thrown away", and neither can we.

Received messages now record `via_courier`, and the interface labels them. This
is a small metadata addition at rest: a seized device reveals not only what was
said but that a particular message travelled by hand, which narrows when and
where the sender may have been. Judged worth it, because a reader who does not
know a message is hours old may act on it as though it were current.

### 3.9 Location channels

`Geohash` and `GeohashChannel` provide six precisions from a building (8
characters) to a large region (2). Posting in one states, to everybody in the
channel and to whatever relay carries it, roughly where the user is standing —
the level is the dial for how roughly, and the coarsest cell is over a hundred
times wider than the finest. This is not wired into the app: it needs location
permission and a working internet connection, neither of which the mesh
requires, and the app does not enable the internet relay yet.

## 4. Where we are least confident

Ordered by how much a finding here would matter.

1. **The framed Noise path** (§3.1). No external vectors exist; it is our own
   construction on top of a reviewed protocol.
2. **Loss of intra-session rekeying** (§3.1). A deliberate trade we would like
   a second opinion on.
3. **Handshake message disambiguation by length** (§3.2). The bound is now
   proved for the current pattern; what is unresolved is whether relying on an
   unstated arithmetic identity is acceptable at all.
4. **The relay's metadata surface.** Gift wrapping hides the sender; we have not
   analysed what an adversary running several popular relays can correlate from
   timing and recipient tags alone.
5. **Argon2id parameters** were chosen for a target derivation time, not from a
   measured attacker cost model.
6. **The Wi-Fi link layer** (§3.6). New attack surface: an unauthenticated TCP
   connection from anyone on the same network. The parser is small and the tests
   include hostile lengths and non-Relay traffic, but it has had no adversarial
   review.
7. **An unsolicited handshake displaces an established session.** *Found while
   writing the collision tests below; not yet fixed.* A completed Noise XX
   handshake offered at a peer's address hash replaces whatever session was
   there, after which the genuine peer's messages fail to open. The address
   hash is broadcast in the clear in every presence beacon, so this needs no
   collision and no guessing — anyone in radio range can cut any conversation,
   repeatedly, for the cost of three frames.

   It is a denial of service and not a disclosure: the intruder holds a session
   under their own static key and cannot read anything sealed to the previous
   one, and a pinned contact still shows as key-changed rather than being
   silently impersonated. `packages/messaging/test/address_collision_test.dart`
   contains a test named `OPEN FINDING` that fails the moment this changes.

   The fix is not mechanical, which is why it is listed rather than done. A
   peer that reinstalls, or is panic-wiped, legitimately arrives with a new
   static key at the same hash and must be able to reconnect — so refusing
   every replacement would break the recovery path in exactly the crowd
   conditions the app exists for. What is wanted is roughly: hold a completed
   but unsolicited handshake in a pending slot, keep decrypting with the
   established session, and promote the new one only on evidence the old peer
   is gone. We would like a reviewer's opinion on what that evidence should be.

8. **Address-hash collisions.** `addressHashOf` truncates to 32 bits, so
   collisions are certain at scale. By the birthday bound the chance of *any*
   collision among simultaneously present devices is about 1 in 870,000 at 100,
   1 in 8,600 at 1,000, 0.1% at 3,000, 1.2% at 10,000 and 25% at 50,000 —
   negligible for a venue, worth thinking about for a city.

   The cost when it happens is now measured rather than assumed:
   `packages/messaging/test/address_collision_test.dart` establishes that a
   collision is a denial of service **between the two colliding parties and
   nothing worse**. The second party cannot open the first party's session, the
   AEAD rejects their frames rather than misattributing them, and a rejected
   frame does not advance the replay window or tear the session down — so the
   genuine peer keeps working. Recovery is all-or-nothing: there is one session
   slot per hash, and `forget` clears it entirely.

   Zero is nudged to 1 so a hash cannot be mistaken for broadcast.
9. **The native relay paths run with no Dart alive** and are the least
   test-covered code in the project — 8 shared vectors each in Kotlin and Swift,
   and nothing on device.

## 5. How to run everything

```bash
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze app packages

# Dart, per package. transport_ble and transport_wifi are absent deliberately:
# they touch Flutter bindings and fail to load under `dart test`.
for p in core_protocol core_crypto core_identity data messaging \
         transport_api transport_fake transport_nostr; do
  dart test "packages/$p"
done
flutter test packages/transport_ble
flutter test packages/transport_wifi
flutter test app

# Cross-language contracts
kotlinc app/android/app/src/main/kotlin/dev/kishorek/relay/ble/RelayEngine.kt \
        tools/parity/kotlin/relay/Main.kt -include-runtime -d relay_kt.jar
java -jar relay_kt.jar testvectors/relay/decisions.json

swiftc -O app/ios/Runner/Ble/RelayEngine.swift \
       tools/parity/swift/relay/main.swift -o relay_parity
./relay_parity testvectors/relay/decisions.json
```

## 6. Scope we would like from a review

In priority order:

1. The framed Noise construction and its replay window.
2. Key handling and storage across both platforms.
3. Room key derivation and the room cipher's nonce strategy.
4. The NIP-44 and NIP-59 implementations against the specifications.
5. The local-network link layer: framing, the duplicate-connection rule, and
   what an attacker on the same Wi-Fi can do with it.
6. Whether the in-app threat-model screen is honest and complete.

Point 6 matters as much as the rest. The product's central claim is that it does
not overstate what it protects; a reviewer who finds the copy misleading has
found a real defect.

## 7. Publication

Findings will be either fixed or published unfixed with an explanation. The
in-app threat model must be updated before any claim in it changes.

**Until this review is complete, the app must not be marketed as safe for
activism, journalism, or any context where being wrong is dangerous.** That
sentence is currently in the app itself and must not be removed before the
review is done.
