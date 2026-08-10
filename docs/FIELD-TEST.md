# Field test and device matrix protocol

Everything here needs real phones and real people. None of it can be simulated,
and none of it has been done. This document exists so that when it is done, it
is done the same way twice and the numbers mean something.

The simulator already covers what it can: `packages/transport_fake/test/dense_crowd_test.dart`
shows flood suppression holding flat at 80 nodes. A simulator cannot tell you
whether an Oppo kills the service after forty minutes, or what BLE actually does
in a room with three hundred people and a Wi-Fi network fighting for the same
band. That is what this is for.

---

## 0. Before you install anything

Nothing procedural. Builds upgrade in place.

Worth knowing, because it is the sort of thing a tester would otherwise be
asked to handle by hand: on every launch the app deletes any database file in
its own storage directory that this build does not own, along with that file's
`-wal` and `-shm` sidecars. A database left behind by an earlier build is not
reached by panic wipe — panic wipe erases the database the running process has
open — so it would otherwise sit there with its history intact while the app
reported a clean wipe.

If you are testing panic wipe (§6) that is the behaviour you are relying on.

---

## 1. Battery measurement

**Purpose:** replace the estimates in `testvectors/power/modes.json` with
measured figures. Until that happens the app is quoting engineering guesses next
to the user's choice, and `measured: false` in that file says so.

### Method

Per device, per mode, three runs:

1. Charge to 100%, unplug, leave for 10 minutes to settle.
2. Note the battery percentage. Start Relay, grant everything, set the mode.
3. Lock the phone. Leave it in a room with **at least three** other phones also
   running Relay — a lone device does almost no work and will produce a
   flattering, meaningless number.
4. Generate light traffic: one message a minute from a fourth device.
5. After **4 hours**, note the percentage. Do not wake the screen in between;
   screen-on time dominates everything else and ruins the measurement.

Record: device, OS version, mode, start %, end %, drain per hour, number of
peers seen (from the diagnostics screen), frames relayed.

### Target

Under **6% per hour** in balanced mode, backgrounded and relaying.

### If the target is missed

Do not quietly adjust the target. Either fix the duty cycle or change the
published figure in `testvectors/power/modes.json` — which will fail the Dart,
Kotlin and Swift parity checks until all three are updated together, which is
the point.

---

## 2. OEM device matrix

**Purpose:** several manufacturers terminate foreground services regardless of
correctness. The app already detects the affected brands and deep-links to their
settings (`BlePermissions`, `MeshBleBridge.openBatterySettings`), but nobody
has checked that those deep links still resolve or that the exemption actually
works.

### Per device

| Check | Pass condition |
|---|---|
| Deep link resolves | The battery/autostart screen opens, not a crash or the generic settings page |
| Service survives screen off, 1 hour | Notification still present; diagnostics shows frames received |
| Service survives app swiped from recents, 1 hour | Same |
| Service survives overnight, 8 hours | Same |
| Survives without the exemption | Record what happens — this is what a user who skips onboarding gets |
| Notification is visible | Some OEMs suppress it, and a suppressed notification often means a killed service |

### Devices

At minimum one each of: Xiaomi/Redmi (MIUI or HyperOS), Oppo/Realme/OnePlus
(ColorOS), Vivo/iQOO (Funtouch), Huawei/Honor (EMUI/MagicOS), Samsung (One UI),
and a Pixel as the control.

Record the exact OS build. These behaviours change between point releases, and a
result without a build number cannot be reproduced.

### Known-hostile behaviours to look for

- Autostart disabled by default, so the service never restarts after a kill.
- "Battery optimisation" re-enabling itself after an OS update.
- Foreground-service notification silently hidden, then the service killed for
  not having one.
- Aggressive Doze on some builds stopping BLE scanning entirely while the screen
  is off, even with an exemption.

---

## 3. Cross-platform interoperability

Needs one Android phone and one iPhone.

| Check | Pass condition |
|---|---|
| Android discovers iPhone, both foregrounded | Under 15 seconds from cold |
| iPhone discovers Android, both foregrounded | Under 15 seconds |
| Messages both directions | Delivered, decrypted, ack returned |
| QR pairing across platforms | Both show the **same** safety code |
| iPhone backgrounded, Android scanning | **Expected to fail.** Record how badly |
| iPhone backgrounded, another iPhone scanning | Should work; record latency |

The backgrounded-iPhone row is the Phase 1.5 question and the single biggest
open risk in the design. iOS moves the service UUID into the advertising
overflow area when backgrounded, where Android cannot read it. If the result is
as bad as expected, the app must say so on screen rather than let iOS users
believe they are reachable when they are not.

---

## 4. Dense-crowd field test

**Purpose:** the Phase 6 exit gate.

### Setup

A genuinely crowded venue. At least **10 real users** who are not on the project,
over several hours. Give them the app and a reason to use it; do not script
their messages.

### Record

- Messages sent, and how many reached their recipient.
- Time from send to `delivered` for each, where it happened at all.
- Battery drain per device over the session.
- Crashes. Any crash fails the gate.
- Messages that showed `sent` and never advanced. This is the number that
  matters most — it is the case where the UI told the truth and the mesh still
  did not deliver.
- Diagnostics counters at the end of the session from each device.

### Ask each participant afterwards

1. Did you ever think a message had been delivered when it had not?
2. Did the app ever look broken when it was working, or working when it was not?
3. Did you understand what "Sent into the mesh" meant without being told?

These matter as much as the delivery rate. The product's central claim is
honesty about delivery, and a user who misread the state chip is a defect even
if every message arrived.

### Pass condition

No crashes, no data loss, and the recorded delivery rate published as measured —
not as a target that was met.

---

## 5. Local network

**Purpose:** the transport is fully tested against real sockets, but never
against a real router. Everything below is about the parts a loopback test
cannot reach: mDNS on hardware, and the ways a real network refuses.

### Setup

A Wi-Fi router with **the internet cable unplugged**, or an old phone running a
hotspot with mobile data off. At least three devices, at least one Android and
one iPhone.

| Check | Pass condition |
|---|---|
| Two Androids find each other | Under 10 seconds from app open |
| Two iPhones find each other | Under 10 seconds |
| Android finds iPhone, and the reverse | Under 10 seconds each way |
| iOS local-network prompt appears | Once, on first use, with our own wording |
| Messages both directions | Delivered and decrypted, with no internet present |
| A large voice note | Noticeably faster than over Bluetooth; record both |
| Both radios at once | One peer entry per person, not two |
| Bluetooth off, Wi-Fi on | App says so specifically and keeps working |
| Walk out of Wi-Fi range | Falls back to Bluetooth; peer does not vanish |
| Turn the router off mid-conversation | Messages queue and resume, nothing lost |
| Stealth mode | The device stops appearing in a Bonjour browser |
| Guest Wi-Fi with client isolation | **Expected to fail.** Record how it presents |

### The isolation case matters most

Hotel, café and corporate guest networks commonly enable AP isolation, which
blocks device-to-device traffic entirely. Nothing the app can do fixes it. What
must not happen is the app appearing broken with no explanation — record exactly
what a user sees, and if it is indistinguishable from "nobody is here", that is
a defect to fix in the copy.

### iOS permission denial

There is no API to ask whether local-network permission was refused. The app
infers it from a browse failure, which is a guess. Test refusing the prompt
deliberately and record whether the app says anything useful. If it does not,
that limitation belongs on screen.

---

## 6. Recording results

Results go in `docs/field-results/YYYY-MM-DD-<venue>.md`, raw numbers included,
whether or not they are flattering. A field test whose bad results are not
written down is worse than no field test, because it produces confidence without
evidence.
