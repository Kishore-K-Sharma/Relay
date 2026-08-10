# Release requirements

What has to be true, and what has to be declared, before this is published.

Nothing here is a formality. Two of these — the encryption declaration and the
background-mode justification — are the usual reasons an app like this is
rejected or pulled after the fact.

---

## 1. Gates that must pass first

| Gate | Status |
|---|---|
| External security review complete, findings fixed or published | **Not done.** See `docs/SECURITY.md` |
| Battery measured on real hardware, `measured: true` in `testvectors/power/modes.json` | **Not done.** See `docs/FIELD-TEST.md` §1 |
| OEM device matrix passed | **Not done.** §2 of the same |
| Field test with 10+ real users, no crashes, no data loss | **Not done.** §4 |
| iOS background discovery measured and disclosed in-app if degraded | **Not done.** Phase 1.5 |
| Local-network transport tested on a real router with no internet | **Not done.** See `docs/FIELD-TEST.md` §5 |
| Release signing configured (currently signing with the debug key) | **Not done** |

The app must not be marketed as safe for activism, journalism, or protest until
the first of those is complete. That statement is currently in the app's own
threat-model screen and must stay there until it is no longer true.

---

## 2. Export compliance

The app implements and uses strong cryptography, so this applies regardless of
where it is published.

### Apple

`ITSAppUsesNonExemptEncryption` must be declared in `Info.plist`.

Set it to **`true`**. The app uses ChaCha20-Poly1305, X25519, Ed25519 and
secp256k1 for its own end-to-end encryption. This is *not* the HTTPS-only
exemption, and claiming otherwise would be a false declaration.

Most open-source implementations of standard algorithms qualify for the mass
market / publicly available exemptions under US EAR 740.17(b)(1), which
generally requires an annual self-classification report rather than a licence.
**Get this confirmed by someone qualified before submitting.** This document is
not legal advice and the authors are not lawyers.

Required in `Info.plist`:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<true/>
```

Plus, if the exemption is claimed, `ITSEncryptionExportComplianceCode` with the
code Apple issues.

### Google Play

Declare encryption use in the Play Console data-safety section. Play does not
require an export code but does require the declaration to be accurate.

### Distribution outside the stores

An APK published directly is still subject to the same export rules. Publishing
the source alongside it is the usual route to the open-source exemption.

---

## 3. Permission and background-mode justifications

Reviewers reject these when the reason is vague. Each string below is the reason
that is actually true.

### iOS `UIBackgroundModes`

- **`bluetooth-central`** — the app is a mesh relay. It carries other users'
  messages toward their recipients, which requires scanning and connecting while
  backgrounded. Without it a phone stops participating the moment it is pocketed
  and the mesh degrades for everyone around it.
- **`bluetooth-peripheral`** — other devices must be able to reach this one.
  Without the peripheral role a device can only ever be a leaf, never a relay.

Both are load-bearing, not conveniences. If Apple pushes back, the honest answer
is that the app does not function as described without them.

### iOS local network

`NSLocalNetworkUsageDescription` and `NSBonjourServices` are both required, and
both are load-bearing: with either missing, Bonjour silently finds nothing and
the app cannot tell the user why. The declared service type is
`_kishorek-relay._tcp` and must match Android's `SERVICE_TYPE` exactly.

Apple's **multicast entitlement is deliberately not used.** The transport
discovers over Bonjour precisely so it does not need one — the entitlement is
granted by application and could be refused. If anyone later replaces mDNS with
a UDP beacon, that decision has to be revisited before submission, not after.

### iOS usage strings

Already present in `Info.plist`. They must describe the actual use:

- `NSBluetoothAlwaysUsageDescription` — finding people nearby and passing on
  messages, including while the app is closed.
- `NSMicrophoneUsageDescription` — recording voice notes, only while recording.
- `NSCameraUsageDescription` — scanning a friend's pairing code, only while the
  scanner is open.
- `NSLocalNetworkUsageDescription` — finding other people on the same Wi-Fi and
  sending directly to them, including when that network has no internet.

### Android

- `BLUETOOTH_SCAN` with **`neverForLocation`**. This flag matters: without it
  the OS demands location permission, which the app does not need and which is
  alarming to ask for in a privacy-focused messenger.
- `FOREGROUND_SERVICE_CONNECTED_DEVICE` — the correct type. The service exists
  to maintain BLE links. Declaring anything else risks both rejection and OS
  termination.
- `POST_NOTIFICATIONS` — the foreground-service notification. On several OEMs a
  service whose notification is hidden gets killed.
- `ACCESS_WIFI_STATE` and `ACCESS_NETWORK_STATE` — how the app knows whether
  there is a Wi-Fi network to use. Discovery itself needs no runtime permission
  on Android; `NsdManager` is a system service, so there is no dialog.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` — Play restricts this. The
  justification is that the app is a relay whose termination silently degrades
  the network for other users, and the request is user-initiated from an
  onboarding step that explains why.

---

## 4. Store data-safety disclosures

The truthful answers:

| Question | Answer |
|---|---|
| Does the app collect data? | **No** |
| Does the app share data with third parties? | **No** |
| Is data encrypted in transit? | Yes, end to end |
| Can users request deletion? | There is nothing held to delete. Panic wipe erases the device's own copy |
| Analytics | None |
| Crash reporting | None. The diagnostics log is in memory, on-device, never uploaded |
| Advertising ID | Not used |
| Account required | No. There is no account, no phone number, no email |

The local network needs a note: when two people on the same Wi-Fi exchange a
message over it, the network's owner can see from ordinary router logs that
their two devices are talking, and when. Contents are encrypted. This is
disclosed in the app's threat model and in the Settings switch that turns the
transport off.

The internet relay needs a note of its own: when a message goes via a public
Nostr relay, that relay operator learns that an encrypted message was addressed
to a particular key at a particular time. Contents and sender are hidden;
recipient and timing are not. This is disclosed in the app's threat model and
should be disclosed in the listing too rather than left for someone to discover.

---

## 5. Release build

The debug signing config is still in place:

```kotlin
buildTypes {
    release {
        // TODO: Add your own signing config for the release build.
        signingConfig = signingConfigs.getByName("debug")
    }
}
```

Before release: generate a release keystore, keep it out of the repository, and
wire it through Gradle properties or CI secrets. Shipping a release signed with
the debug key means anyone can sign an update to it.

---

## 6. Listing copy

The description must not imply protections the app does not provide. In
particular it must not describe the app as safe for protest or activism, and it
must not present group rooms as having the same protection as direct messages.

The one-line version that is true today:

> Chat with people around you when there is no signal. Messages hop phone to
> phone over Bluetooth, and go directly over Wi-Fi when you share one — even a
> router with no internet. Direct messages are end-to-end encrypted. Group codes
> are short and anyone who learns one can read that group.

The last sentence stays in. It is the thing most likely to be cut for marketing
reasons and the thing most likely to hurt someone if it is.
