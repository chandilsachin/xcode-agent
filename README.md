# xcode-agent

An **agent-friendly CLI for Xcode/iOS development** — the Apple-side counterpart to
Google's Android agent dev toolchain. It gives AI agents predictable, structured,
low-token access to the Apple toolchain (Swift, xcodebuild, simctl) and Tuist.

See [`DESIGN.md`](DESIGN.md) for the full spec and
[`android-agent-toolchain.md`](android-agent-toolchain.md) for the reference it mirrors.

## Build

```sh
swift build
# binary at .build/debug/xcode
```

## Commands

| Command | Description |
|---|---|
| `xcode doctor` | Toolchain readiness check with remediation hints |
| `xcode info` | Active toolchain versions |
| `xcode commands` | Self-describing command list (use `--json`) |
| `xcode create <Name>` | Scaffold a project and generate it with Tuist |
| `xcode build` | Build the project in the current directory |
| `xcode run` | Build & run (Swift packages; app run is a later milestone) |
| `xcode test` | Run tests and report a summary |
| `xcode simulator <list\|boot\|shutdown>` | Manage simulators (simctl) |
| `xcode skills <list\|show>` | Discover/read `SKILL.md` instruction sets |
| `xcode docs <query>` | Knowledge-base pointers |

### `create` flags

```
xcode create <Name> [--template app|package] [--platform ios|macos] [--bundle-id <id>] [--no-generate]
```

- `--template app` (default) → SwiftUI app via a Tuist `Project.swift` manifest, then
  `tuist generate` produces the `.xcodeproj`.
- `--template package` → a plain Swift Package (no Xcode/Tuist required).

## Agent-friendly I/O

- **`--json`** on any command → one JSON object on **stdout**; logs go to **stderr**.
- **Envelope:** `{ ok, command, data, error, hint }`.
- **Exit codes:** `0` ok · `1` runtime · `2` usage · `3` env-not-ready · `4` tool-not-found.
- Every failure carries a `hint` with the literal command to fix it.

```sh
xcode doctor --json        # machine-readable readiness
xcode commands --json      # discover available commands + flags
xcode build --json         # { ok, data:{ exitCode, counts } }
```

## Requirements

- macOS with the Swift toolchain (Command Line Tools is enough to build this CLI).
- Full Xcode for `simulator`, `xcodebuild`-backed `build`/`test`, and app `run`.
- [Tuist](https://tuist.io) for generating app projects from `create`.

Without full Xcode/Tuist the CLI still runs: package `build`/`test`, `doctor`, `info`,
`commands`, `skills`, and `docs` work; the rest exit with a clear install hint.
