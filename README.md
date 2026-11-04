# EdgeDial

Control screen brightness and volume from the edges of your MacBook trackpad.

Rest a finger on the **left** edge for a moment, then slide up and down to change
**brightness**. Same on the **right** edge for **volume**. Lift your finger and
you're done.

![icon](docs/icon.png)

```
┌─────────────────────────────┐
│ BRIGHT  │           │  VOL   │
│  ███    │           │  ███   │
│  ███    │  normal   │  ███   │   1. rest a finger on an edge
│  ███    │           │  ███   │   2. wait ~300ms → indicator appears
└─────────────────────────────┘   3. slide ↕, then lift
```

No Accessibility permission, no Input Monitoring permission, no prompts at all.
Normal clicking, scrolling and swiping are untouched — EdgeDial only reads.

## Why resting instead of clicking

The obvious design is "click the edge, then slide". It doesn't work well: a
physical trackpad click is delivered to whatever app is focused, so arming a
dial with a click means swallowing that click — and then clicking the left or
right part of your trackpad stops working everywhere. Intercepting and
re-posting clicks to work around that breaks drags and text selection in subtle
ways.

Resting a finger costs nothing, because no click is involved at all.

The tradeoff is false positives, so the gesture is deliberately fussy:

- The finger must **land** inside the edge strip. A cursor swipe that happens to
  end near the edge can't arm a dial.
- It must stay inside a small jitter radius for the whole dwell. Any drift and
  the touch is disqualified.
- A disqualified touch cannot re-arm until **every** finger has left the
  trackpad.
- Extra fingers cancel, so two-finger scrolling near an edge is safe.

While a dial is live, the pointer is pinned in place so your slide doesn't drag
the cursor across the screen.

## What a dial can control

Each edge can be pointed at any of these. Defaults are brightness on the left
and volume on the right; everything else is opt-in and changes nothing until
you pick it.

| Action | Notes |
| --- | --- |
| **Screen Brightness** | Built-in display |
| **Volume** | Default output device; sliding up from zero also unmutes |
| **Keyboard Backlight** | Built-in keyboard. macOS ambient adjustment may move it again later |
| **Night Shift Warmth** | Sliding up from zero switches Night Shift on, sliding back to zero switches it off — strength alone is invisible while it's off |

An action the Mac can't drive is shown greyed out and marked *unavailable*
rather than silently doing nothing.

### A note on two- and three-finger mode

Raising **Fingers** to 2 makes accidental arming almost impossible, but it has a
real cost: two fingers resting and sliding is also how macOS scrolls, so
whatever is under the pointer scrolls while you work the dial. EdgeDial can't
suppress that without an event tap, which would mean requiring Accessibility
permission for the whole app. One finger stays the default for this reason.

## Install

Requires macOS 13 or later and Xcode command line tools.

```bash
git clone https://github.com/DiegoHermosilloP/EdgeDial.git
cd EdgeDial
./Scripts/build-app.sh --install
open /Applications/EdgeDial.app
```

EdgeDial lives in the menu bar (the sliders icon). Turn on **Launch at Login**
from its menu to have it start with your Mac.

## Settings

Most things are in the menu bar:

| Item | What it does |
| --- | --- |
| **Enabled** | Master switch |
| **Left Edge** / **Right Edge** | Screen Brightness, Volume, Keyboard Backlight, Night Shift Warmth, or Nothing |
| **Hold Delay** | How long a finger must rest before a dial arms, 150–700 ms |
| **Fingers** | How many fingers the gesture needs, 1–3 |
| **Slide Up Decreases** | Flips the direction |
| **Show Indicator** | EdgeDial's own on-screen level bar |
| **Haptic Feedback** | Tick when a dial arms and at the ends of the range |
| **Hold Pointer Still** | Pin the cursor during a slide |
| **Launch at Login** | Start with macOS |

Everything else lives in
`~/Library/Application Support/EdgeDial/config.json`, reachable via
**Edit Settings File…** and picked up by **Reload Settings**:

| Key | Default | Meaning |
| --- | --- | --- |
| `leftZoneWidth` / `rightZoneWidth` | `0.18` | Edge strip width, as a fraction of trackpad width |
| `dwellJitter` | `0.035` | How far the finger may drift during the dwell before being disqualified |
| `sensitivity` | `1.5` | Range covered by sliding the full height of the trackpad |
| `minimumTouchSize` | `0.08` | Rejects stray brushes |
| `hudSegments` | `16` | Segments in the level bar; `0` draws a continuous bar |

**Edit Settings File…** opens the file in TextEdit specifically, rather than
handing a `.json` to whatever happens to claim that extension — which is Xcode
on a developer's Mac, but could as easily be Excel, Chrome or Notes, and on a
Mac with no handler registered gives an error instead of a file. TextEdit ships
with every macOS install. Option-click the same row for **Reveal Settings in
Finder** if you'd rather use your own editor.

If a dial arms when you didn't mean it, raise **Hold Delay** or lower
`leftZoneWidth`. If it's hard to trigger, do the opposite.

## How it works

| Concern | Mechanism | Permission |
| --- | --- | --- |
| Raw finger positions | `MultitouchSupport.framework` | none |
| Brightness | `DisplayServices.framework` | none |
| Keyboard backlight | `CoreBrightness.framework` (`KeyboardBrightnessClient`) | none |
| Night Shift | `CoreBrightness.framework` (`CBBlueLightClient`) | none |
| Volume | CoreAudio (`kAudioDevicePropertyVolumeScalar`) | none |
| Holding the pointer still | `CGAssociateMouseAndMouseCursorPosition` | none |

The pointer lock is why EdgeDial needs no permissions. The alternative —
swallowing pointer-movement events with a `CGEventTap` — would require
Accessibility access, and detaching the pointer achieves the same thing with a
plain CoreGraphics call.

`MultitouchSupport`, `DisplayServices` and `CoreBrightness` are private
frameworks, so they are loaded at runtime rather than linked. If a future macOS moves or
changes them, EdgeDial reports the problem in its menu instead of failing to
launch.

## Troubleshooting

```bash
.build/release/EdgeDial --probe           # trackpad data + what's readable
.build/release/EdgeDial --test-controls   # drive every control and restore it
```

`--probe` prints ten seconds of live finger coordinates. `--test-controls`
writes two values to each control and puts the original back, which is the only
way to confirm the private frameworks still behave after a macOS update.

## Limits

- Brightness applies to the built-in display. External monitors need DDC over
  I2C, which EdgeDial doesn't do yet.
- Keyboard backlight and Night Shift apply to the built-in keyboard and display.
- Private frameworks mean this can't ship on the App Store, and a future macOS
  could change them.
- Built and tested on a MacBook Air (M1) running macOS 26.3.

## Development

```bash
swift build          # build
swift test           # run the gesture state machine tests
./Scripts/build-app.sh   # bundle without installing
```

The gesture logic in `Sources/EdgeDial/GestureEngine.swift` is pure and has no
dependency on the trackpad, so `Tests/EdgeDialTests` drives it with synthetic
frames.

## License

MIT
