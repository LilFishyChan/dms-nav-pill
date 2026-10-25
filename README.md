# Navigation Pill

An Android-style gesture bar for the bottom edge of the screen, packaged as a
[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) plugin.

A thin rounded bar sits just above the bottom edge. It appears when nothing is on screen, gets out of
the way when a window is open, and comes back on a bottom-edge swipe. Once visible it responds to
swipes, taps and long presses, each mapped to a configurable action.

## Why a layer-shell window and not raw evdev

The bar is a `PanelWindow` on the overlay layer, so it **receives** touch events itself and can cancel
them — the app underneath never sees the gesture. Listening on `/dev/input` alone cannot do this:
evdev is read-only, events are still delivered to the compositor and the focused client.

evdev is only used for the one case where the bar is *not* on screen: detecting a bottom-edge swipe to
bring it back. That path is inherently a side-channel (the swipe also reaches the app), which is why
it is deliberately narrow — see the thresholds below.

## Behaviour

| State | Bar |
|---|---|
| No windows open | always visible |
| A window is open | hidden — the surface is destroyed so touch passes straight through |
| Bottom-edge swipe while hidden | revealed for `Auto-hide delay` (default 3 s) |
| Finger held on the bar | auto-hide timer paused |
| Any setting changed | forced reveal + the sensing zone is drawn for 3 s |

Fade in and out take 300 ms; the surface is only destroyed after the fade finishes, so the bar
disappears smoothly instead of popping.

## Gestures

Six gestures, all configurable: **swipe up / down / left / right**, **tap**, **long press**.
Each can be mapped to a niri action, a DMS action, a custom shell command, "hide the bar", or nothing.

Swipes are judged **on release**: the drag can wander and come back without triggering. Minimum
displacement is 30 px.

While dragging, the bar follows the finger at **1/5** of the distance, capped at the bar height, so it
gives tactile feedback without flying around.

## Requirements

- `python-evdev` (`pacman -S python-evdev`) — only for the hidden-state bottom swipe
- the user in the `input` group (`usermod -aG input $USER`, then re-login)
- `niri`, for window state (`niri msg --json windows`) and the built-in actions

## Install

```sh
git clone https://github.com/LilFishyChan/dms-nav-pill \
  ~/.config/dms/plugins/nabuNavPill
dms ipc call plugins reload nabuNavPill
```

The directory **must** be named `nabuNavPill` — DMS requires the folder name to match the plugin id.
`nabu` in the id is historical; the plugin itself is device-agnostic.

## Settings

Appearance: bar width, height, distance from the bottom, opacity, auto-hide delay.

Sensing: the bottom zone height in **pixels** (never smaller than bar height + 2× margin). The zone is
drawn as a translucent overlay whenever you change it, so you can see what you are adjusting. Every
slider has a reset button that appears only once its value differs from the default.

Bottom swipe thresholds (hidden state): minimum swipe distance, vertical bias, and a cooldown that
prevents a single swipe from firing twice.

## Notes

- The sensing zone is specified in **logical** pixels; `bottom-swipe-watch.py` multiplies by the
  output scale before comparing against evdev coordinates, which are physical.
- `niri`'s `logical.transform` values for 90° and 270° are the opposite of what the wlroots
  documentation suggests — the script accounts for this.
- The bar is drawn with `Theme.primary`, so it follows the shell accent colour.
