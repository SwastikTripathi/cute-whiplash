# Whiplash — design brief

A fluffy gentleman Samoyed named **Lash** (top hat, monocle, bow tie) lives in a Dynamic-Island-style black pill hugging the MacBook notch. It watches
how long you've been in a terminal. Fifty minutes of terminal-heavy work without a real break and it nudges you; ignore the nudge and it snaps: it
pulls out a leather
whip and cracks it across your screen. Every crack fractures the glass with spiderweb cracks; then the glass
**shatters** — the pieces of glass fall out, the actual text around the hits drops to the bottom of the screen,
and the display behind the hole is dead (black, bleeding liquid crystal, dead pixel lines), while Lash cackles. A few seconds later everything rewinds back into place and the overlay vanishes. You can also grab
the whip yourself and flick it around for fun.

**Tone:** juicy, over-the-top game feel — squash & stretch, springy easing, screen shake, particles, comic
"CRACK!" text, procedural sound. Never actually harmful: nothing reaches the live screen blind (over a screenshot
the overlay takes the mouse and keyboard), Esc/click gets you out, and it always closes by itself.

## Punishment timeline (auto mode, defaults)

| t | what happens |
|---|---|
| −2 min | Island auto-expands in a calm **nudge**: "stretch break?" with a countdown. Stepping away from the keyboard calls it off. |
| −5 s | Nudge ignored: **warning**, red pulse, countdown 5…1 with ticks, Lash furious. Stepping away still cancels it. |
| 0 | Screenshot of the punished screen (if permitted). Overlay appears showing the screenshot pixel-for-pixel — nothing visibly changes yet — and takes the mouse and keyboard (a click or Esc = quick exit, ≤ 0.4 s). OCR of the text starts in the background (Vision was warmed up at launch). |
| 0–0.3 | The whip unfurls from under the island: its handle, in Lash's fluffy white paw, comes out just below the pill's bottom edge (the island draws no handle of its own). The whip stays fixed to the screen while the glass shakes. |
| strikes | The volley is clustered round the middle of the terminal so the webs join into one hole. Each strike: wind-up → flick → tip breaks the sound barrier → **CRACK** (flash, shockwave, comic text, sound) → the glass fractures there (spiderweb grows outward in ~0.25 s), camera shake. The first strike takes ~0.9 s; from the second on, the next one is called 0.1 s after each crack, so the volley speeds up (~0.6 s apart). |
| after last strike | whip retracts; glass creaks; ~0.35 s later **SHATTER** (Lash cackles, the island laughs "BWAHA!"): one big hole breaks out, its shards fall *out* of the screen (flung from the impact, tipping towards you, tumbling, gravity takes them off the bottom edge), revealing the **dead panel** — the display behind it is dead: near-black, liquid crystal bleeding out under the unbroken glass (seeping along the cracks, an oily sheen, patches of raw backlight), dead pixel columns and rows flickering on across the screen, an electrical buzz with sparks. Letters loosen in a wave, detach, drop and pile up at the bottom. Lash's island shows the taunt and the break's countdown ("GO TOUCH GRASS · back in 7"). (Glass mode: only the letters on the broken glass fall — the live screen still shows the rest.) |
| hold 2 s | counted from when the shards have fallen (~2 s after the shatter); click / Esc to skip. |
| reassemble ~0.9 s | everything rewinds into place (eased, slight overshoot), the island turns smug, the cracks zip back into their impacts (0.4 s), the ink and the dead lines fade; overlay fades out 0.25 s and lets go of the mouse. Because the overlay showed the screenshot, the hand-back to the live screen is seamless. |

Total ≈ 8 s for the first offence (2–3 strikes), ≈ 10 s for 6. Strikes escalate with repeat offences in the same
streak: `min(6, 2 + level)`.

**Glass mode** (no Screen Recording permission, or `--no-capture`): the overlay is transparent over the live
screen. Cracks are drawn on top of it, shards are translucent glass slivers, the hole shows the dead panel, and the
letters are synthetic monospace text (TextHarvester.synthetic) laid over the terminal window.

**Manual mode** (pull the whip out of the island's right end — press there and drag — or "Grab the Whip" in the
menu): the whip lives in that end, so its handle slides out from under it and back in. The overlay takes the mouse
and reads the pointer every frame (while you're still dragging, the island's window has the mouse). The handle
follows the cursor, a hard flick
cracks the glass wherever the tip is. After 6 cracks the glass shatters by itself; Esc or right-click
reassembles and exits.

## Architecture

SwiftPM executable (`Sources/Whiplash`), AppKit + SwiftUI (island) + SpriteKit (overlay) + ScreenCaptureKit +
Vision + AVAudioEngine. No third-party dependencies, no asset files: everything is drawn and synthesized in
code. `scripts/build-app.sh` wraps the binary into `build/Whiplash.app` (LSUIElement, signed with a stable self-signed identity from `scripts/signing.sh` so Screen Recording survives rebuilds).

```
Core/        contracts shared by everyone (Settings, Types, NotchGeometry, CoordinateSpace, IslandModel, LaunchOptions)
Debug/       headless demo harness (OffscreenRenderer, DemoRunner, FakeBackdrop) + one Demo+<Module>.swift per module
Tracking/    TerminalWatcher, TerminalWindowLocator                     ─┐ module "tracking"
Audio/       SoundBoard (procedural SFX)                                ─┘
Capture/     ScreenGrabber (ScreenCaptureKit), TextHarvester (Vision)     module "capture"
Notch/       NotchController, island panel, SwiftUI island + Lash         module "notch"
Whip/        WhipNode (verlet rope physics + rendering)                   module "whip"
FX/          DestructionLayer (cracks, shatter, dead panel, glyph fall, rewind) module "fx"
Overlay/     OverlayController, overlay window, PunishmentScene          ─┐ module "overlay"
App/         AppDelegate, AppCoordinator, status-bar menu, SelfTest     ─┘
```

Data flow: `TerminalWatcher` → `AppCoordinator` → `IslandModel` (UI state) and, at the threshold,
`ScreenGrabber` → `PunishmentPlan` → `OverlayController` → `PunishmentScene` (WhipNode + DestructionLayer,
TextHarvester in the background, SoundBoard for audio).

### Coordinate spaces
See the header of `Core/Types.swift`. Short version: Cocoa global (y-up), Quartz global (y-down; CGWindowList,
ScreenCaptureKit), and **scene** = points relative to one screen's bottom-left, y-up, == SpriteKit coords of
the overlay scene. Whip and FX work purely in scene coords.

## Engineering rules (all modules)

- **Swift 5 language mode, macOS 14+.** Do **not** mark types or members `@MainActor` — in Swift 5 mode that
  turns cross-module calls from nonisolated code into compile errors. Everything runs on the main thread by
  convention; hop back with `DispatchQueue.main.async` when a callback arrives elsewhere. If you must call a
  MainActor-only API (e.g. SwiftUI `ImageRenderer`), wrap it in `MainActor.assumeIsolated { }`.
- **Contracts are frozen.** Keep every existing signature in your module's stub; you may add members, types and
  files. Never edit `Core/*`, `main.swift`, `Debug/{OffscreenRenderer,DemoRunner,DemoRegistry,FakeBackdrop}.swift`
  or another module's files. Need a contract change? Put it under "contract change requests" in your report.
- **SpriteKit must work without a view.** Scenes and nodes are also rendered by `OffscreenRenderer` (SKRenderer):
  no `didMove(to:)`, no `view`. Drive time only via `update(_:)` / `step(dt:)`. Clamp dt (≤ 1/30 s).
- **Idle cost ≈ 0.** No 60 Hz timers while nothing animates. The island and watcher must sit at ~0% CPU.
  The overlay renders only while it is on screen.
- **Never trap the user.** Every full-screen thing has a hard timeout and an escape hatch.
- **No GUI on the real screen while developing.** Don't launch the app or open windows — the user is working
  on this Mac. Verify visuals with headless demos (`swift run Whiplash --demo <prefix> --out <dir>`; look at the
  PNGs and `@sheet.png` contact sheets) and logic with XCTest (`swift test`).
- Match the surrounding style: small focused types, doc comments on non-obvious API, no dead code.

## Demo harness

`Debug/DemoRegistry.swift` defines `Demo` (a `SceneDemo` stepped at 60 fps with capture times, or a SwiftUI
`ViewDemo`). Add your module's demos in your own `Debug/Demo+<Module>.swift` under the `<module>.` prefix.
`FakeBackdrop` gives a believable desktop (`render`), a fake `ScreenSnapshot` (`snapshot`), the terminal window
rect (`terminalRect(for:)`) and exact per-character `GlyphSample`s with crops (`groundTruthGlyphs`) — use them
as realistic test data. `NotchGeometry.demo(size:)` gives the demo screen's notch.
