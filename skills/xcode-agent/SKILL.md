---
name: xcode-agent
description: Use the xcode-agent CLI to create, build, run, test, screenshot, and stream logs for iOS/macOS apps
---

# xcode-agent CLI

`xcode` is an agent-friendly command-line tool for iOS/macOS development. It wraps
Xcode tooling (xcodebuild, simctl, xcresulttool, Tuist) in a stable, scriptable
interface with JSON output on every command.

## Discover capabilities

```bash
xcode-agent commands --json   # machine-readable list of all commands + flags
xcode-agent help              # human-readable overview
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

### `xcode-agent create`
Scaffold a new Tuist-based iOS/macOS app and generate the Xcode project.

```bash
xcode-agent create MyApp --platform ios --bundle-id com.example.myapp
xcode-agent create MyLib --template package
```

Creates `MyApp/` in the current directory with a generated `.xcworkspace`.

### `xcode-agent build`
Build the project in the current directory (auto-detects Tuist / xcworkspace / xcodeproj / SPM).

```bash
xcode-agent build
xcode-agent build --json   # { ok, exitCode }
```

### `xcode-agent run`
Build for the iOS simulator and launch the app. Boots the simulator if needed.

```bash
xcode-agent run                                       # auto-picks booted or first iPhone
xcode-agent run --simulator "iPhone 17 Pro"
xcode-agent run --simulator "iPhone 17 Pro" --scheme MyApp --bundle-id com.example.myapp
xcode-agent run --json   # { scheme, appPath, bundleId, simulatorUDID, pid }
```

### `xcode-agent test`
Run tests and surface per-test results with failure messages.

```bash
xcode-agent test
xcode-agent test --json   # { ok, exitCode, counts: { total, passed, failed, skipped }, tests: [...] }
```

Each test in the `tests` array: `{ identifier, name, status, duration, failureMessage? }`

### `xcode-agent screenshot`
Capture a PNG screenshot of a running simulator.

```bash
xcode-agent screenshot                                 # saves screenshot.png in cwd
xcode-agent screenshot out.png
xcode-agent screenshot --simulator "iPhone 17 Pro" out.png
xcode-agent screenshot --json   # { simulatorUDID, path }
```

### `xcode-agent log`
Stream live system logs from a simulator app. Exits when interrupted.

```bash
xcode-agent log                                        # all logs from booted simulator
xcode-agent log --bundle-id com.example.myapp          # filtered to the app
xcode-agent log --simulator "iPhone 17 Pro" --bundle-id com.example.myapp
xcode-agent log --bundle-id com.example.myapp --level error   # errors only
```

### `xcode-agent simulator`
List, boot, and shut down simulators.

```bash
xcode-agent simulator list
xcode-agent simulator list --json   # raw simctl JSON
xcode-agent simulator boot "iPhone 17 Pro"
xcode-agent simulator shutdown all
```

### `xcode-agent doctor`
Check toolchain readiness with actionable remediation hints.

```bash
xcode-agent doctor
xcode-agent doctor --json   # { fullXcode, simctl, tuist, issues: [...] }
```

### `xcode-agent info`
Show active toolchain versions (Xcode, Swift, Tuist).

```bash
xcode-agent info --json   # { developerDir, fullXcode, xcodebuild, swift, tuist }
```

## Agent workflow: create → run → verify

```bash
# 1. Scaffold and generate
xcode-agent create HelloWorld --platform ios --bundle-id com.example.helloworld
cd HelloWorld

# 2. Build and launch on simulator
xcode-agent run --simulator "iPhone 17 Pro" --json

# 3. Take a screenshot to verify visually
xcode-agent screenshot verification.png

# 4. Stream logs while reproducing a bug
xcode-agent log --bundle-id com.example.helloworld &
# ... trigger the bug ...
# kill %1

# 5. Run tests
xcode-agent test --json
```

## Requirements

- Full Xcode (not just Command Line Tools). Run `xcode-agent doctor` to verify.
- Tuist required for `xcode-agent create`. Install: `brew install tuist`
- `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` if toolchain is wrong.
