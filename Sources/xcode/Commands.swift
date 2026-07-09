import Foundation

// MARK: - Command registry (powers `xcode-agent commands` introspection)

struct CommandSpec {
    let name: String
    let summary: String
    let usage: String
    let flags: [String]
}

let commandRegistry: [CommandSpec] = [
    CommandSpec(name: "doctor", summary: "Check toolchain readiness with remediation hints",
                usage: "xcode-agent doctor", flags: ["--json"]),
    CommandSpec(name: "info", summary: "Show active toolchain versions",
                usage: "xcode-agent info", flags: ["--json"]),
    CommandSpec(name: "commands", summary: "List all commands (self-describing)",
                usage: "xcode-agent commands", flags: ["--json"]),
    CommandSpec(name: "version", summary: "Print the xcode-agent version",
                usage: "xcode-agent version", flags: ["--json"]),
    CommandSpec(name: "create", summary: "Scaffold a new project and generate it with Tuist",
                usage: "xcode-agent create <Name> [--template app|package] [--platform ios|macos] [--bundle-id <id>] [--no-generate]",
                flags: ["--template", "--platform", "--bundle-id", "--no-generate", "--json"]),
    CommandSpec(name: "build", summary: "Build the project in the current directory",
                usage: "xcode-agent build [extra tool args]", flags: ["--json"]),
    CommandSpec(name: "run", summary: "Build and run an app on simulator or physical device",
                usage: "xcode-agent run [--simulator <name|udid>] [--device <name|udid>] [--scheme <name>] [--bundle-id <id>] [extra xcodebuild args]",
                flags: ["--simulator", "--device", "--scheme", "--bundle-id", "--json"]),
    CommandSpec(name: "devices", summary: "List connected physical devices",
                usage: "xcode-agent devices", flags: ["--json"]),
    CommandSpec(name: "clean", summary: "Clean build artifacts for the project in the current directory",
                usage: "xcode-agent clean", flags: ["--json"]),
    CommandSpec(name: "open", summary: "Open the project in Xcode",
                usage: "xcode-agent open", flags: ["--json"]),
    CommandSpec(name: "lint", summary: "Run SwiftLint on the project (requires swiftlint on PATH)",
                usage: "xcode-agent lint [extra swiftlint args]", flags: ["--json"]),
    CommandSpec(name: "test", summary: "Run tests and report a summary",
                usage: "xcode-agent test [extra tool args]", flags: ["--json"]),
    CommandSpec(name: "simulator", summary: "Manage simulators (list/boot/shutdown)",
                usage: "xcode-agent simulator <list|boot|shutdown> [name|udid|all]", flags: ["--json"]),
    CommandSpec(name: "screenshot", summary: "Take a screenshot of a running simulator",
                usage: "xcode-agent screenshot [--simulator <name|udid>] [<output.png>]",
                flags: ["--simulator", "--json"]),
    CommandSpec(name: "log", summary: "Stream live logs from a simulator app",
                usage: "xcode-agent log [--simulator <name|udid>] [--bundle-id <id>] [extra log stream args]",
                flags: ["--simulator", "--bundle-id"]),
    CommandSpec(name: "skills", summary: "Discover and read SKILL.md instruction sets",
                usage: "xcode-agent skills <list|show> [name]", flags: ["--json"]),
    CommandSpec(name: "docs", summary: "Knowledge-base pointers for a query",
                usage: "xcode-agent docs <query>", flags: ["--json"]),
    CommandSpec(name: "ui", summary: "Inspect and interact with a simulator's UI",
                usage: "xcode-agent ui <describe|verify|tap|swipe|input|button|driver> [--simulator <name|udid>] ...",
                flags: ["--simulator", "--id", "--label", "--type", "--value", "--frame",
                        "--bundle-id", "--duration", "--delta", "--screenshot", "--idb", "--json"]),
]

// MARK: - Shared build/test runner (summary-only structured output)

/// Run a build/test-like tool. In JSON mode, captures output, forwards logs to
/// stderr, and emits a `{ ok, exitCode, counts }` summary on stdout. In human
/// mode, streams logs live and mirrors the tool's exit status.
func runToolWithSummary(command: String, tool: String, args: [String], _ ctx: Context) -> Never {
    if ctx.json {
        let result = Shell.run(tool, args)
        if !result.stdout.isEmpty { Out.stderr(result.stdout) }
        if !result.stderr.isEmpty { Out.stderr(result.stderr) }
        let ok = result.exitCode == 0
        var data: [String: Any] = ["exitCode": Int(result.exitCode)]
        if let counts = parseTestCounts(result.stdout + "\n" + result.stderr) {
            data["counts"] = counts
        }
        Out.printJSON(["ok": ok, "command": command, "data": data,
                       "error": ok ? NSNull() : "tool exited with status \(result.exitCode)",
                       "hint": NSNull()])
        exit(ok ? ExitCode.ok : ExitCode.runtime)
    } else {
        let code = Shell.runStreaming(tool, args)
        exit(code == 0 ? ExitCode.ok : ExitCode.runtime)
    }
}

/// Best-effort parse of `Executed N tests, with M failures` (xcodebuild/swift test).
func parseTestCounts(_ text: String) -> [String: Int]? {
    let pattern = #"Executed (\d+) test[s]?, with (\d+) failure"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard let match = matches.last else { return nil }
    let total = Int(ns.substring(with: match.range(at: 1))) ?? 0
    let failures = Int(ns.substring(with: match.range(at: 2))) ?? 0
    return ["total": total, "failures": failures, "passed": total - failures]
}

// MARK: - info / doctor / commands

enum InfoCommand {
    static func run(_ args: [String], _ ctx: Context) {
        let dev = Toolchain.developerDir ?? "(not set)"
        let xcodebuild = Toolchain.xcodebuildVersion ?? "(Xcode not installed — Command Line Tools only)"
        let swift = Toolchain.swiftVersion?.components(separatedBy: "\n").first ?? "(unknown)"
        let tuist = Toolchain.tuistPath ?? "(not installed)"
        let idb = Toolchain.which("idb") ?? "(not installed)"
        let swiftlint = Toolchain.which("swiftlint") ?? "(not installed)"
        let data: [String: Any] = [
            "developerDir": dev,
            "fullXcode": Toolchain.hasFullXcode,
            "xcodebuild": xcodebuild,
            "swift": swift,
            "tuist": tuist,
            "idb": idb,
            "swiftlint": swiftlint,
        ]
        let human = """
        xcode-agent — toolchain info
          developer dir : \(dev)
          full Xcode    : \(Toolchain.hasFullXcode ? "yes" : "no")
          xcodebuild    : \(xcodebuild)
          swift         : \(swift)
          tuist         : \(tuist)
          idb           : \(idb)
          swiftlint     : \(swiftlint)
        """
        Out.success("info", data: data, human: human, ctx)
    }
}

enum DoctorCommand {
    static func run(_ args: [String], _ ctx: Context) {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            checks.append(["name": name, "ok": pass, "detail": detail])
        }

        check("xcode-select", Toolchain.developerDir != nil,
              Toolchain.developerDir ?? "run: xcode-select --install")
        check("full Xcode", Toolchain.hasFullXcode,
              Toolchain.hasFullXcode ? "ok"
              : "install Xcode, then: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer")
        check("swift", Toolchain.swiftVersion != nil, Toolchain.swiftVersion != nil ? "ok" : "missing")
        check("simctl", Toolchain.hasSimctl, Toolchain.hasSimctl ? "ok" : "requires full Xcode")
        check("tuist", Toolchain.tuistPath != nil,
              Toolchain.tuistPath ?? "install: brew install tuist")
        check("idb", Toolchain.which("idb") != nil,
              Toolchain.which("idb") ?? "install: brew install facebook/fb/idb-companion && pip3 install fb-idb (required for `ui` commands)")
        check("swiftlint", Toolchain.which("swiftlint") != nil,
              Toolchain.which("swiftlint") ?? "install: brew install swiftlint (optional, required for `lint`)")

        let allOK = checks.allSatisfy { ($0["ok"] as? Bool) ?? false }
        if ctx.json {
            Out.printJSON(["ok": allOK, "command": "doctor",
                           "data": ["checks": checks], "error": NSNull(), "hint": NSNull()])
        } else {
            print("xcode-agent — doctor")
            for c in checks {
                let ok = (c["ok"] as? Bool) ?? false
                print("  [\(ok ? "✓" : "✗")] \(c["name"] as! String) — \(c["detail"] as! String)")
            }
            print(allOK ? "\nAll checks passed." : "\nSome checks need attention (see above).")
        }
        exit(allOK ? ExitCode.ok : ExitCode.envNotReady)
    }
}

enum CommandsCommand {
    static func run(_ args: [String], _ ctx: Context) {
        if ctx.json {
            let list = commandRegistry.map {
                ["name": $0.name, "summary": $0.summary, "usage": $0.usage, "flags": $0.flags]
            }
            Out.printJSON(["ok": true, "command": "commands",
                           "data": ["commands": list], "error": NSNull(), "hint": NSNull()])
        } else {
            print("xcode-agent — commands")
            for spec in commandRegistry {
                print("  \(spec.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(spec.summary)")
            }
        }
    }
}

// MARK: - create

enum CreateCommand {
    static func run(_ args: [String], _ ctx: Context) {
        var name: String?
        var template = "app"
        var platform = "ios"
        var bundleId: String?
        var generate = true

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--template": idx += 1; if idx < args.count { template = args[idx] }
            case "--platform": idx += 1; if idx < args.count { platform = args[idx] }
            case "--bundle-id": idx += 1; if idx < args.count { bundleId = args[idx] }
            case "--no-generate": generate = false
            default: if !arg.hasPrefix("-") && name == nil { name = arg }
            }
            idx += 1
        }

        guard let projectName = name else {
            Out.fail("create", error: "missing project name",
                     hint: "usage: xcode-agent create <Name> [--template app|package] [--platform ios|macos] [--bundle-id <id>] [--no-generate]",
                     code: ExitCode.usage, ctx)
        }
        guard ["app", "package"].contains(template) else {
            Out.fail("create", error: "unknown template '\(template)'",
                     hint: "use --template app or --template package", code: ExitCode.usage, ctx)
        }

        let fm = FileManager.default
        let dir = fm.currentDirectoryPath + "/" + projectName
        if fm.fileExists(atPath: dir) {
            Out.fail("create", error: "directory already exists: \(projectName)",
                     code: ExitCode.runtime, ctx)
        }
        let bid = bundleId ?? "com.example.\(projectName.lowercased())"

        do {
            if template == "package" {
                try Templates.scaffoldPackage(name: projectName, dir: dir)
            } else {
                try Templates.scaffoldTuistApp(name: projectName, dir: dir,
                                               platform: platform, bundleId: bid)
            }
        } catch {
            Out.fail("create", error: "failed to scaffold: \(error.localizedDescription)",
                     code: ExitCode.runtime, ctx)
        }

        var generated = false
        var note: String?
        if template == "app" && generate {
            if let tuist = Toolchain.tuistPath {
                // Tuist 4.x requires a .git directory to locate the project root.
                Shell.run("/usr/bin/git", ["init", "-q"], cwd: dir)
                let result = Shell.run(tuist, ["generate", "--no-open"], cwd: dir)
                if result.exitCode == 0 {
                    generated = true
                } else {
                    note = "tuist generate failed: "
                        + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                note = "tuist not installed — manifest written but project not generated "
                    + "(install: brew install tuist, then run `tuist generate`)"
            }
        }

        let data: [String: Any] = [
            "name": projectName, "path": dir, "template": template,
            "platform": platform, "bundleId": bid, "generated": generated,
        ]
        let human = """
        Created \(template) project '\(projectName)' at \(projectName)/
          bundle id : \(bid)
          generated : \(generated ? "yes" : "no")\(note.map { "  (\($0))" } ?? "")
        next: cd \(projectName) && xcode build
        """
        if ctx.json {
            Out.printJSON(["ok": true, "command": "create", "data": data,
                           "error": NSNull(), "hint": note as Any? ?? NSNull()])
        } else {
            Out.success("create", data: data, human: human, ctx)
        }
    }
}

// MARK: - build / run / test

enum BuildCommand {
    static func run(_ args: [String], _ ctx: Context) {
        switch Project.detect() {
        case .tuist:
            let tuist = requireTuist("build", ctx)
            runToolWithSummary(command: "build", tool: tuist, args: ["build"] + args, ctx)
        case .xcworkspace(let path):
            requireFullXcode("build", ctx)
            runToolWithSummary(command: "build", tool: "/usr/bin/xcrun",
                               args: ["xcodebuild", "-workspace", path, "build"] + args, ctx)
        case .xcodeproj(let path):
            requireFullXcode("build", ctx)
            runToolWithSummary(command: "build", tool: "/usr/bin/xcrun",
                               args: ["xcodebuild", "-project", path, "build"] + args, ctx)
        case .package:
            runToolWithSummary(command: "build", tool: "/usr/bin/xcrun",
                               args: ["swift", "build"] + args, ctx)
        case .none:
            Out.fail("build", error: "no project found in current directory",
                     hint: "run `xcode-agent create <Name>` or cd into a project", code: ExitCode.usage, ctx)
        }
    }
}

enum TestCommand {
    static func run(_ args: [String], _ ctx: Context) {
        switch Project.detect() {
        case .tuist:
            let tuist = requireTuist("test", ctx)
            runToolWithSummary(command: "test", tool: tuist, args: ["test"] + args, ctx)
        case .xcworkspace(let path):
            requireFullXcode("test", ctx)
            runXcodebuildTest(projectFlag: ["-workspace", path], extraArgs: args, ctx)
        case .xcodeproj(let path):
            requireFullXcode("test", ctx)
            runXcodebuildTest(projectFlag: ["-project", path], extraArgs: args, ctx)
        case .package:
            runToolWithSummary(command: "test", tool: "/usr/bin/xcrun",
                               args: ["swift", "test"] + args, ctx)
        case .none:
            Out.fail("test", error: "no project found in current directory",
                     hint: "run `xcode-agent create <Name>` or cd into a project", code: ExitCode.usage, ctx)
        }
    }

    /// Run `xcodebuild test` with a result bundle and surface per-test details via xcresulttool.
    static func runXcodebuildTest(projectFlag: [String], extraArgs: [String], _ ctx: Context) -> Never {
        let pid = ProcessInfo.processInfo.processIdentifier
        let xcresultPath = "/tmp/xcode-agent-test-\(pid).xcresult"
        let xcodebuildArgs = projectFlag + ["test", "-resultBundlePath", xcresultPath] + extraArgs

        let exitCode: Int32
        var capturedOutput = ""

        if ctx.json {
            let result = Shell.run("/usr/bin/xcrun", ["xcodebuild"] + xcodebuildArgs)
            if !result.stdout.isEmpty { Out.stderr(result.stdout) }
            if !result.stderr.isEmpty { Out.stderr(result.stderr) }
            capturedOutput = result.stdout + "\n" + result.stderr
            exitCode = result.exitCode
        } else {
            exitCode = Shell.runStreaming("/usr/bin/xcrun", ["xcodebuild"] + xcodebuildArgs)
        }

        let ok = exitCode == 0
        var data: [String: Any] = ["exitCode": Int(exitCode)]

        if let summary = XCResult.parse(path: xcresultPath) {
            data["counts"] = [
                "total":   summary.totalTests,
                "passed":  summary.passed,
                "failed":  summary.failed,
                "skipped": summary.skipped,
            ]
            data["durationSeconds"] = summary.durationSeconds
            data["tests"] = summary.tests.map { $0.jsonDict }
            if !ctx.json { printTestSummaryHuman(summary) }
        } else if let counts = parseTestCounts(capturedOutput) {
            data["counts"] = counts
        }

        if ctx.json {
            Out.printJSON(["ok": ok, "command": "test", "data": data,
                           "error": ok ? NSNull() : "tests failed with exit code \(exitCode)",
                           "hint": NSNull()])
        }

        try? FileManager.default.removeItem(atPath: xcresultPath)
        exit(ok ? ExitCode.ok : ExitCode.runtime)
    }

    static func printTestSummaryHuman(_ summary: XCResult.Summary) {
        print("\n── Test Results ─────────────────────────")
        print("  passed  : \(summary.passed) / \(summary.totalTests)")
        if summary.skipped > 0 { print("  skipped : \(summary.skipped)") }
        print(String(format: "  duration: %.2fs", summary.durationSeconds))
        let failed = summary.tests.filter { $0.status == "failed" }
        if !failed.isEmpty {
            print("\nFailed:")
            for t in failed {
                print("  ✗ \(t.identifier)")
                if let msg = t.failureMessage { print("    \(msg)") }
            }
        }
    }
}

enum RunCommand {
    static func run(_ args: [String], _ ctx: Context) {
        var simulatorTarget: String?
        var deviceTarget: String?
        var scheme: String?
        var bundleId: String?
        var extraArgs: [String] = []

        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator": idx += 1; if idx < args.count { simulatorTarget = args[idx] }
            case "--device":    idx += 1; if idx < args.count { deviceTarget = args[idx] }
            case "--scheme":    idx += 1; if idx < args.count { scheme = args[idx] }
            case "--bundle-id": idx += 1; if idx < args.count { bundleId = args[idx] }
            default: extraArgs.append(args[idx])
            }
            idx += 1
        }

        let project = Project.detect()
        switch project {
        case .package:
            runToolWithSummary(command: "run", tool: "/usr/bin/xcrun",
                               args: ["swift", "run"] + extraArgs, ctx)
        case .tuist, .xcworkspace, .xcodeproj:
            requireFullXcode("run", ctx)
            if let device = deviceTarget {
                runAppOnDevice(project: project, deviceTarget: device,
                               scheme: scheme, bundleId: bundleId, extraArgs: extraArgs, ctx)
            } else {
                runAppOnSimulator(project: project, simulatorTarget: simulatorTarget,
                                  scheme: scheme, bundleId: bundleId, extraArgs: extraArgs, ctx)
            }
        case .none:
            Out.fail("run", error: "no project found in current directory",
                     hint: "run `xcode-agent create <Name>`", code: ExitCode.usage, ctx)
        }
    }

    static func runAppOnSimulator(project: ProjectKind, simulatorTarget: String?,
                                   scheme: String?, bundleId: String?,
                                   extraArgs: [String], _ ctx: Context) -> Never {
        let schemeName: String
        if let s = scheme {
            schemeName = s
        } else if let inferred = inferScheme() {
            schemeName = inferred
        } else {
            Out.fail("run", error: "could not infer scheme — pass --scheme <name>",
                     hint: "run `xcrun xcodebuild -list` to see available schemes",
                     code: ExitCode.runtime, ctx)
        }

        let projectFlag: [String]
        switch project {
        case .xcworkspace(let path): projectFlag = ["-workspace", path]
        case .xcodeproj(let path):  projectFlag = ["-project", path]
        case .tuist:
            guard let ws = findWorkspaceInCwd() else {
                Out.fail("run", error: "no .xcworkspace found in current directory",
                         hint: "run `tuist generate` first", code: ExitCode.runtime, ctx)
            }
            projectFlag = ["-workspace", ws]
        default:
            Out.fail("run", error: "unexpected project type", code: ExitCode.runtime, ctx)
        }

        let derivedDataPath = "/tmp/xcode-agent-run-\(schemeName)"
        let buildArgs = projectFlag + [
            "-scheme", schemeName,
            "-sdk", "iphonesimulator",
            "-configuration", "Debug",
            "-derivedDataPath", derivedDataPath,
        ] + extraArgs + ["build"]

        Out.stderr("Building '\(schemeName)' for iphonesimulator…")
        let buildResult = Shell.run("/usr/bin/xcrun", ["xcodebuild"] + buildArgs)
        guard buildResult.exitCode == 0 else {
            if !buildResult.stderr.isEmpty { Out.stderr(buildResult.stderr) }
            Out.fail("run", error: "build failed (exit \(buildResult.exitCode))",
                     hint: "run `xcode-agent build` for full diagnostics", code: ExitCode.runtime, ctx)
        }

        guard let appPath = findApp(in: derivedDataPath, scheme: schemeName) else {
            Out.fail("run", error: "could not locate .app under \(derivedDataPath)/Build/Products/",
                     hint: "verify scheme '\(schemeName)' has an app target that builds for simulator",
                     code: ExitCode.runtime, ctx)
        }

        let resolvedBundleId = bundleId ?? readBundleId(from: appPath)
        guard let bid = resolvedBundleId else {
            Out.fail("run", error: "could not read CFBundleIdentifier from \(appPath)/Info.plist",
                     hint: "pass --bundle-id <id> explicitly", code: ExitCode.runtime, ctx)
        }

        let simUDID = findOrBootSimulator(target: simulatorTarget, ctx)

        Out.stderr("Installing on simulator \(simUDID)…")
        let installResult = Shell.run("/usr/bin/xcrun", ["simctl", "install", simUDID, appPath])
        guard installResult.exitCode == 0 else {
            Out.fail("run", error: "simctl install failed: \(installResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                     code: ExitCode.runtime, ctx)
        }

        Out.stderr("Launching \(bid)…")
        let launchResult = Shell.run("/usr/bin/xcrun", ["simctl", "launch", simUDID, bid])
        let pid = launchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok  = launchResult.exitCode == 0
        if ok { UIDriver.recordLaunchedApp(bundleId: bid, udid: simUDID) }

        let data: [String: Any] = [
            "scheme":         schemeName,
            "appPath":        appPath,
            "bundleId":       bid,
            "simulatorUDID":  simUDID,
            "pid":            pid,
        ]
        Out.success("run", data: data, human: """
            Launched '\(schemeName)' on \(simUDID)
              bundle id : \(bid)
              pid       : \(pid.isEmpty ? "(unknown)" : pid)
            """, ctx)
        exit(ok ? ExitCode.ok : ExitCode.runtime)
    }

    /// Returns the first scheme from `xcodebuild -list`, or nil on failure.
    static func inferScheme() -> String? {
        let result = Shell.run("/usr/bin/xcrun", ["xcodebuild", "-list", "-json"])
        guard result.exitCode == 0,
              let data      = result.stdout.data(using: .utf8),
              let json      = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = (json["project"] ?? json["workspace"]) as? [String: Any],
              let schemes   = container["schemes"] as? [String]
        else { return nil }
        return schemes.first
    }

    /// Finds the first `.xcworkspace` in the current directory (generated by Tuist).
    static func findWorkspaceInCwd() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: cwd) else { return nil }
        return entries.first(where: { $0.hasSuffix(".xcworkspace") }).map { cwd + "/" + $0 }
    }

    /// Finds the built `.app` under `<derivedDataPath>/Build/Products/*-iphonesimulator/`.
    static func findApp(in derivedDataPath: String, scheme: String) -> String? {
        let searchBase = derivedDataPath + "/Build/Products"
        let fm = FileManager.default
        guard let configs = try? fm.contentsOfDirectory(atPath: searchBase) else { return nil }
        for config in configs.sorted().reversed() where config.contains("iphonesimulator") {
            let configPath = searchBase + "/" + config
            guard let apps = try? fm.contentsOfDirectory(atPath: configPath) else { continue }
            if let exact = apps.first(where: { $0 == scheme + ".app" }) { return configPath + "/" + exact }
            if let any   = apps.first(where: { $0.hasSuffix(".app")   }) { return configPath + "/" + any   }
        }
        return nil
    }

    /// Reads `CFBundleIdentifier` from an `.app`'s `Info.plist`.
    static func readBundleId(from appPath: String) -> String? {
        let plistPath = appPath + "/Info.plist"
        guard let data  = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// Boot a simulator, tolerating the "already booted" case.
    static func bootSimulator(udid: String, command: String, _ ctx: Context) {
        let result = Shell.run("/usr/bin/xcrun", ["simctl", "boot", udid])
        // simctl boot exits 149 (or mentions "current state: Booted") when already booted — not an error.
        if result.exitCode != 0 && !result.stderr.contains("Booted") {
            Out.fail(command,
                     error: "failed to boot simulator \(udid): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                     hint: "run `xcode-agent simulator list` to check device state",
                     code: ExitCode.runtime, ctx)
        }
    }

    /// Returns a booted simulator UDID, booting one if necessary.
    /// `command` is the caller's command name, used in error envelopes.
    static func findOrBootSimulator(target: String?, command: String = "run", _ ctx: Context) -> String {
        let result = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"])
        guard result.exitCode == 0,
              let data    = result.stdout.data(using: .utf8),
              let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]]
        else {
            Out.fail(command, error: "could not list simulators",
                     hint: "check that simctl is available (requires full Xcode)", code: ExitCode.envNotReady, ctx)
        }

        let all = devices.values.flatMap { $0 }

        if let target = target {
            guard let sim  = all.first(where: {
                      ($0["udid"] as? String) == target || ($0["name"] as? String) == target
                  }),
                  let udid = sim["udid"] as? String else {
                Out.fail(command, error: "simulator not found: '\(target)'",
                         hint: "run `xcode-agent simulator list` to see available devices",
                         code: ExitCode.runtime, ctx)
            }
            if (sim["state"] as? String) != "Booted" {
                bootSimulator(udid: udid, command: command, ctx)
            }
            return udid
        }

        // Prefer an already-booted simulator
        if let booted = all.first(where: { ($0["state"] as? String) == "Booted" }),
           let udid   = booted["udid"] as? String { return udid }

        // Boot the first available iPhone on the latest iOS runtime
        for runtime in devices.keys.filter({ $0.contains("iOS") }).sorted().reversed() {
            if let sims = devices[runtime],
               let sim  = sims.first(where: { ($0["name"] as? String ?? "").contains("iPhone") }),
               let udid = sim["udid"] as? String {
                Out.stderr("Booting \(sim["name"] as? String ?? udid)…")
                bootSimulator(udid: udid, command: command, ctx)
                return udid
            }
        }

        Out.fail(command, error: "no iOS simulator available",
                 hint: "install a simulator runtime in Xcode Settings → Platforms",
                 code: ExitCode.envNotReady, ctx)
    }

    // MARK: Physical device

    static func runAppOnDevice(project: ProjectKind, deviceTarget: String,
                                scheme: String?, bundleId: String?,
                                extraArgs: [String], _ ctx: Context) -> Never {
        let schemeName: String
        if let s = scheme {
            schemeName = s
        } else if let inferred = inferScheme() {
            schemeName = inferred
        } else {
            Out.fail("run", error: "could not infer scheme — pass --scheme <name>",
                     hint: "run `xcrun xcodebuild -list` to see available schemes",
                     code: ExitCode.runtime, ctx)
        }

        let projectFlag: [String]
        switch project {
        case .xcworkspace(let path): projectFlag = ["-workspace", path]
        case .xcodeproj(let path):  projectFlag = ["-project", path]
        case .tuist:
            guard let ws = findWorkspaceInCwd() else {
                Out.fail("run", error: "no .xcworkspace found — run `tuist generate` first",
                         code: ExitCode.runtime, ctx)
            }
            projectFlag = ["-workspace", ws]
        default:
            Out.fail("run", error: "unexpected project type", code: ExitCode.runtime, ctx)
        }

        let derivedDataPath = "/tmp/xcode-agent-device-\(schemeName)"
        let buildArgs = projectFlag + [
            "-scheme", schemeName,
            "-sdk", "iphoneos",
            "-configuration", "Debug",
            "-derivedDataPath", derivedDataPath,
            "-allowProvisioningUpdates",
        ] + extraArgs + ["build"]

        Out.stderr("Building '\(schemeName)' for iphoneos…")
        let buildResult = Shell.run("/usr/bin/xcrun", ["xcodebuild"] + buildArgs)
        guard buildResult.exitCode == 0 else {
            if !buildResult.stderr.isEmpty { Out.stderr(buildResult.stderr) }
            Out.fail("run", error: "build failed (exit \(buildResult.exitCode))",
                     hint: "ensure the scheme has a signing team set, or pass -allowProvisioningUpdates",
                     code: ExitCode.runtime, ctx)
        }

        // Find the .app under Build/Products/Debug-iphoneos/
        let searchBase = derivedDataPath + "/Build/Products"
        let fm = FileManager.default
        var appPath: String?
        if let configs = try? fm.contentsOfDirectory(atPath: searchBase) {
            for config in configs.sorted().reversed() where config.contains("iphoneos") {
                let configPath = searchBase + "/" + config
                if let apps = try? fm.contentsOfDirectory(atPath: configPath),
                   let app = apps.first(where: { $0.hasSuffix(".app") }) {
                    appPath = configPath + "/" + app; break
                }
            }
        }
        guard let app = appPath else {
            Out.fail("run", error: "could not locate .app under \(searchBase)",
                     hint: "verify the scheme builds an app target for iphoneos",
                     code: ExitCode.runtime, ctx)
        }

        let bid = bundleId ?? readBundleId(from: app)
        guard let finalBid = bid else {
            Out.fail("run", error: "could not read CFBundleIdentifier from \(app)/Info.plist",
                     hint: "pass --bundle-id <id> explicitly", code: ExitCode.runtime, ctx)
        }

        let deviceUDID = findDevice(target: deviceTarget, ctx)

        Out.stderr("Installing on device \(deviceUDID)…")
        let installResult = Shell.run("/usr/bin/xcrun",
            ["devicectl", "device", "install", "app", "--device", deviceUDID, app])
        guard installResult.exitCode == 0 else {
            Out.fail("run",
                     error: "devicectl install failed: \(installResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                     code: ExitCode.runtime, ctx)
        }

        Out.stderr("Launching \(finalBid)…")
        let launchResult = Shell.run("/usr/bin/xcrun",
            ["devicectl", "device", "process", "launch",
             "--terminate-existing", "--device", deviceUDID, finalBid])
        let ok = launchResult.exitCode == 0
        let pid = launchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let data: [String: Any] = [
            "scheme": schemeName, "appPath": app,
            "bundleId": finalBid, "deviceUDID": deviceUDID, "pid": pid,
        ]
        Out.success("run", data: data, human: """
            Launched '\(schemeName)' on device \(deviceUDID)
              bundle id : \(finalBid)
              pid       : \(pid.isEmpty ? "(unknown)" : pid)
            """, ctx)
        exit(ok ? ExitCode.ok : ExitCode.runtime)
    }

    /// Returns a device UDID matching the given name or UDID string, or exits with an error.
    static func findDevice(target: String, _ ctx: Context) -> String {
        let tmpPath = "/tmp/xcode-agent-devices.json"
        let result = Shell.run("/usr/bin/xcrun",
            ["devicectl", "device", "list", "--json-output", tmpPath])
        guard result.exitCode == 0,
              let data = FileManager.default.contents(atPath: tmpPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceList = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]]
        else {
            Out.fail("run", error: "could not list devices — is a device connected?",
                     hint: "connect your iPhone and trust this Mac, then retry",
                     code: ExitCode.envNotReady, ctx)
        }
        try? FileManager.default.removeItem(atPath: tmpPath)

        if let device = deviceList.first(where: {
            ($0["udid"] as? String) == target ||
            ($0["deviceProperties"] as? [String: Any])?["name"] as? String == target
        }), let udid = device["udid"] as? String {
            return udid
        }

        Out.fail("run", error: "device not found: '\(target)'",
                 hint: "run `xcode-agent devices` to list connected devices",
                 code: ExitCode.runtime, ctx)
    }
}

// MARK: - devices

enum DevicesCommand {
    static func run(_ args: [String], _ ctx: Context) {
        requireFullXcode("devices", ctx)
        let tmpPath = "/tmp/xcode-agent-devices.json"
        let result = Shell.run("/usr/bin/xcrun",
            ["devicectl", "device", "list", "--json-output", tmpPath])
        guard result.exitCode == 0,
              let data = FileManager.default.contents(atPath: tmpPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceList = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]]
        else {
            if ctx.json {
                Out.printJSON(["ok": false, "command": "devices",
                               "data": ["devices": []],
                               "error": "no devices found — connect an iPhone and trust this Mac",
                               "hint": NSNull()])
            } else {
                print("No devices found. Connect an iPhone/iPad and trust this Mac.")
            }
            try? FileManager.default.removeItem(atPath: tmpPath)
            exit(ExitCode.ok)
        }
        try? FileManager.default.removeItem(atPath: tmpPath)

        let devices: [[String: Any]] = deviceList.compactMap { d in
            guard let udid = d["udid"] as? String,
                  let props = d["deviceProperties"] as? [String: Any],
                  let name = props["name"] as? String else { return nil }
            let os = (d["hardwareProperties"] as? [String: Any])?["cpuType"] as? String ?? ""
            let osVersion = props["osVersionNumber"] as? String ?? ""
            return ["udid": udid, "name": name, "osVersion": osVersion, "cpuType": os]
        }

        if ctx.json {
            Out.printJSON(["ok": true, "command": "devices",
                           "data": ["devices": devices],
                           "error": NSNull(), "hint": NSNull()])
        } else {
            if devices.isEmpty {
                print("No devices found. Connect an iPhone/iPad and trust this Mac.")
            } else {
                print("Connected devices:")
                for d in devices {
                    let name = d["name"] as? String ?? ""
                    let udid = d["udid"] as? String ?? ""
                    let os   = d["osVersion"] as? String ?? ""
                    print("  \(name) (\(os))  \(udid)")
                }
            }
        }
        exit(ExitCode.ok)
    }
}

// MARK: - clean

enum CleanCommand {
    static func run(_ args: [String], _ ctx: Context) {
        switch Project.detect() {
        case .tuist:
            let tuist = requireTuist("clean", ctx)
            runToolWithSummary(command: "clean", tool: tuist, args: ["clean"], ctx)
        case .xcworkspace(let path):
            requireFullXcode("clean", ctx)
            runToolWithSummary(command: "clean", tool: "/usr/bin/xcrun",
                               args: ["xcodebuild", "-workspace", path, "clean"], ctx)
        case .xcodeproj(let path):
            requireFullXcode("clean", ctx)
            runToolWithSummary(command: "clean", tool: "/usr/bin/xcrun",
                               args: ["xcodebuild", "-project", path, "clean"], ctx)
        case .package:
            runToolWithSummary(command: "clean", tool: "/usr/bin/xcrun",
                               args: ["swift", "package", "clean"], ctx)
        case .none:
            Out.fail("clean", error: "no project found in current directory",
                     hint: "cd into a project directory", code: ExitCode.usage, ctx)
        }
    }
}

// MARK: - open

enum OpenCommand {
    static func openPath(_ path: String, _ ctx: Context) -> Never {
        let result = Shell.run("/usr/bin/open", [path])
        guard result.exitCode == 0 else {
            Out.fail("open",
                     error: "open failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                     code: ExitCode.runtime, ctx)
        }
        Out.success("open", data: ["path": path], human: "Opened \(path)", ctx)
        exit(ExitCode.ok)
    }

    static func run(_ args: [String], _ ctx: Context) {
        let cwd = FileManager.default.currentDirectoryPath
        let fm  = FileManager.default

        // Prefer workspace (Tuist / CocoaPods generate one)
        if let entries = try? fm.contentsOfDirectory(atPath: cwd) {
            if let ws = entries.first(where: { $0.hasSuffix(".xcworkspace") }) {
                openPath(cwd + "/" + ws, ctx)
            }
            if let proj = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
                openPath(cwd + "/" + proj, ctx)
            }
        }
        if fm.fileExists(atPath: cwd + "/Package.swift") {
            openPath(cwd + "/Package.swift", ctx)
        }
        Out.fail("open", error: "no Xcode project found in current directory",
                 hint: "cd into a project or run `xcode-agent create <Name>`", code: ExitCode.usage, ctx)
    }
}

// MARK: - lint

enum LintCommand {
    static func run(_ args: [String], _ ctx: Context) {
        guard let swiftlint = Toolchain.which("swiftlint") else {
            Out.fail("lint", error: "swiftlint not found on PATH",
                     hint: "install: brew install swiftlint", code: ExitCode.toolNotFound, ctx)
        }
        runToolWithSummary(command: "lint", tool: swiftlint, args: args, ctx)
    }
}

// MARK: - screenshot

enum ScreenshotCommand {
    static func run(_ args: [String], _ ctx: Context) {
        requireFullXcode("screenshot", ctx)

        var simulatorTarget: String?
        var outputPath: String?
        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator": idx += 1; if idx < args.count { simulatorTarget = args[idx] }
            default:
                if !args[idx].hasPrefix("-") && outputPath == nil { outputPath = args[idx] }
            }
            idx += 1
        }

        let simUDID = RunCommand.findOrBootSimulator(target: simulatorTarget, command: "screenshot", ctx)
        let path = outputPath ?? (FileManager.default.currentDirectoryPath + "/screenshot.png")

        let result = Shell.run("/usr/bin/xcrun", ["simctl", "io", simUDID, "screenshot", path])
        guard result.exitCode == 0 else {
            Out.fail("screenshot",
                     error: "simctl io screenshot failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                     code: ExitCode.runtime, ctx)
        }

        let data: [String: Any] = ["simulatorUDID": simUDID, "path": path]
        Out.success("screenshot", data: data, human: "Screenshot saved to \(path)", ctx)
        exit(ExitCode.ok)
    }
}

// MARK: - log

enum LogCommand {
    static func run(_ args: [String], _ ctx: Context) {
        requireFullXcode("log", ctx)

        var simulatorTarget: String?
        var bundleId: String?
        var extraArgs: [String] = []
        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator": idx += 1; if idx < args.count { simulatorTarget = args[idx] }
            case "--bundle-id": idx += 1; if idx < args.count { bundleId = args[idx] }
            default: extraArgs.append(args[idx])
            }
            idx += 1
        }

        let simUDID = RunCommand.findOrBootSimulator(target: simulatorTarget, command: "log", ctx)

        // `simctl spawn <udid> log stream` runs the host's `log` tool inside
        // the simulator's process namespace, giving us the simulator's unified log.
        var logArgs = ["simctl", "spawn", simUDID, "log", "stream", "--level", "debug"]
        if let bid = bundleId {
            // Filter to the specific app via its bundle ID subsystem or image path.
            // Escape quotes/backslashes so the value can't break out of the predicate string.
            let escaped = bid.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
            logArgs += ["--predicate",
                        "subsystem == \"\(escaped)\" OR processImagePath CONTAINS \"\(escaped)\""]
        }
        logArgs += extraArgs

        exit(Shell.runStreaming("/usr/bin/xcrun", logArgs))
    }
}

// MARK: - simulator

enum SimulatorCommand {
    static func run(_ args: [String], _ ctx: Context) {
        guard Toolchain.hasSimctl else {
            Out.fail("simulator", error: "simctl not available",
                     hint: "requires full Xcode (sudo xcode-select -s /Applications/Xcode.app/Contents/Developer)",
                     code: ExitCode.envNotReady, ctx)
        }
        let action = args.first ?? "list"
        let rest = Array(args.dropFirst())
        switch action {
        case "list":
            if ctx.json {
                let result = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"])
                guard result.exitCode == 0,
                      let data = result.stdout.data(using: .utf8),
                      let raw  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let devs = raw["devices"] as? [String: [[String: Any]]]
                else {
                    Out.printJSON(["ok": false, "command": "simulator list",
                                   "data": ["devices": [:]], "error": "simctl failed", "hint": NSNull()])
                    exit(ExitCode.runtime)
                }
                // Flatten to a list of {name, udid, state, runtime} for agent convenience
                let flat: [[String: Any]] = devs.flatMap { runtime, sims in
                    sims.map { s in
                        ["name": s["name"] as? String ?? "",
                         "udid": s["udid"] as? String ?? "",
                         "state": s["state"] as? String ?? "",
                         "runtime": runtime]
                    }
                }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
                Out.printJSON(["ok": true, "command": "simulator list",
                               "data": ["devices": flat], "error": NSNull(), "hint": NSNull()])
            } else {
                exit(Shell.runStreaming("/usr/bin/xcrun", ["simctl", "list", "devices", "available"]))
            }
        case "boot":
            guard let target = rest.first else {
                Out.fail("simulator", error: "missing simulator",
                         hint: "usage: xcode-agent simulator boot <udid|name>", code: ExitCode.usage, ctx)
            }
            let result = Shell.run("/usr/bin/xcrun", ["simctl", "boot", target])
            // Exit code 149 / "current state: Booted" means already booted — treat as success.
            let ok = result.exitCode == 0 || result.stderr.contains("Booted")
            if !ok {
                Out.fail("simulator boot",
                         error: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                         code: ExitCode.runtime, ctx)
            }
            Out.success("simulator boot", data: ["target": target],
                        human: "✓ booted \(target)", ctx)
            exit(ExitCode.ok)
        case "shutdown":
            let target = rest.first ?? "all"
            let result = Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", target])
            // "current state: Shutdown" means already shut down — treat as success.
            let ok = result.exitCode == 0 || result.stderr.contains("Shutdown")
            if !ok {
                Out.fail("simulator shutdown",
                         error: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                         code: ExitCode.runtime, ctx)
            }
            Out.success("simulator shutdown", data: ["target": target],
                        human: "✓ shut down \(target)", ctx)
            exit(ExitCode.ok)
        default:
            Out.fail("simulator", error: "unknown action '\(action)'",
                     hint: "use: list | boot | shutdown", code: ExitCode.usage, ctx)
        }
    }
}

// MARK: - skills

enum SkillsCommand {
    struct Skill { let name: String; let description: String; let path: String }

    static func searchDirs() -> [String] {
        var dirs = [FileManager.default.currentDirectoryPath + "/skills"]
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            dirs.append(home + "/.xcode-agent/skills")
        }
        return dirs
    }

    static func run(_ args: [String], _ ctx: Context) {
        let action = args.first ?? "list"
        switch action {
        case "list":
            let skills = discover()
            if ctx.json {
                Out.printJSON(["ok": true, "command": "skills",
                               "data": ["skills": skills.map {
                                   ["name": $0.name, "description": $0.description, "path": $0.path]
                               }], "error": NSNull(), "hint": NSNull()])
            } else if skills.isEmpty {
                print("No skills found. Add SKILL.md files under ./skills/<name>/")
            } else {
                print("xcode-agent — skills")
                for s in skills { print("  \(s.name) — \(s.description)") }
            }
        case "show":
            guard let target = args.dropFirst().first else {
                Out.fail("skills", error: "missing skill name",
                         hint: "usage: xcode-agent skills show <name>", code: ExitCode.usage, ctx)
            }
            guard let skill = discover().first(where: { $0.name == target }),
                  let content = try? String(contentsOfFile: skill.path, encoding: .utf8) else {
                Out.fail("skills", error: "skill not found: \(target)",
                         hint: "run `xcode-agent skills list`", code: ExitCode.runtime, ctx)
            }
            print(content)
        default:
            Out.fail("skills", error: "unknown action '\(action)'",
                     hint: "use: list | show", code: ExitCode.usage, ctx)
        }
    }

    static func discover() -> [Skill] {
        let fm = FileManager.default
        var result: [Skill] = []
        for dir in searchDirs() {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries.sorted() {
                let path = dir + "/" + entry + "/SKILL.md"
                guard fm.fileExists(atPath: path),
                      let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let (name, desc) = parseFrontmatter(content, fallbackName: entry)
                result.append(Skill(name: name, description: desc, path: path))
            }
        }
        return result
    }

    static func parseFrontmatter(_ content: String, fallbackName: String) -> (String, String) {
        var name = fallbackName
        var description = ""
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { return (name, description) }
        for line in lines.dropFirst() {
            if line == "---" { break }
            if line.hasPrefix("name:") {
                name = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("description:") {
                description = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return (name, description)
    }
}

// MARK: - ui (describe / verify)

enum UICommand {
    // idb element keys vary by version; normalise here.
    static func elementType(_ el: [String: Any]) -> String {
        (el["type"] as? String) ?? (el["type_"] as? String) ?? "Unknown"
    }
    static func elementLabel(_ el: [String: Any]) -> String {
        (el["AXLabel"] as? String)               // idb 1.1.x
            ?? (el["accessibility_label"] as? String)
            ?? (el["content"] as? String)
            ?? (el["label"] as? String) ?? ""
    }
    static func elementValue(_ el: [String: Any]) -> String {
        (el["AXValue"] as? String) ?? (el["value"] as? String) ?? ""
    }
    static func elementID(_ el: [String: Any]) -> String {
        (el["AXUniqueId"] as? String) ?? ""
    }
    static func elementBounds(_ el: [String: Any]) -> [String: Double]? {
        func extract(_ d: [String: Any]) -> [String: Double] {
            ["x":      (d["x"]      as? Double) ?? 0,
             "y":      (d["y"]      as? Double) ?? 0,
             "width":  (d["width"]  as? Double) ?? 0,
             "height": (d["height"] as? Double) ?? 0]
        }
        if let b = el["bounds"] as? [String: Any] { return extract(b) }
        if let f = el["frame"]  as? [String: Any] { return extract(f) }
        return nil
    }
    static func elementChildren(_ el: [String: Any]) -> [[String: Any]] {
        (el["children"] as? [[String: Any]]) ?? []
    }

    /// Format a bounds dict as `x=X y=Y W×H` without force-unwrapping.
    static func frameString(_ f: [String: Double]) -> String {
        "x=\(Int(f["x"] ?? 0)) y=\(Int(f["y"] ?? 0)) \(Int(f["width"] ?? 0))×\(Int(f["height"] ?? 0))"
    }

    static func requireIDB(_ ctx: Context) -> String {
        guard let idb = Toolchain.which("idb") else {
            Out.fail("ui", error: "idb not found on PATH",
                     hint: "install: brew install facebook/fb/idb-companion && pip3 install fb-idb",
                     code: ExitCode.toolNotFound, ctx)
        }
        return idb
    }

    static func fetchHierarchy(udid: String, idb: String, _ ctx: Context) -> [[String: Any]] {
        let result = Shell.run(idb, ["ui", "describe-all", "--udid", udid])
        guard result.exitCode == 0 else {
            Out.fail("ui",
                     error: "idb ui describe-all failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                     hint: "ensure a simulator is booted and idb-companion is installed on this Mac",
                     code: ExitCode.runtime, ctx)
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            Out.fail("ui", error: "could not parse idb output as JSON", code: ExitCode.runtime, ctx)
        }
        if let array = json as? [[String: Any]] { return array }
        if let obj = json as? [String: Any] {
            if let items = obj["elements"] as? [[String: Any]] { return items }
            return [obj]
        }
        return []
    }

    /// Fetch the accessibility hierarchy from the XCUITest driver for a given
    /// app. Returns nil when no target app is resolvable (caller falls back to
    /// idb). The driver returns already-nested elements in `ui describe` shape.
    static func fetchHierarchyViaDriver(udid: String, bundleIdFlag: String?,
                                        command: String, _ ctx: Context) -> [[String: Any]]? {
        guard let bundleId = bundleIdFlag ?? UIDriver.lastLaunchedBundleId(udid: udid),
              !bundleId.isEmpty else { return nil }
        let port = UIDriver.ensureRunning(udid: udid, command: command, ctx)
        guard let response = UIDriver.request(port: port, method: "POST", path: "/hierarchy",
                                              body: ["bundleId": bundleId], timeout: 30) else {
            return nil
        }
        guard response.ok, let elements = response.payload["elements"] as? [[String: Any]] else {
            if let err = response.error {
                Out.stderr("warning: driver hierarchy failed (\(err)); falling back to idb")
            }
            return nil
        }
        return elements
    }

    static func flatten(_ elements: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for el in elements {
            result.append(el)
            result.append(contentsOf: flatten(elementChildren(el)))
        }
        return result
    }

    // MARK: Spatial tree reconstruction
    // idb describe-all returns a flat list; rebuild hierarchy by frame containment.

    static func frameArea(_ f: [String: Double]?) -> Double {
        guard let f else { return 0 }
        return (f["width"] ?? 0) * (f["height"] ?? 0)
    }

    static func frameContains(outer: [String: Double], inner: [String: Double]) -> Bool {
        let ox = outer["x"] ?? 0, oy = outer["y"] ?? 0
        let ow = outer["width"] ?? 0, oh = outer["height"] ?? 0
        let ix = inner["x"] ?? 0, iy = inner["y"] ?? 0
        let iw = inner["width"] ?? 0, ih = inner["height"] ?? 0
        return ox <= ix && oy <= iy && (ox + ow) >= (ix + iw) && (oy + oh) >= (iy + ih)
    }

    static func buildSpatialTree(_ flat: [[String: Any]]) -> [[String: Any]] {
        guard !flat.isEmpty else { return [] }
        let n = flat.count
        let bounds = flat.map { elementBounds($0) }
        let areas  = bounds.map { frameArea($0) }

        // For each element, find its direct parent: the smallest element that fully contains it.
        var parentOf = Array(repeating: -1, count: n)
        for i in 0..<n {
            guard let ib = bounds[i], areas[i] > 0 else { continue }
            var bestArea = Double.infinity
            for j in 0..<n {
                guard i != j, let jb = bounds[j], areas[j] > areas[i] else { continue }
                if areas[j] < bestArea && frameContains(outer: jb, inner: ib) {
                    bestArea = areas[j]; parentOf[i] = j
                }
            }
        }

        var childrenOf = Array(repeating: [Int](), count: n)
        var roots = [Int]()
        for i in 0..<n {
            if parentOf[i] == -1 { roots.append(i) }
            else { childrenOf[parentOf[i]].append(i) }
        }

        func build(_ i: Int) -> [String: Any] {
            var node = flat[i]
            node["children"] = childrenOf[i].map { build($0) }
            return node
        }
        return roots.map { build($0) }
    }

    static func run(_ args: [String], _ ctx: Context) {
        let action = args.first ?? "describe"
        let rest = Array(args.dropFirst())
        switch action {
        case "describe": runDescribe(rest, ctx)
        case "verify":   runVerify(rest, ctx)
        case "tap":      runTap(rest, ctx)
        case "swipe":    runSwipe(rest, ctx)
        case "input":    runInput(rest, ctx)
        case "button":   runButton(rest, ctx)
        case "driver":   runDriver(rest, ctx)
        default:
            Out.fail("ui", error: "unknown action '\(action)'",
                     hint: "use: describe | verify | tap | swipe | input | button | driver",
                     code: ExitCode.usage, ctx)
        }
    }

    static func runDescribe(_ args: [String], _ ctx: Context) {
        requireFullXcode("ui describe", ctx)

        var simulatorTarget: String?
        var bundleIdFlag: String?
        var withScreenshot = false
        var forceIDB = false
        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator": idx += 1; if idx < args.count { simulatorTarget = args[idx] }
            case "--bundle-id": idx += 1; if idx < args.count { bundleIdFlag = args[idx] }
            case "--screenshot": withScreenshot = true
            case "--idb": forceIDB = true
            default: break
            }
            idx += 1
        }

        let udid = RunCommand.findOrBootSimulator(target: simulatorTarget, command: "ui describe", ctx)

        // Prefer the XCUITest driver (works on any Xcode, no idb); fall back to
        // idb when no target app is known or --idb is passed.
        let tree: [[String: Any]]
        let flat: [[String: Any]]
        if !forceIDB,
           let driverTree = fetchHierarchyViaDriver(udid: udid, bundleIdFlag: bundleIdFlag,
                                                    command: "ui describe", ctx) {
            tree = driverTree
            flat = flatten(driverTree)
        } else {
            let idb = requireIDB(ctx)
            flat = fetchHierarchy(udid: udid, idb: idb, ctx)
            tree = buildSpatialTree(flat)
        }

        if withScreenshot {
            let path = "/tmp/xcode-agent-ui-\(udid).png"
            let shot = Shell.run("/usr/bin/xcrun", ["simctl", "io", udid, "screenshot", path])
            if shot.exitCode == 0 {
                Out.stderr("Screenshot saved to \(path)")
            } else {
                Out.stderr("warning: screenshot failed: \(shot.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        if ctx.json {
            Out.printJSON(["ok": true, "command": "ui describe",
                           "data": ["simulatorUDID": udid, "elements": tree, "flat": flat],
                           "error": NSNull(), "hint": NSNull()])
        } else {
            printTree(tree, indent: 0)
        }
        exit(ExitCode.ok)
    }

    static func runVerify(_ args: [String], _ ctx: Context) {
        requireFullXcode("ui verify", ctx)

        var simulatorTarget: String?
        var bundleIdFlag: String?
        var forceIDB = false
        var labelQuery: String?
        var typeQuery: String?
        var valueQuery: String?
        var idQuery: String?
        var expectedFrame: [String: Double]?

        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator":
                idx += 1; if idx < args.count { simulatorTarget = args[idx] }
            case "--bundle-id":
                idx += 1; if idx < args.count { bundleIdFlag = args[idx] }
            case "--idb":
                forceIDB = true
            case "--label":
                idx += 1; if idx < args.count { labelQuery = args[idx] }
            case "--type":
                idx += 1; if idx < args.count { typeQuery = args[idx] }
            case "--value":
                idx += 1; if idx < args.count { valueQuery = args[idx] }
            case "--id":
                idx += 1; if idx < args.count { idQuery = args[idx] }
            case "--frame":
                idx += 1
                if idx < args.count {
                    let parts = args[idx].split(separator: ",")
                        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 4 {
                        expectedFrame = ["x": parts[0], "y": parts[1],
                                         "width": parts[2], "height": parts[3]]
                    }
                }
            default: break
            }
            idx += 1
        }

        guard labelQuery != nil || typeQuery != nil || valueQuery != nil || idQuery != nil else {
            Out.fail("ui verify",
                     error: "provide at least one of --label, --type, --value, or --id",
                     hint: "usage: xcode-agent ui verify --id <AXUniqueId> | --label <text> [--type <type>] [--value <text>] [--frame x,y,w,h] [--simulator <udid>]",
                     code: ExitCode.usage, ctx)
        }

        let udid = RunCommand.findOrBootSimulator(target: simulatorTarget, command: "ui verify", ctx)
        let flat: [[String: Any]]
        if !forceIDB,
           let driverTree = fetchHierarchyViaDriver(udid: udid, bundleIdFlag: bundleIdFlag,
                                                    command: "ui verify", ctx) {
            flat = flatten(driverTree)
        } else {
            let idb = requireIDB(ctx)
            flat = fetchHierarchy(udid: udid, idb: idb, ctx)
        }

        let matched = flat.filter { el in
            if let q = idQuery,    elementID(el) != q                                    { return false }
            if let q = labelQuery, !elementLabel(el).localizedCaseInsensitiveContains(q) { return false }
            if let q = typeQuery,  !elementType(el).localizedCaseInsensitiveContains(q)  { return false }
            if let q = valueQuery, !elementValue(el).localizedCaseInsensitiveContains(q) { return false }
            return true
        }

        let found = !matched.isEmpty
        var frameOK = true
        let first = matched.first

        if let ef = expectedFrame, let el = first, let f = elementBounds(el) {
            let tol = 5.0
            func close(_ key: String) -> Bool { abs((f[key] ?? 0) - (ef[key] ?? 0)) < tol }
            frameOK = close("x") && close("y") && close("width") && close("height")
        }

        let ok = found && frameOK
        let data: [String: Any] = [
            "matched":    found,
            "frameOK":    frameOK,
            "matchCount": matched.count,
            "element":    first as Any? ?? NSNull(),
        ]

        if ctx.json {
            Out.printJSON(["ok": ok, "command": "ui verify", "data": data,
                           "error": ok ? NSNull() : (found ? "frame mismatch" : "element not found") as Any,
                           "hint": NSNull()])
        } else {
            if !found {
                print("✗ element not found")
                if let q = idQuery    { print("  id    : \(q)") }
                if let q = labelQuery { print("  label : \(q)") }
                if let q = typeQuery  { print("  type  : \(q)") }
                if let q = valueQuery { print("  value : \(q)") }
            } else if !frameOK, let el = first, let f = elementBounds(el), let ef = expectedFrame {
                print("✗ element found but frame mismatch")
                print("  actual  : \(frameString(f))")
                print("  expected: \(frameString(ef))")
            } else {
                let n = matched.count
                print("✓ element verified (\(n) match\(n == 1 ? "" : "es"))")
                if let el = first {
                    let eid = elementID(el);    if !eid.isEmpty { print("  id    : \(eid)") }
                    let lbl = elementLabel(el); if !lbl.isEmpty { print("  label : \(lbl)") }
                    let typ = elementType(el);  print("  type  : \(typ)")
                    if let f = elementBounds(el) {
                        print("  frame : \(frameString(f))")
                    }
                }
            }
        }
        exit(ok ? ExitCode.ok : ExitCode.runtime)
    }

    // MARK: HID interaction (XCUITest driver backend)

    /// Bundle id for element-targeted commands: --bundle-id flag, else the app
    /// last launched via `xcode-agent run` on this simulator.
    static func resolveBundleId(flag: String?, udid: String, command: String, _ ctx: Context) -> String {
        if let flag, !flag.isEmpty { return flag }
        if let last = UIDriver.lastLaunchedBundleId(udid: udid), !last.isEmpty { return last }
        Out.fail(command, error: "no target app known for this simulator",
                 hint: "pass --bundle-id <id>, or launch the app first with: xcode-agent run",
                 code: ExitCode.usage, ctx)
    }

    /// Run one driver command and emit the standard success/failure output.
    static func driverAction(command: String, udid: String, path: String,
                             body: [String: Any], data: [String: Any],
                             successText: String, _ ctx: Context) -> Never {
        let port = UIDriver.ensureRunning(udid: udid, command: command, ctx)
        guard let response = UIDriver.request(port: port, method: "POST", path: path, body: body, timeout: 60) else {
            Out.fail(command, error: "lost connection to the UI driver",
                     hint: "retry the command; check the driver log: \(UIDriver.baseDir)/driver-\(udid).log",
                     code: ExitCode.runtime, ctx)
        }
        let ok = response.ok
        if ctx.json {
            Out.printJSON(["ok": ok, "command": command, "data": data,
                           "error": ok ? NSNull() : (response.error ?? "driver error") as Any,
                           "hint": NSNull()])
        } else {
            if ok { print(successText) }
            else { Out.stderr("error: \(response.error ?? "driver error")") }
        }
        exit(ok ? ExitCode.ok : ExitCode.runtime)
    }

    static func runTap(_ args: [String], _ ctx: Context) {
        requireFullXcode("ui tap", ctx)
        var simulatorTarget: String?
        var duration: Double?
        var elementID: String?
        var bundleIDFlag: String?
        var positional: [String] = []
        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator": idx += 1; if idx < args.count { simulatorTarget = args[idx] }
            case "--duration":  idx += 1; if idx < args.count { duration = Double(args[idx]) }
            case "--id":        idx += 1; if idx < args.count { elementID = args[idx] }
            case "--bundle-id": idx += 1; if idx < args.count { bundleIDFlag = args[idx] }
            default: positional.append(args[idx])
            }
            idx += 1
        }

        let udid = RunCommand.findOrBootSimulator(target: simulatorTarget, command: "ui tap", ctx)

        if let elementID {
            let bundleId = resolveBundleId(flag: bundleIDFlag, udid: udid, command: "ui tap", ctx)
            driverAction(command: "ui tap", udid: udid, path: "/tapElement",
                         body: ["id": elementID, "bundleId": bundleId],
                         data: ["id": elementID, "bundleId": bundleId, "simulatorUDID": udid],
                         successText: "✓ tapped element '\(elementID)'", ctx)
        }

        guard positional.count >= 2,
              let x = Double(positional[0]),
              let y = Double(positional[1]) else {
            Out.fail("ui tap", error: "missing coordinates or --id",
                     hint: "usage: xcode-agent ui tap <x> <y> | --id <accessibility-id> [--bundle-id <id>] [--simulator <udid>] [--duration <secs>]",
                     code: ExitCode.usage, ctx)
        }
        var body: [String: Any] = ["x": x, "y": y]
        if let duration { body["duration"] = duration }
        driverAction(command: "ui tap", udid: udid, path: "/tap",
                     body: body,
                     data: ["x": x, "y": y, "simulatorUDID": udid],
                     successText: "✓ tapped (\(Int(x)), \(Int(y)))", ctx)
    }

    static func runSwipe(_ args: [String], _ ctx: Context) {
        requireFullXcode("ui swipe", ctx)
        var simulatorTarget: String?
        var duration: Double?
        var positional: [String] = []
        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator": idx += 1; if idx < args.count { simulatorTarget = args[idx] }
            case "--duration":  idx += 1; if idx < args.count { duration = Double(args[idx]) }
            case "--delta":     idx += 1 // accepted for back-compat; the xcuitest backend ignores it
            default: positional.append(args[idx])
            }
            idx += 1
        }
        guard positional.count >= 4,
              let x1 = Double(positional[0]), let y1 = Double(positional[1]),
              let x2 = Double(positional[2]), let y2 = Double(positional[3]) else {
            Out.fail("ui swipe", error: "missing coordinates",
                     hint: "usage: xcode-agent ui swipe <x1> <y1> <x2> <y2> [--simulator <udid>] [--duration <secs>]",
                     code: ExitCode.usage, ctx)
        }
        let udid = RunCommand.findOrBootSimulator(target: simulatorTarget, command: "ui swipe", ctx)
        var body: [String: Any] = ["x1": x1, "y1": y1, "x2": x2, "y2": y2]
        if let duration { body["duration"] = duration }
        driverAction(command: "ui swipe", udid: udid, path: "/swipe",
                     body: body,
                     data: ["x1": x1, "y1": y1, "x2": x2, "y2": y2, "simulatorUDID": udid],
                     successText: "✓ swiped (\(Int(x1)),\(Int(y1))) → (\(Int(x2)),\(Int(y2)))", ctx)
    }

    static func runInput(_ args: [String], _ ctx: Context) {
        requireFullXcode("ui input", ctx)
        var simulatorTarget: String?
        var bundleIDFlag: String?
        var positional: [String] = []
        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator": idx += 1; if idx < args.count { simulatorTarget = args[idx] }
            case "--bundle-id": idx += 1; if idx < args.count { bundleIDFlag = args[idx] }
            default: positional.append(args[idx])
            }
            idx += 1
        }
        guard let text = positional.first, !text.isEmpty else {
            Out.fail("ui input", error: "missing text argument",
                     hint: "usage: xcode-agent ui input <text> [--bundle-id <id>] [--simulator <udid>]",
                     code: ExitCode.usage, ctx)
        }
        let udid = RunCommand.findOrBootSimulator(target: simulatorTarget, command: "ui input", ctx)
        let bundleId = resolveBundleId(flag: bundleIDFlag, udid: udid, command: "ui input", ctx)
        driverAction(command: "ui input", udid: udid, path: "/input",
                     body: ["text": text, "bundleId": bundleId],
                     data: ["text": text, "bundleId": bundleId, "simulatorUDID": udid],
                     successText: "✓ typed: \(text)", ctx)
    }

    static func runButton(_ args: [String], _ ctx: Context) {
        requireFullXcode("ui button", ctx)
        var simulatorTarget: String?
        var positional: [String] = []
        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator": idx += 1; if idx < args.count { simulatorTarget = args[idx] }
            case "--duration":  idx += 1 // accepted for back-compat; ignored by the xcuitest backend
            default: positional.append(args[idx])
            }
            idx += 1
        }
        guard let buttonRaw = positional.first else {
            Out.fail("ui button", error: "missing button name",
                     hint: "usage: xcode-agent ui button <home> [--simulator <udid>]",
                     code: ExitCode.usage, ctx)
        }
        let button = buttonRaw.lowercased()
        guard button == "home" else {
            Out.fail("ui button", error: "unknown button '\(buttonRaw)'",
                     hint: "the xcuitest backend supports: home",
                     code: ExitCode.usage, ctx)
        }
        let udid = RunCommand.findOrBootSimulator(target: simulatorTarget, command: "ui button", ctx)
        driverAction(command: "ui button", udid: udid, path: "/button",
                     body: ["name": button],
                     data: ["button": button, "simulatorUDID": udid],
                     successText: "✓ pressed \(button)", ctx)
    }

    /// `ui driver <status|stop>` — inspect or stop the background XCUITest driver.
    static func runDriver(_ args: [String], _ ctx: Context) {
        requireFullXcode("ui driver", ctx)
        var simulatorTarget: String?
        var positional: [String] = []
        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator": idx += 1; if idx < args.count { simulatorTarget = args[idx] }
            default: positional.append(args[idx])
            }
            idx += 1
        }
        let action = positional.first ?? "status"
        let udid = RunCommand.findOrBootSimulator(target: simulatorTarget, command: "ui driver", ctx)
        let port = UIDriver.portFor(udid: udid)
        switch action {
        case "status":
            let running = UIDriver.isHealthy(port: port)
            if ctx.json {
                Out.printJSON(["ok": true, "command": "ui driver",
                               "data": ["running": running, "port": Int(port), "simulatorUDID": udid],
                               "error": NSNull(), "hint": NSNull()])
            } else {
                print(running ? "✓ driver running on port \(port)" : "✗ driver not running (port \(port))")
            }
            exit(ExitCode.ok)
        case "stop":
            let stopped = UIDriver.stop(udid: udid)
            if ctx.json {
                Out.printJSON(["ok": true, "command": "ui driver",
                               "data": ["stopped": stopped, "simulatorUDID": udid],
                               "error": NSNull(), "hint": NSNull()])
            } else {
                print(stopped ? "✓ driver stopped" : "driver was not running")
            }
            exit(ExitCode.ok)
        default:
            Out.fail("ui driver", error: "unknown action '\(action)'",
                     hint: "use: status | stop", code: ExitCode.usage, ctx)
        }
    }

    static func printTree(_ elements: [[String: Any]], indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        for el in elements {
            var line = "\(pad)\(elementType(el))"
            let lbl = elementLabel(el)
            let val = elementValue(el)
            let text = !lbl.isEmpty ? lbl : val
            if !text.isEmpty { line += " \"\(text)\"" }
            if let f = elementBounds(el) {
                line += " [\(Int(f["x"] ?? 0)),\(Int(f["y"] ?? 0)) \(Int(f["width"] ?? 0))×\(Int(f["height"] ?? 0))]"
            }
            let id = elementID(el)
            if !id.isEmpty { line += " id=\(id)" }
            print(line)
            printTree(elementChildren(el), indent: indent + 1)
        }
    }
}

// MARK: - docs

enum DocsCommand {
    static func run(_ args: [String], _ ctx: Context) {
        let query = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            Out.fail("docs", error: "missing query",
                     hint: "usage: xcode-agent docs <query>", code: ExitCode.usage, ctx)
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let sources: [String: String] = [
            "Apple Developer": "https://developer.apple.com/search/?q=\(encoded)",
            "Swift Package Index": "https://swiftpackageindex.com/search?query=\(encoded)",
            "Human Interface Guidelines": "https://developer.apple.com/design/human-interface-guidelines/",
        ]
        if ctx.json {
            Out.printJSON(["ok": true, "command": "docs",
                           "data": ["query": query, "sources": sources],
                           "error": NSNull(), "hint": NSNull()])
        } else {
            print("knowledge base — \(query)")
            for (name, url) in sources.sorted(by: { $0.key < $1.key }) {
                print("  \(name): \(url)")
            }
        }
    }
}
