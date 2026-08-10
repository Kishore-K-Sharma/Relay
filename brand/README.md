# Relay — brand assets

## The mark

A message leaves one phone, rides over a phone in between, and lands on another.

The middle node is a **ring, not a dot**. The phone that relays your message
carries it and cannot read it. That is the single most important thing about how
this app works, and it is the only idea in the logo.

Everything is drawn from one geometry, defined in a 100-unit square:

```
path    M 22 50  Q 36 -6  50 50  Q 64 106  78 50
stroke  7.5, round caps
nodes   r 8 at (22,50) and (78,50), solid
relay   r 8 at (50,50), stroked 3.6, hollow
```

The hole is punched out of the wave with a mask, not covered with a disc of
background colour. A painted disc looks correct on the dark tile it was drawn
against and shows up as a grey blob the moment the mark sits on anything else.

## Files

| File | Use |
| --- | --- |
| `relay-mark.svg` | Square, opaque. Source for the iOS icon set and the legacy Android launcher icon. |
| `relay-foreground.svg` | Transparent, inset. Android adaptive-icon foreground layer. |
| `relay-mark-mono.svg` | Transparent, one flat colour. Android 13+ themed icon. |
| `relay-lockup-dark.svg` | Mark + wordmark, for dark surfaces. |
| `relay-lockup-light.svg` | The same, for light surfaces. Different greens — see below. |
| `relay-mark-on-dark.svg` | Mark alone, transparent, greens for a dark surface. Source for the iOS dark launch image. |
| `relay-mark-on-light.svg` | The same for a light surface. Source for the iOS light launch image. |
| `relay-icon-1024.png` | App Store listing. |
| `relay-icon-512.png` | Play Store listing. |

## The launch screen

The window the OS paints before Flutter exists. Flutter's template leaves it
plain **white**, which for this app is a defect rather than a default: it opens
dark because a bright screen at night ruins night vision and marks somebody out,
and a full-screen white flash on the way in defeats that however brief it is.

It cannot read the user's in-app theme choice — nothing is running yet — so it
follows the system dark-mode setting instead.

- **Android** — `res/drawable/launch_background.xml` (and the identical
  `drawable-v21/` copy, which is the one that actually wins on every supported
  API). The mark is `res/drawable/launch_mark.xml`, a **vector**, so there are no
  density exports to regenerate. Every colour is a resource, so
  `values/launch_colors.xml` and `values-night/launch_colors.xml` supply the two
  palettes and the vector is not duplicated.

  One deviation worth knowing: a vector drawable has no blend modes, so the
  relay node's hole is a disc filled with `@color/launch_background` rather than
  a real hole. It is only ever drawn on that background. Do not lift that file
  onto anything else expecting transparency.

- **iOS** — `LaunchScreen.storyboard` points at the `LaunchBackground` colour
  set and the `LaunchImage` image set, both of which carry a dark appearance
  variant. Regenerate the images at 96 pt:

  ```bash
  D=app/ios/Runner/Assets.xcassets/LaunchImage.imageset
  for s in 1 2 3; do
    suffix=$([ $s -gt 1 ] && echo "@${s}x")
    rsvg-convert -w $((96*s)) -h $((96*s)) brand/relay-mark-on-light.svg -o "$D/LaunchImage$suffix.png"
    rsvg-convert -w $((96*s)) -h $((96*s)) brand/relay-mark-on-dark.svg  -o "$D/LaunchImage-dark$suffix.png"
  done
  ```

Inside the app the mark is **not** an asset. It is a painter,
[`app/lib/src/ui/brand.dart`](../app/lib/src/ui/brand.dart), restating the same
geometry so it stays sharp at any size and takes its colour from the theme. If
you change the shape here, change it there too — `app/test/brand_test.dart`
checks the files exist, not that they agree.

## Colour

| Token | Dark surfaces | Light surfaces |
| --- | --- | --- |
| Node, start | `#3FC47E` | `#22A05F` |
| Node, end | `#8BE8B4` | `#3FC47E` |
| Relay ring | `#5FD97A` | `#22A05F` |
| Icon background | `#12251C` → `#070F0B` | — |
| Adaptive background | `#0D1B14` flat | — |

The light lockup is the same mark in different hex, not the same file on a white
page. The icon palette is tuned for a black tile and goes weak and minty on
white.

The adaptive background is flat where the square icon's is a gradient: a
launcher scales, parallaxes and re-crops that layer, and a gradient shifts
visibly when it does.

## Regenerating the icons

Everything under `app/ios/.../AppIcon.appiconset/` and
`app/android/.../mipmap-*/` is generated. Do not hand-edit a PNG.

```bash
# iOS — sizes are read from Contents.json, so adding an idiom needs no script change
python3 - <<'PY'
import json, subprocess
d = 'app/ios/Runner/Assets.xcassets/AppIcon.appiconset'
for img in json.load(open(d + '/Contents.json'))['images']:
    if not img.get('filename'):
        continue
    px = int(round(float(img['size'].split('x')[0]) * float(img['scale'].rstrip('x'))))
    subprocess.run(['rsvg-convert', '-w', str(px), '-h', str(px),
                    'brand/relay-mark.svg', '-o', f"{d}/{img['filename']}"], check=True)
PY

# Android — legacy icon in dp, adaptive layers always 108dp
python3 - <<'PY'
import subprocess
R = 'app/android/app/src/main/res'
legacy   = {'mdpi': 48,  'hdpi': 72,  'xhdpi': 96,  'xxhdpi': 144, 'xxxhdpi': 192}
adaptive = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}
for d, px in legacy.items():
    subprocess.run(['rsvg-convert', '-w', str(px), '-h', str(px),
                    'brand/relay-mark.svg', '-o', f'{R}/mipmap-{d}/ic_launcher.png'], check=True)
for d, px in adaptive.items():
    for src, out in [('relay-foreground', 'ic_launcher_foreground'),
                     ('relay-mark-mono', 'ic_launcher_monochrome')]:
        subprocess.run(['rsvg-convert', '-w', str(px), '-h', str(px),
                        f'brand/{src}.svg', '-o', f'{R}/mipmap-{d}/{out}.png'], check=True)
PY
```

Two things that will fail a store review rather than a build:

- **iOS icons must have no alpha channel.** Check with
  `magick identify -format '%[channels]' <file>` — it must say `srgb`, not
  `srgba`. The square mark is opaque, so this holds as long as nobody points the
  script at `relay-foreground.svg`.
- **Do not round the corners.** Every platform applies its own mask. Baking
  them in shows as a double rounding on Android.

## Wordmark

Set in Avenir Next Demi Bold, lowercase, tracking −2 at display sizes.

The lockup SVGs use live text so they stay editable. **Convert them to outlines
before publishing the file anywhere** — on a machine without Avenir Next they
silently fall back to Helvetica and nobody notices until it is in print.

## Naming

This category is unusually crowded — Murmur is a registered trademark held by a
messaging company, Ember has at least four live chat apps, Pigeon has three, and
[Fernweh](https://www.fernweh.chat/) already ships a BLE and Wi-Fi Direct offline
mesh messenger. Every candidate was checked against both stores before anything
was drawn.

Relay was chosen with one known trade-off, accepted deliberately: it is a
descriptive word, so it is legally weak. It will be hard to stop a competitor
using it, and other apps called Relay already exist. If the product is ever
worth defending, the name is the part that will not defend itself.

### The word "relay" inside the codebase

The code uses "relay" 459 times as a verb and a mechanism — Nostr relays, the
BLE `RelayEngine`, `allowRelay`, TTL relay decisions. So **the brand name does
not appear in identifiers**. Types are named for what they do:
`AppColors`, `AppTextScale`, `LocalStore`, `MeshRuntime`, `MeshIdentity`,
`MeshBlePlugin`. The one exception is `RelayMark`, which is the logo and nothing
else.

The alternative was documentation reading "Relay relays via relays."

### Five strings a rename must never touch

If the name ever changes, these do not move with it:

```
relay-addr-v1          relay-safety-v1
relay-room-v1          relay-roomid-v1
relay-courier-tag-v1
```

They are cryptographic domain separators, hashed into every address, safety
number, room code and courier tag. Editing one compiles, passes a smoke test,
and changes the identity of every user — old contacts stop verifying and every
safety number appears to have changed, which is indistinguishable from an
attack. They end in `-v1` because that is how such a constant is meant to be
treated: frozen, and superseded rather than edited.

`app/test/brand_test.dart` fails if any of them changes.

---

## Using the name and the mark

The code is public domain — see [LICENSE](../LICENSE). The name and the mark are
not part of that dedication.

Fork it, sell it, ship it, change anything you like. **Call it something else.**

This is not possessiveness. Relay is a messaging app whose security has not been
reviewed, and users cannot inspect a build. If two apps called Relay carry the
same mark and one of them has been altered, the name stops carrying information
about what is running on the phone — and the name is the only thing most people
will ever check.

Fine without asking: writing about Relay, linking to it, screenshots, saying
your project is built on it or interoperates with it.

Ask first: shipping the mark or the name on a build that is not this one.
