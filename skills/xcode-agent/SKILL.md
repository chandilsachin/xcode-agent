---
name: xcode-agent
description: Use the xcode CLI to create, build, run, test, screenshot, and stream logs for iOS/macOS apps
---

# xcode-agent CLI

`xcode` is an agent-friendly command-line tool for iOS/macOS development. It wraps
Xcode tooling (xcodebuild, simctl, xcresulttool, Tuist) in a stable, scriptable
interface with JSON output on every command.

## Discover capabilities

```bash
xcode commands --json   # machine-readable list of all commands + flags
xcode help              # human-readable overview
```

## JSON mode

Pass `--json` to any command for structured output on stdout; logs go to stderr.
Every response follows the same envelope:

```json
{ "ok": true|false, "command": "...", "data": {...}, "error": null|"...", "hint": null|"..." }
```

Branch on `ok` and `exit code`. If `ok` is false, `hint` tells you exactly how to recover.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | runtime error (build failed, tool returned non-zero) |
| 2 | usage error (bad args) |
| 3 | environment not ready (Xcode not installed / not selected) |
| 4 | tool not found (tuist missing, etc.) |

## Commands

### `xcode create`
Scaffold a new Tuist-based iOS/macOS app and generate the Xcode project.

```bash
xcode create MyApp --platform ios --bundle-id com.example.myapp
xcode create MyLib --template package
```

Creates `MyApp/` in the current directory with a generated `.xcworkspace`.

### `xcode build`
Build the project in the current directory (auto-detects Tuist / xcworkspace / xcodeproj / SPM).

```bash
xcode build
xcode build --json   # { ok, exitCode }
```

### `xcode run`
Build for the iOS simulator and launch the app. Boots the simulator if needed.

```bash
xcode run                                       # auto-picks booted or first iPhone
xcode run --simulator "iPhone 17 Pro"
xcode run --simulator "iPhone 17 Pro" --scheme MyApp --bundle-id com.example.myapp
xcode run --json   # { scheme, appPath, bundleId, simulatorUDID, pid }
```

### `xcode test`
Run tests and surface per-test results with failure messages.

```bash
xcode test
xcode test --json   # { ok, exitCode, counts: { total, passed, failed, skipped }, tests: [...] }
```

Each test in the `tests` array: `{ identifier, name, status, duration, failureMessage? }`

### `xcode screenshot`
Capture a PNG screenshot of a running simulator.

```bash
xcode screenshot                                 # saves screenshot.png in cwd
xcode screenshot out.png
xcode screenshot --simulator "iPhone 17 Pro" out.png
xcode screenshot --json   # { simulatorUDID, path }
```

### `xcode log`
Stream live system logs from a simulator app. Exits when interrupted.

```bash
xcode log                                        # all logs from booted simulator
xcode log --bundle-id com.example.myapp          # filtered to the app
xcode log --simulator "iPhone 17 Pro" --bundle-id com.example.myapp
xcode log --bundle-id com.example.myapp --level error   # errors only
```

### `xcode simulator`
List, boot, and shut down simulators.

```bash
xcode simulator list
xcode simulator list --json   # raw simctl JSON
xcode simulator boot "iPhone 17 Pro"
xcode simulator shutdown all
```

### `xcode doctor`
Check toolchain readiness with actionable remediation hints.

```bash
xcode doctor
xcode doctor --json   # { fullXcode, simctl, tuist, issues: [...] }
```

### `xcode info`
Show active toolchain versions (Xcode, Swift, Tuist).

```bash
xcode info --json   # { developerDir, fullXcode, xcodebuild, swift, tuist }
```

## Agent workflow: create → run → verify

```bash
# 1. Scaffold and generate
xcode create HelloWorld --platform ios --bundle-id com.example.helloworld
cd HelloWorld

# 2. Build and launch on simulator
xcode run --simulator "iPhone 17 Pro" --json

# 3. Take a screenshot to verify visually
xcode screenshot verification.png

# 4. Stream logs while reproducing a bug
xcode log --bundle-id com.example.helloworld &
# ... trigger the bug ...
# kill %1

# 5. Run tests
xcode test --json
```

## Requirements

- Full Xcode (not just Command Line Tools). Run `xcode doctor` to verify.
- Tuist required for `xcode create`. Install: `brew install tuist`
- `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` if toolchain is wrong.
