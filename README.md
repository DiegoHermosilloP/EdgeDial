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
| **Left Edge** / **Right Edge** | Brightness, Volume, or Nothing |
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
| `dwellMilliseconds` | `300` | How long the finger must rest before a dial arms |
| `dwellJitter` | `0.035` | How far it may drift during the dwell before being disqualified |
| `sensitivity` | `1.5` | Range covered by sliding the full height of the trackpad |
| `requiredFingerCount` | `1` | Fingers the gesture needs; `2` makes accidental arming nearly impossible |
| `minimumTouchSize` | `0.08` | Rejects stray brushes |
| `hudSegments` | `16` | Segments in the level bar; `0` draws a continuous bar |

If a dial arms when you didn't mean it, raise `dwellMilliseconds` or lower
`leftZoneWidth`. If it's hard to trigger, do the opposite.

## How it works

| Concern | Mechanism | Permission |
| --- | --- | --- |
| Raw finger positions | `MultitouchSupport.framework` | none |
| Brightness | `DisplayServices.framework` | none |
| Volume | CoreAudio (`kAudioDevicePropertyVolumeScalar`) | none |
| Holding the pointer still | `CGAssociateMouseAndMouseCursorPosition` | none |

The pointer lock is why EdgeDial needs no permissions. The alternative —
swallowing pointer-movement events with a `CGEventTap` — would require
Accessibility access, and detaching the pointer achieves the same thing with a
plain CoreGraphics call.

`MultitouchSupport` and `DisplayServices` are private frameworks, so they are
loaded with `dlopen`/`dlsym` rather than linked. If a future macOS moves or
changes them, EdgeDial reports the problem in its menu instead of failing to
launch.

## Troubleshooting

```bash
.build/release/EdgeDial --probe
```

Prints whether the trackpad is readable, whether brightness and volume can be
driven, and ten seconds of live finger coordinates. Useful after a macOS update.

## Limits

- Brightness applies to the built-in display. External monitors need DDC, which
  EdgeDial doesn't do.
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
