# Whiplash

> Fifty minutes at the terminal without a break? Lash has a whip, and your screen is made of glass.

**Lash** is a fluffy gentleman Samoyed (top hat, monocle, bow tie; slightly unhinged) who lives in a Dynamic-Island-style pill wrapped around your MacBook's
notch. He watches how long you've been in a terminal. Hit the limit and the island turns red and counts down
from five. Then he pulls out a leather whip and cracks it across your screen, 2 to 6 times. Every crack puts a
spiderweb in the glass. Then the glass **shatters**: the pieces fall out of the screen, the letters around the
hits drop and pile up at the bottom, and the display behind the hole is dead: black, with liquid crystal bleeding
out under the glass and dead pixel lines across the screen, like a real smashed laptop. Lash's island taunts you
(`GO TOUCH GRASS · back in 7`). A few seconds later it all rewinds into place and nothing ever happened. Except
you should really stand up now.

It never touches your windows, Esc gets you out, and it always leaves on its own.

## Features

- **A notch pet.** Lash sits in a black pill over the notch, on its right side; the left of the notch is left
  free, so another notch app's island (Sapphire's album art, say) shows there and the two read as one. Down the
  pill's right end runs the work timer as a thin bar, shorter as the session runs out (green → amber → red; blue
  while snoozed), no digits. As your work session grows Lash goes from happy to curious, suspicious, annoyed and
  then furious. He's maniacal mid-whip, smug afterwards and asleep while snoozed. His eyes follow the cursor.
- **Play with Lash.** Stroke the cursor across his head for **head pats** (he closes his eyes, dips under
  your hand, purrs, hearts float up) — a cursor just resting on him does nothing. **Click** to boop him (five
  quick boops and he's dizzy), **double-click** for a happy spin. Rub the cursor back and forth over him to pet
  him. Leave the mouse alone while you're away and he naps; he wakes up with a start when you're back.
- **A hover dashboard.** Hover over the notch for your work time since the last break, a burning fuse, whip stats (today, total, longest session), Lash's
  running commentary and one-click actions.
- **Real screen shattering.** With Screen Recording allowed, the overlay starts from a pixel-exact screenshot,
  so it's *your* screen that cracks. Vision OCR (on-device) finds every character on the screen, the strikes
  aim at your text, and every hit knocks the letters around it loose on the spot — they pop off and fall into
  the screen. At the final shatter the broken glass falls out and the rest of the damaged area's text drops.
- **Glass mode fallback.** With no permission (or `--no-capture`), the cracks and translucent shards are drawn
  over the live screen, and made-up terminal text does the falling.
- **Escalation.** Each whip before you take a real break adds a strike: `min(6, 2 + level)`.
- **Manual mode.** The whip hides in the island's **right end**, past Lash, by the timer's bar: press there (the cursor turns into a hand) and
  drag, and you pull it out — the handle slides out from under the island and stays in your hand. Flick hard to
  crack the glass wherever the tip lands. Six cracks shatter it. Esc or right-click and it reels back in.
- **No asset files.** Every sprite, the whip physics (a verlet rope), the icon and every sound are drawn or
  synthesized in code.
- **~0% CPU when idle.** No 60 Hz timers when nothing is moving, and the overlay only exists while it's on
  screen.

Knows Terminal, iTerm2, kitty, Ghostty, Warp, Alacritty, WezTerm, Hyper, Tabby and Rio.

## How it works

```
WorkSessionTracker ──▶ AppCoordinator ──▶ IslandModel ──▶ notch island + Lash (SwiftUI)
 (input, terminal use,       │
  breaks, work time)         └─ at the threshold: 2 min nudge ─▶ 5 s countdown ─▶ ScreenGrabber (ScreenCaptureKit)
                                   ──▶ PunishmentPlan ──▶ OverlayController ──▶ PunishmentScene (SpriteKit)
                                        WhipNode + DestructionLayer, TextHarvester (Vision) in the background,
                                        SoundBoard (AVAudioEngine) for the cracks and the cackle
```

**When it triggers.** Whiplash is a break reminder for terminal-heavy work. It counts *work since your last real
break*: time you're actively typing or mousing, in any app, as long as you've used a terminal in the last 10 minutes
(reading docs between commands counts; a day without a terminal doesn't). Idling for a minute pauses the clock;
only a **real break** resets it — 5 minutes without input, or the Mac asleep or locked that long. Switching apps
never resets it.

After **50 minutes** of work Lash nudges you ("stretch break?") for 2 minutes. Step away from the keyboard (45 s
without input) and the whip is called off; keep working and the 5-second countdown starts, then the whip and a
forced 10-second break. Ignore that too, and it comes back every 20 minutes of work, one strike harder each time,
until you take a real break. The punishment overlay is a borderless full-screen SpriteKit panel over the screen that
shows most of your terminal. The whip comes out of the notch, or out of a virtual notch on external displays.

## Build & run

Requires macOS 14+ and Xcode (Swift 5.10+ toolchain). No dependencies.

```sh
scripts/build-app.sh            # release build → build/Whiplash.app (signed with a stable local identity); "debug" for a debug build
scripts/run.sh                  # build, quit any running copy, launch
scripts/run.sh --threshold 20   # nudge after 20 s of work (this session only)
scripts/run.sh --whip-now       # punish ~2 s after launch (a fresh build first waits for OCR to warm up)
scripts/run.sh --grab           # start manual whip mode ~2 s after launch
scripts/run.sh --mute           # no sound this session
scripts/run.sh --no-capture     # never screenshot: glass mode only
```

Flags combine (`scripts/run.sh --whip-now --no-capture`). `CONFIG=debug scripts/run.sh` runs a debug build.
`build/Whiplash.app/Contents/MacOS/Whiplash --selftest` builds every subsystem headlessly, prints a report and
exits 0 or 1. To redraw the app icon, run `swift scripts/make-icon.swift` (add `--preview sheet.png` for a
contact sheet of every size).

## Permissions

- **Screen Recording enables itself.** On first launch Whiplash asks macOS once; switch it on in *System Settings ›
  Privacy & Security › Screen & System Audio Recording* and Whiplash notices within a couple of seconds (no click,
  no relaunch — if macOS insists on one, the island offers *Relaunch me*). Without the permission you get glass mode.
- **One grant survives rebuilds.** `scripts/build-app.sh` signs with a self-signed identity kept in `.signing/`
  (its own keychain; your login keychain is untouched), so every build has the same identity and macOS keeps the
  grant. Delete `.signing/` and macOS will ask once more.
- **Listed as allowed but still asking?** That's a grant left over from an older, differently signed build. Run
  `tccutil reset ScreenCapture com.lightstick.whiplash` and relaunch; Whiplash asks afresh.
- **macOS 15+ may re-confirm now and then** ("…continue to allow?"). That's the system's periodic check for apps
  that capture the screen; Whiplash triggers it at launch rather than in the middle of a punishment.
- **Nothing else is needed.** Screenshots are only taken at the moment of a punishment, stay in memory, and are
  discarded when the overlay closes. Nothing is written to disk or sent anywhere.

## Controls

**The island.** Hover over the notch (the middle of the pill) to open the dashboard:

- a mood chip, plus the speaker and lightning-bolt toggles for sound and auto-whip
- the break-reminder chooser (work before the nudge): `25m · 45m · 50m · 60m · 90m`
- **Whip me** and **Snooze** (`15 min · 1 hour · Rest of day`) — to whip the screen yourself, pull the whip out of
  the island's right end (the dashboard's too)
- **Wake up** instead of Snooze while snoozed, and **Turn on** while auto-whip is off

During the nudge or the countdown, step away from the keyboard to call it off ("good human"), press
**Not now · 15 min** to snooze, or **Spare me this once**: the work timer starts over from zero, no whip, and
the next reminder is a full threshold away. *Spare me this once* is also always on the dashboard, at the end of
the burning fuse, to reset the timer in the middle of a session.

**The menu bar whip.**

- a live header (`Working 34:12 / 50:00`) and today's tally
- **Whip Me Now**, **Grab the Whip**, and **Spare Me This Once** (reset the work timer, no whip)
- **Snooze** ▸ `15 Minutes · 1 Hour · Rest of Day`, and **Resume** while snoozed
- **Break Reminder After** ▸ `25 · 30 · 45 · 50 · 60 · 90 Minutes`
- **Intensity** ▸ `Gentle · Normal · Unhinged`
- **Island Position** ▸ `Around the Notch · Beside the Notch` — Around the Notch (the default) keeps Lash's island
  on top of any other notch app's island (Sapphire, NotchNook, …); Beside the Notch moves it into the menu bar to
  the left. Sharing the notch, hover **Lash's face** for his dashboard and **the notch** for the other app; Lash
  fades out while you have the other app's island open (unless he's nudging or whipping), but stays put when it
  pops open by itself for a volume or brightness HUD
- the **Sound**, **Auto-Whip**, **Real Screen Shattering** and **Launch at Login** toggles (Launch at Login only
  works from `Whiplash.app`)
- **About** and **Quit** (⌘Q)

## Settings

| Setting | Default | Where |
|---|---|---|
| Work before the reminder | 50 min | island chooser, menu ▸ Break Reminder After, `--threshold <s>` for one session |
| A real break (no input) | 5 min | `defaults write com.lightstick.whiplash whiplash.breakSeconds -float 600` |
| Repeat after a whip, no break | 20 min of work | `… whiplash.repeatSeconds -float 900` |
| Nudge before the whip | 2 min | `… whiplash.nudgeSeconds -float 60` |
| Stepping away that calls it off | 45 s | `… whiplash.stepAwaySeconds -float 30` |
| Terminal counts as "recent" for | 10 min | `… whiplash.terminalRecencySeconds -float 900` |
| Idle pause (no input pauses the clock) | 60 s | `… whiplash.idlePauseSeconds -float 120` |
| Snooze | off | island or menu: 15 min, 1 hour, rest of day |
| Intensity (strikes, crack size, shake) | Normal | menu ▸ Intensity: Gentle ×0.5, Normal ×1, Unhinged ×2 (always 1–6 strikes) |
| Escalation | on | `… whiplash.escalate -bool false` |
| Sound | on | island speaker toggle, menu ▸ Sound, `--mute` |
| Auto-whip | on | island bolt toggle, menu ▸ Auto-Whip |
| Terminals | the list above | `… whiplash.terminalBundleIDs -array <bundle ids…>` (replaces the list) |

Settings live in `UserDefaults` under `com.lightstick.whiplash`. Relaunch after changing them with `defaults`.

## Safety

- **Nothing reaches your screen blind.** Over a screenshot the overlay takes the mouse and the keyboard for the
  whole show, since the live screen is hidden behind a frozen picture. **Esc** or a right-click leaves at once
  (during the break it skips straight to the rewind); a plain click doesn't, so the break isn't cut short by
  accident — during the break it smashes the screen some more instead. It lets go of the mouse as the rewind
  starts.
- **The break is 10 seconds.** Once the glass has fallen, the screen stays broken for 10 s while Lash's island
  counts down ("GO TOUCH GRASS · back in 7"), then everything glides back into place and the screen fades back
  to live. Meanwhile, **click to keep smashing it**: every blow lands with a THWACK, cracks the glass that's left
  (the letters around it fall, the display dies a little more under it) or, in the hole, kills another column of
  pixels. It all rewinds with the rest.
- **Glass mode is click-through**, since the live screen stays visible, except during the break.
- **The island stays out of the menu bar's way.** Only the notch itself, Lash (to poke him) and the pill's very
  end (to pull the whip out) take clicks; nothing left of the notch is covered while it's closed.
- **Manual mode** takes the mouse. **Esc** or a **right-click** reassembles the glass and hands the mouse back.
- **Hard timeouts.** Auto mode quits after 25 s, manual after 120 s. A wall-clock watchdog 2 s later closes the
  window outright in case the scene hangs.
- **Instant teardown** on sleep, a user switch or a display change.
- **Your windows are never touched.** The overlay paints over a screenshot, or straight over the live screen in
  glass mode, so handing the screen back is seamless.

## Headless demos

Every module renders its scenes offscreen (SKRenderer, SwiftUI `ImageRenderer`) to PNGs, with no windows and no
permissions. This is how Whiplash was built without ever being run on screen.

```sh
scripts/demo.sh list                  # every demo, one line each
scripts/demo.sh whip                  # everything under whip.*  → demo-out/
scripts/demo.sh fx.shatter out/       # one demo, custom output dir
scripts/demo.sh all
swift test                            # the XCTest suite
```

Scene demos write one PNG per captured frame (`<name>@00.85s.png`) plus a labelled contact sheet,
`<name>@sheet.png`. SwiftUI demos write `<name>@view.png`. Good places to start are `overlay.auto` (the whole
punishment), `fx.shatter`, `whip.combo` and `notch.moods`.

## Project layout

```
Package.swift                 SwiftPM executable + tests, macOS 14, Swift 5 mode
Resources/                    Info.plist (LSUIElement), AppIcon.icns
scripts/                      build-app.sh, run.sh, demo.sh, make-icon.swift
Sources/Whiplash/
  Core/                       shared contracts: Settings, Types, NotchGeometry, CoordinateSpace, IslandModel, LaunchOptions
  Tracking/                   TerminalWatcher, TerminalWindowLocator
  Audio/                      SoundBoard, SFXSynth: procedural SFX
  Capture/                    ScreenGrabber (ScreenCaptureKit), TextHarvester (Vision OCR)
  Notch/                      NotchController, island panel, SwiftUI island, Lash
  Whip/                       WhipNode: verlet rope physics + leather skin
  FX/                         DestructionLayer: cracks, shatter, dead panel, glyph fall, rewind
  Overlay/                    OverlayController, overlay window, PunishmentScene
  App/                        AppDelegate, AppCoordinator, status menu, SelfTest
  Debug/                      headless demo harness + one Demo+<Module>.swift per module
Tests/WhiplashTests/          XCTest
DESIGN.md                     the brief and the engineering rules
```
