# Display Flow

**OLED screen-care utility for macOS.** Protects external OLED monitors (and any display you mark as protected) from burn-in by dimming idle screens, hiding the static menu bar, and pixel-shifting the overlay over time.

> Lives in your menu bar. No login screen, no fullscreen mode, no telemetry.

---

## Why

OLED panels suffer from **burn-in**: pixels that stay bright and unchanged for long periods get permanently dim, leaving ghost images of whatever was there. On a Mac the usual culprits are static and on for hours at a time:

- The macOS menu bar (Apple logo, app name, clock, status icons)
- The Dock
- App sidebars and toolbars (Finder, Mail, Slack, etc.)

Display Flow attacks this without forcing you into fullscreen or changing how you work.

## Features

| | |
|---|---|
| **Cursor-aware dimming** | The display you're not actively using fades to opaque. Move the cursor and the active screen flips instantly. |
| **Menu-bar cover** | A thin black strip pinned over the macOS menu bar on protected displays. Move the cursor to the top edge to fade it away and use the menus. |
| **Pixel shift** | Drifts the overlay ±1 pixel through a 9-step grid every minute, so the menu-bar cover's lower edge doesn't always burn the same physical row. |
| **Video-aware pause** | When a video is *visible* anywhere on screen — fullscreen, picture-in-picture, or a small browser player — the overlay steps aside. Audio-only apps (Spotify, Discord voice) don't pause the dimming. |
| **Idle blackout** | After a configurable idle threshold, fully cover protected displays. |
| **Schedule** | Auto-rest your monitor between set hours (default 22:00 → 07:00). |
| **Manual rest** | One click puts protected displays to sleep until you wake them. |
| **Per-display control** | Default: only external (non-built-in) displays are protected. Toggle per monitor. |

## Install

Requirements: **macOS 12 or later**, Xcode Command Line Tools (Swift 5.9+).

```sh
git clone <repo-url> display-flow
cd display-flow
./run.sh
```

`run.sh` builds the app, signs it ad-hoc, and opens it. The icon appears in the menu bar (top right). To start it cold later, just `open ".build/release/Display Flow.app"`.

To stop it: menu-bar icon → **Quit Display Flow**, or `pkill -x DisplayFlow`.

## How to use

Click the menu-bar icon for quick controls:

- **Pause / Resume Display Flow** — master toggle
- **Rest Displays Now** — full blackout until you click again
- **Preferences…** — full UI

The icon changes with state so you can see what it's doing at a glance:

| Icon | Meaning |
|---|---|
| ▭ `rectangle.on.rectangle` | Active — protecting your displays |
| 🌙 `moon.fill` | Resting (manual or scheduled) |
| ⏵ `play.rectangle.fill` | Paused — a video is on screen |
| 💤 `bed.double.fill` | Idle blackout |
| 🌓 `moon.zzz` | Master switch off |
| ⏰ `clock.fill` | Schedule window active |
| ⚠ `exclamationmark.triangle` | No protected displays |

## Preferences

Five sections in the SwiftUI window:

- **Displays** — toggle which monitors are protected. Built-in vs. external is auto-detected and labeled.
- **Appearance** — Black / White / Blur, opacity, fade speed, leave delay, with a live preview.
- **Care** — pause-on-video, pixel shift, hide menu bar, idle blackout (with threshold), and the **Rest Displays Now** button.
- **Schedule** — from / to time pickers; handles overnight ranges.
- **Footer** — total time protected, persisted across launches.

## How it works

Every protected display gets a borderless `NSWindow` at `screenSaver` level (above the menu bar at `mainMenu`). A 30 Hz tick reads `NSEvent.mouseLocation` and flips each window's alpha based on cursor position and several precedence rules.

| Layer | What it does |
|---|---|
| **Cursor follow** | Each window's `alphaValue` animates between 0 and `opacity` depending on whether the cursor is on its display. |
| **Menu-bar cover** | A second `NSWindow` per protected display, sized to `screen.frame.maxY - screen.visibleFrame.maxY` (the actual menu bar height per display). Reveals when the cursor enters the top strip. |
| **Pixel shift** | Each window is created with a frame inflated by 4 px on every side so a ±1 px offset never exposes a screen edge. A 9-step pattern advances every 60 s. |
| **Video detection** | `IOPMCopyAssertionsStatus` polls for `PreventUserIdleDisplaySleep` / `NoDisplaySleepAssertion`. These are the assertions video players, browsers playing video, and video calls already create. Audio-only apps don't, so the overlay still dims while you listen. |
| **Idle detection** | `IOHIDSystem.HIDIdleTime` — seconds since last keyboard or mouse input. |
| **Schedule** | A simple time-of-day window check, including overnight ranges (22:00 → 07:00). |

State precedence (highest first): `disabled` → `noDisplays` → `manualRest` → `scheduled` → `mediaPaused` → `idleBlackout` → `active`.

## Honest limitations

- **Real OLED pixel shift** lives in the panel's firmware on televisions and some monitors and shifts every pixel of the displayed image. A userspace Mac app can't reach the panel that way. Display Flow's pixel shift only moves *its own* overlay layer — most useful where the overlay is always visible (the menu-bar cover), of marginal benefit elsewhere. The strongest protection here is *not having content stuck in the same place*, which is what dimming, idle blackout, schedule, and the menu-bar cover are for.
- The MacBook Pro M3+ tandem-OLED display already does pixel shift in firmware. Display Flow's default is to leave built-in displays alone.
- The build is **ad-hoc signed**, not notarized. It runs on your own Mac; distributing the bundle to other machines requires a real Developer ID + notarization.
- The app polls power assertions every 1.5 s, so a video that just started can take up to ~1.5 s before the overlay fades out. Tradeoff for not hammering IOKit.

## Project layout

```
display-flow/
├── Package.swift              Swift package, embeds Info.plist via -sectcreate
├── Info.plist                 LSUIElement (no Dock), bundle metadata
├── build-app.sh               Bundle assembly + ad-hoc codesign
├── run.sh                     One-shot: build + open
└── Sources/DisplayFlow/
    ├── main.swift             AppDelegate + AppController root
    ├── Settings.swift         ObservableObject, persists to UserDefaults
    ├── MediaWatcher.swift     IOKit assertions + HIDIdleTime polling
    ├── Overlay.swift          OverlayWindow, TopBarWindow, OverlayController
    └── UI.swift               Menu bar + SwiftUI preferences window
```

Pure AppKit + SwiftUI + IOKit. No external dependencies.

## License

MIT.
