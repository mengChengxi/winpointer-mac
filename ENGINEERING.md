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

## Speed And Internal Normalization

The user-facing control should primarily be:

- `--speed 1..11`: Windows-style pointer speed table selection.

The CLI keeps these debug overrides:

- `--sensitivity FLOAT`: extra linear multiplier applied after the EPP gain.
- `--input-scale FLOAT`: multiplier applied to packet magnitude before EPP table lookup.

Default values:

```text
speed = 4
sensitivity = 1.0
input-scale = 0.08
```

The speed table should be the only normal tuning control. Windows' reference default is `f6`, but local macOS testing currently uses `speed = 4` as the practical default with this HID-driven implementation. `sensitivity = 1.0` preserves the low-speed Windows EPP gain from the selected table. `input-scale = 0.08` normalizes larger modern HID packets into the middle of the `libpointing` table domain without adding a custom low-speed rule. The value is intentionally an internal preset rather than a per-device profile; debug overrides remain available for experiments.

## CLI Shape

Initial commands:

```text
winpointer devices
winpointer doctor [--json]
winpointer run --dry-run
winpointer run --shadow --quiet
winpointer run [--speed 1..11] [--samples N] [--timeout-ms N] [--verbose]
winpointer status
winpointer stop
winpointer kill-switch
winpointer probe
winpointer probe --tap hid --summary --quiet
winpointer probe --tap hid --summary --quiet --json
winpointer compare-summaries --external FILE --trackpad FILE [--min-samples N] [--min-abs-delta N] [--json]
winpointer compare-summary-set --external FILE [--external FILE ...] --trackpad FILE [--trackpad FILE ...] [--min-samples N] [--min-abs-delta N] [--json]
winpointer attribution-probe --field FIELD --external-value VALUE --trackpad-value VALUE [--json]
winpointer pass-through-probe --confirm PASS_THROUGH_TAP [--json]
winpointer stage2-gate --summary-set FILE --attribution FILE --pass-through FILE [--json]
winpointer bench-transform
```

Expected behavior:

- `devices` lists candidate pointing devices and marks which ones are protected.
- `doctor` prints a read-only readiness report covering candidates, permissions, listen-only/active tap creation, attribution gates, and persistence safety. With `--json`, stdout must contain only one final result object.
- `run` without `--real` remains disabled unless it is a dry-run or shadow run.
- `run` is the current foreground control path. It reads external mouse IOHID reports, moves the cursor from transformed HID deltas, swallows matching macOS mouse events, posts synthetic session events for dragging, and passes through trackpad/unmatched events unchanged. `--verbose` enables hot-path logs; normal operation is quiet by default.
- `status` reports the active config if a daemon is running.
- `stop` stops the daemon if running in background mode later.
- `kill-switch` force-disables any active event tap or background daemon state owned by this tool.
- `probe` prints raw mouse deltas and transformed deltas without moving the pointer, useful for tuning and tests.
- `probe --summary` records CGEvent field stability for external-mouse versus trackpad attribution checks.
- `compare-summaries` compares two JSON summary captures and reports conservative candidate attribution fields after sample-count and movement-quality gates pass. With `--json`, stdout must contain only one final result object.
- `compare-summary-set` requires repeated external-mouse and trackpad captures and reports only fields that repeat within each device class while differing between device classes. With `--json`, stdout must contain only one final result object.
- `attribution-probe` uses a repeatable candidate field for live listen-only classification; it must not transform, suppress, or inject events. With `--json`, stdout must contain only one final result object.
- `pass-through-probe` uses an active event tap but returns every event unchanged; it must require explicit confirmation and exit by sample count or timeout. With `--json`, stdout must contain only one final result object.
- `stage2-gate` reads the summary-set, attribution, and pass-through JSON outputs offline for legacy CGEvent-path diagnostics. It must not access HID, create event taps, write settings, or enable default `run`.
- `bench-transform` measures only the acceleration transform cost; it must not access HID, event taps, or system settings.

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
winpointer run
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
- CLI default speed is `4`.
- CLI default internal normalization uses `input-scale = 0.08`.
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

## Performance Expectations

The intended runtime cost should be small relative to normal desktop input handling.

- The transform is O(1) per mouse report: magnitude, EPP table interpolation, sensitivity multiply, truncation, and remainder bookkeeping.
- The process should sleep in the run loop when there is no mouse input; it should not poll.
- Terminal output is not representative of the final runtime path. Use quiet/stat modes when measuring CPU behavior.
- `doctor` should only perform short read-only checks and must not schedule persistent taps, write HID properties, or start a daemon. With `--json`, the report should be parseable by automation as `kind=doctor-report`.
- Real pointer-control work must keep per-report processing lightweight and avoid allocating in the hot path where practical.

## Pointer Control Path

The current working path is `run`:

- Reads raw IOHID reports from external mouse candidates only.
- Applies the `libpointing` Windows EPP table using the selected `--speed`.
- Moves the cursor immediately from the HID callback to avoid low frame-rate CGEvent delivery.
- Swallows matching macOS mouse move/drag events so the system pointer speed does not stack with this tool.
- Posts synthetic session events so window and file dragging remains continuous.
- Passes through trackpad and unmatched events unchanged.
- Runs only in the foreground and stops when the user closes it with `Ctrl-C`, process termination, or system shutdown.
- Avoids system setting writes, daemons, launch agents, login items, drivers, or kernel extensions.

The older CoreGraphics attribution commands (`compare-summary-set`, `attribution-probe`, `pass-through-probe`, `stage2-gate`) remain useful diagnostics, but they are not the recommended control path on the current test machine because CGEvent fields did not provide a safe external-mouse-vs-trackpad discriminator.

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
