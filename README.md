# Auto Rotate

Accelerometer-based screen rotation for [niri](https://github.com/YaLTeR/niri), packaged as a
[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) plugin.

Developed on a Xiaomi Pad 5 (nabu), but the sensor backend is auto-detected and the output
is configurable, so it should work on any niri tablet or convertible with an accelerometer.

## Features

- **Real-time orientation tracking** — turn the device, the screen follows.
- **Control-center toggle** — turning it off *freezes* the current orientation; turning it
  back on syncs immediately to however the device is being held.
- **Rotation hint** — while auto-rotate is off, turning the device brings up a small round
  button in the bottom-left corner; tapping it rotates the screen to match. It fades after
  four seconds and vanishes immediately on tap. Disable it in settings.
- **Sensor backends, probed in order:**
  1. `iio-sensor-proxy` over D-Bus (`net.hadess.SensorProxy`) — x86 and most ARM devices
  2. `ssccli --sensor accelerometer` — Qualcomm Snapdragon Sensor Core
  3. `/sys/bus/iio/devices/*/in_accel_*` — bare IIO fallback
- **Multi-monitor aware** — pick which output to rotate in the settings (defaults to the first).
- **Per-axis calibration** for devices whose sensor axes don't match the usual convention.
- **Debounce + dead zone** so tilting the device mid-air doesn't make the screen flicker.

## Requirements

- `niri` — rotation is applied with `niri msg output <output> transform <normal|90|180|270>`
- `python3`
- An accelerometer (one of the three backends above must be available)

## Install

```sh
git clone https://github.com/LilFishyChan/dms-auto-rotate \
  ~/.config/dms/plugins/nabuAutoRotate
dms ipc call plugins reload nabuAutoRotate
```

Then toggle it from the control center.

> The directory name must stay `nabuAutoRotate` — it has to match `id` in `plugin.json`.

## Settings

| Setting | Purpose |
| --- | --- |
| Bound display | Which niri output to rotate (`auto` = first) |
| Swap X / Y | Flip portrait ↔ landscape detection as a whole |
| Invert X | Fix "both landscape directions are mirrored" |
| Invert Y | Fix "upside-down is detected backwards" |
| Debounce | How long a direction must hold before it is applied (ms) |
| Dominant-axis ratio | How much one axis must dominate before a direction is decided — raise it if the screen twitches while the device lies at an angle |
| Sensor backend | `auto`, or pin `iio` / `ssccli` / `sysfs` when auto-detection picks one that reports the wrong orientation |
| Rotation hint button | Show the bottom-left rotate button while auto-rotate is off |

Calibration is a one-time thing per device: the sensor axes are fixed by the hardware.

## How it works

```
ssccli / iio-sensor-proxy / sysfs
        ↓  gravity components (x, y)
   dominant axis + sign
        ↓
   normal | 90 | 180 | 270
        ↓  held for `debounce_ms`
niri msg output <output> transform <transform>
```

The daemon is launched and supervised by the plugin's `Process` element, so it lives and
dies with DMS. Its whole configuration lives in DMS's `plugin_settings.json`
(`nabuAutoRotate` node) and is hot-reloaded, so changing a setting takes effect immediately.

## Layout

```
plugin.json                 manifest (id, component, settings, permissions)
AutoRotate.qml              control-center toggle
AutoRotateSettings.qml      settings page
Daemon.qml                  daemon surface: supervising the worker + hosting the hint window
RotateHintWindow.qml        the bottom-left "tap to rotate" overlay
scripts/nabu-autorotate.py  sensor → transform daemon
translations/zh_CN.json      Chinese translation
```

## Notes

- Touch input follows niri's output transform automatically, so nothing extra is needed
  for the touchscreen.
- If `iio-sensor-proxy` reports `AccelerometerOrientation: undefined` (some devices ship a
  firmware mount matrix of all zeros), the plugin automatically falls through to `ssccli`.

## License

MIT
