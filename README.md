# winpointer-mac

`winpointer-mac` is a foreground-only macOS CLI prototype for external mice. It emulates Windows XP-and-later "Enhance pointer precision" using community Windows EPP curves.

`winpointer-mac` 是一个只在前台运行的 macOS 命令行原型，用于外接鼠标。它使用社区复刻的 Windows EPP 曲线，模拟 Windows XP 之后“提高指针精准度”的手感。

## Quick Start / 快速使用

Requirements:

使用前需要：

- macOS 13 or newer.
- Swift toolchain compatible with `swift-tools-version: 6.2`.
- Xcode Command Line Tools or Xcode installed.
- No third-party Swift packages are required.

- macOS 13 或更新版本。
- 兼容 `swift-tools-version: 6.2` 的 Swift 工具链。
- 已安装 Xcode Command Line Tools 或 Xcode。
- 不需要额外安装第三方 Swift 包。

Install Apple's command line tools if `swift` is not available:

如果系统里没有 `swift` 命令，先安装 Apple 命令行工具：

```sh
xcode-select --install
```

Build the release binary:

构建 release 版本：

```sh
cd /path/to/winpointer-mac
swift build -c release
```

Check that your external mouse is detected as a candidate and the internal trackpad is protected:

确认外接鼠标被识别为候选设备，并且内置触控板被保护：

```sh
.build/release/winpointer devices
```

Run pointer control with the default preset:

使用默认预设运行鼠标控制：

```sh
.build/release/winpointer run
```

Stop it with `Ctrl-C` in the same terminal. If it is running in another terminal, stop it with:

在同一个终端里按 `Ctrl-C` 停止。如果它在另一个终端运行，用：

```sh
pkill -f "winpointer run"
```

## Speed / 速度

The normal user-facing control is only `--speed`.

正常使用时只调 `--speed`。

Default:

默认值：

```text
speed = 4
```

Examples:

示例：

```sh
.build/release/winpointer run --speed 3
.build/release/winpointer run --speed 5
```

Default is `speed 4`. Lower means slower, higher means faster.

默认是 `speed 4`。数字越小越慢，数字越大越快。

Debug overrides exist, but normal use should avoid them:

也保留了调试参数，但正常使用不建议改：

```text
--sensitivity
--input-scale
```

## Permissions / 权限

macOS may require these permissions for the terminal app you use:

macOS 可能需要给你使用的终端开启这些权限：

- Accessibility
- Input Monitoring

If the program cannot create an event tap or cannot open IOHID input, enable the permissions, restart the terminal app, and run the command again.

如果程序无法创建 event tap 或无法打开 IOHID 输入，打开权限后重启终端，再重新运行命令。

## Safety / 安全性

This project is designed to avoid persistent system changes:

这个项目设计上不做持久系统修改：

- It does not modify system preferences.
- It does not change trackpad settings.
- It does not install drivers, kernel extensions, launch agents, or login items.
- It does not run after you stop it.
- It only targets external HID mouse candidates; trackpad and unmatched events pass through.

- 不修改系统偏好设置。
- 不修改触控板设置。
- 不安装驱动、内核扩展、启动项或登录项。
- 用户停止后不会继续运行。
- 只处理外接 HID 鼠标候选设备；触控板和未匹配事件直接放行。

## How It Works / 工作原理

The current pointer-control path is the default `run` command.

当前真实控制路径就是默认的 `run` 命令。

It works like this:

1. Read raw IOHID movement reports from external mouse candidates.
2. Transform the raw deltas through Windows EPP tables from `libpointing`.
3. Move the cursor immediately from the HID callback for smoother frame pacing.
4. Swallow the matching macOS mouse move/drag event so macOS pointer speed does not stack with this tool.
5. Post a synthetic session event so dragging windows and files continues to work.
6. Leave trackpad and unmatched events untouched.

流程如下：

1. 从外接鼠标候选设备读取原始 IOHID 位移。
2. 用 `libpointing` 的 Windows EPP 表转换原始 delta。
3. 在 HID 回调里立即移动光标，减少低帧率感。
4. 吃掉匹配到的 macOS 原始鼠标移动/拖拽事件，避免 macOS 鼠标速度叠加。
5. 补发 synthetic session event，让拖窗口和拖文件保持正常。
6. 触控板和未匹配事件不处理，直接放行。

## Curve And Defaults / 曲线和默认值

The EPP tables come from INRIA `libpointing`:

EPP 表来自 INRIA `libpointing`：

```text
pointing-echomouse/windows/epp/f1.dat ... f11.dat
```

Windows' reference default table is `f6`, but the current macOS preset defaults to `speed 4` because it felt closest in local testing with this HID-driven implementation.

Windows 参考默认表是 `f6`，但当前 macOS 预设默认使用 `speed 4`，因为在这套 HID-driven 实现的本机测试中它最接近目标手感。

Internal defaults:

内部默认值：

```text
speed = 4
sensitivity = 1.0
input-scale = 0.08
```

`sensitivity = 1.0` keeps the low-speed gain from the selected Windows EPP table. `input-scale = 0.08` normalizes modern HID packets into the range expected by the 125 Hz / 400 CPI reference curve.

`sensitivity = 1.0` 保留所选 Windows EPP 表的低速增益。`input-scale = 0.08` 用来把现代鼠标较大的 HID packet 归一化到 `125 Hz / 400 CPI` 参考曲线更适合的范围。

## Developer Commands / 开发命令

These commands are for development and diagnostics, not normal use.

这些命令用于开发和诊断，不是日常使用命令。

```sh
swift build
swift build -c release
swift run winpointer-core-tests
.build/release/winpointer doctor
.build/release/winpointer run --dry-run
.build/release/winpointer run --shadow --samples 1000
.build/release/winpointer hid-probe --samples 20
.build/release/winpointer transform --dx 10 --dy 0
```

Legacy CoreGraphics attribution commands still exist for diagnostics, but they are not the recommended control path now:

旧的 CoreGraphics attribution 相关命令仍然保留作诊断用途，但现在不推荐作为控制路径：

```text
probe --summary
compare-summary-set
attribution-probe
pass-through-probe
stage2-gate
```

## Current Limits / 当前限制

- Foreground-only. No GUI and no background daemon yet.
- Not a pixel-perfect Windows clone.
- Current defaults are tuned from local testing, not a universal guarantee.
- Games or apps using raw input may not follow the desktop pointer path.
- Device filtering is strict and may skip ambiguous devices.

- 只能前台运行，还没有 GUI 或后台 daemon。
- 不是像素级完全复刻 Windows。
- 当前默认值来自本机测试，不保证所有设备都完全一致。
- 使用 raw input 的游戏或应用可能不走桌面指针路径。
- 设备过滤比较保守，可能跳过不明确的设备。
