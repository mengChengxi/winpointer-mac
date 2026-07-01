# winpointer-mac Engineering Notes

## Purpose

`winpointer-mac` is a macOS CLI tool that aims to emulate the Windows XP-and-later "Enhance pointer precision" mouse feel for external mice.

The first target is a practical, low-latency desktop pointer implementation. It should be close enough to Windows EPP for daily use, while keeping the implementation honest about limits: Microsoft does not publish a complete modern EPP specification, and macOS does not expose the same input pipeline as Windows.

## Hard Constraints

- Do not change trackpad feel.
- Do not write global trackpad settings.
- Do not write `com.apple.trackpad.*` preferences.
- Do not apply acceleration changes to built-in trackpads, Magic Trackpad, digitizers, or multi-touch devices.
- Start as a CLI. No GUI in the first version.
- Keep speed adjustable.
- Avoid device-specific curve fitting in the first version.
- Must be easy to shut down immediately.
- Must not damage the computer or leave persistent system changes behind.

## Baseline Curve

Use INRIA `libpointing` as the first implementation reference.

Relevant source data:

- Project: <https://github.com/INRIA/libpointing>
- Windows EPP config: `pointing-echomouse/windows/epp/config.dict`
- Default Windows 7/8/10 EPP table: `pointing-echomouse/windows/epp/f6.dat`

The config describes:

- System: `Windows_7_8_10`
- EPP: enabled
- Reference input: `125 Hz`, `400 CPI`
- Speed tables: `f1` through `f11`
- Aliases: `-5` through `+5`
- Default function: `f6`

For the CLI, expose speed as `1..11`, where:

- `--speed 1` maps to `f1`
- `--speed 6` maps to `f6`
- `--speed 11` maps to `f11`

## Transfer Function

The first implementation should follow `libpointing`'s interpolation model.

Given one mouse packet:

```text
raw_dx, raw_dy
```

Compute a table index from packet magnitude:

```text
index = floor(sqrt(raw_dx * raw_dx + raw_dy * raw_dy))
```

Look up the selected Windows EPP table:

```text
pixels = table[index]
gain = pixels / index
```

Apply the gain to both axes:

```text
out_x_float = raw_dx * gain + remainder_x
out_y_float = raw_dy * gain + remainder_y
```

Convert to integer pointer movement using truncation toward zero:

```text
out_x = trunc_toward_zero(out_x_float)
out_y = trunc_toward_zero(out_y_float)
```

Save fractional remainders:

```text
remainder_x = out_x_float - out_x
remainder_y = out_y_float - out_y
```

Reset an axis remainder when movement on that axis changes sign. This avoids carrying stale fractional movement across direction reversals.

If `index` is past the end of the table, use the last table value.

## Speed And Sensitivity

The tool should support two controls:

- `--speed 1..11`: Windows-style pointer speed table selection.
- `--sensitivity FLOAT`: extra linear multiplier applied after the EPP gain.

Default values:

```text
speed = 6
sensitivity = 1.0
```

The speed table should be the primary control. `sensitivity` is a calibration escape hatch for DPI, display scaling, and personal preference.

## CLI Shape

Initial commands:

```text
winpointer devices
winpointer run --speed 6 --sensitivity 1.0
winpointer status
winpointer stop
winpointer kill-switch
winpointer probe
```

Expected behavior:

- `devices` lists candidate pointing devices and marks which ones are protected.
- `run` starts the foreground CLI daemon by default.
- `status` reports the active config if a daemon is running.
- `stop` stops the daemon if running in background mode later.
- `kill-switch` force-disables any active event tap or background daemon state owned by this tool.
- `probe` prints raw mouse deltas and transformed deltas without moving the pointer, useful for tuning and tests.

Background daemon support can come later. The first version should run in the foreground so it can be closed with `Ctrl-C`.

## Shutdown And Safety

The first version should be user-space only.

Avoid:

- Kernel extensions.
- DriverKit system extensions.
- SIP changes.
- `sudo` requirements.
- Login items.
- Launch agents.
- Persistent system preference writes.
- Automatic startup after reboot.

The default mode should be foreground-only:

```text
winpointer run --speed 6 --sensitivity 1.0
```

Required shutdown paths:

- Pressing `Ctrl-C` stops all event handling and exits cleanly.
- Sending `SIGTERM` stops all event handling and exits cleanly.
- `winpointer stop` stops a background instance if background mode is added later.
- `winpointer kill-switch` force-disables tool-owned hooks if normal shutdown fails.

On shutdown:

- Disable the event tap or HID callback first.
- Stop injecting pointer events before freeing state.
- Restore any system value changed by the process.
- Remove any PID/socket file owned by the process.
- Leave trackpad settings untouched.

Failure behavior should be fail-closed:

- If permissions are missing, print instructions and exit without changing settings.
- If device classification is ambiguous, skip that device.
- If event injection fails, stop the daemon instead of retrying aggressively.
- If transformed output is unreasonable, clamp or stop rather than sending extreme pointer deltas.
- If shutdown cleanup fails, print the exact cleanup action that failed.

The tool should never attempt to modify firmware, install drivers, change security settings, or keep running after the user explicitly stops it.

## Device Filtering

Default target:

```text
external HID mouse devices only
```

Protected device classes:

- Built-in trackpad
- Magic Trackpad
- Multi-touch devices
- Digitizers/tablets
- Touch screens
- Apple Internal Keyboard / Trackpad composite devices

The first version should use a strict allowlist approach:

- Accept HID devices with mouse usage page/usage.
- Reject devices with trackpad, digitizer, multi-touch, or Apple internal indicators.
- If classification is ambiguous, skip the device and print a warning.

No global pointer or trackpad setting should be changed as a side effect of discovering devices.

## macOS Input Strategy

There are two possible implementation paths.

Path A: event interception and re-injection

- Easier to prototype.
- Gives direct control over the transfer function.
- May introduce more latency.
- Needs accessibility/input monitoring permissions.

Path B: lower-level HID handling

- Better latency target.
- More complex device filtering.
- Harder to implement arbitrary curves cleanly.

Start with Path A only if it is good enough for a CLI prototype. If latency is visibly worse than LinearMouse, move the event path closer to HID and keep the same transfer-function module.

## Verification

Unit-level checks:

- `speed 6` table lookup matches `libpointing` values.
- Integer conversion preserves fractional remainders.
- Remainders reset on sign change.
- `--sensitivity` scales output after EPP gain.
- Out-of-range table indices clamp to the final table entry.

Device safety checks:

- Built-in trackpad is never selected.
- Magic Trackpad is never selected.
- Ambiguous devices are skipped.
- `devices` makes protected status visible.

Manual checks:

- Slow movement remains controllable.
- Fast movement accelerates like Windows EPP.
- Trackpad feel is unchanged before, during, and after the daemon.
- Disabling the daemon restores normal mouse movement.
- `Ctrl-C` exits immediately and restores normal mouse movement.
- `kill-switch` disables all tool-owned input hooks.

## Non-Goals For The First Version

- GUI.
- Per-device curve fitting.
- Windows-pixel-perfect reproduction.
- Game raw-input handling.
- Kernel extension.
- DriverKit system extension.
- Persistent background service.
- Automatic startup.

## Open Questions

- Whether the first viable input path should use `CGEventTap`, `IOHIDManager`, or a hybrid.
- Whether injected pointer movement can avoid feedback loops cleanly enough with an event tap.
- Whether background daemon mode is needed before the first usable test.
- Whether display scaling needs explicit normalization in the first version.
