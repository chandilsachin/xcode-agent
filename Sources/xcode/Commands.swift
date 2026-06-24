import Foundation

// MARK: - Command registry (powers `xcode commands` introspection)

struct CommandSpec {
    let name: String
    let summary: String
    let usage: String
    let flags: [String]
}

let commandRegistry: [CommandSpec] = [
    CommandSpec(name: "doctor", summary: "Check toolchain readiness with remediation hints",
                usage: "xcode doctor", flags: ["--json"]),
    CommandSpec(name: "info", summary: "Show active toolchain versions",
                usage: "xcode info", flags: ["--json"]),
    CommandSpec(name: "commands", summary: "List all commands (self-describing)",
                usage: "xcode commands", flags: ["--json"]),
    CommandSpec(name: "create", summary: "Scaffold a new project and generate it with Tuist",
                usage: "xcode create <Name> [--template app|package] [--platform ios|macos] [--bundle-id <id>] [--no-generate]",
                flags: ["--template", "--platform", "--bundle-id", "--no-generate", "--json"]),
    CommandSpec(name: "build", summary: "Build the project in the current directory",
                usage: "xcode build [extra tool args]", flags: ["--json"]),
    CommandSpec(name: "run", summary: "Build and run a Swift package or app on simulator",
                usage: "xcode run [--simulator <name|udid>] [--scheme <name>] [--bundle-id <id>] [extra xcodebuild args]",
                flags: ["--simulator", "--scheme", "--bundle-id", "--json"]),
    CommandSpec(name: "test", summary: "Run tests and report a summary",
                usage: "xcode test [extra tool args]", flags: ["--json"]),
    CommandSpec(name: "simulator", summary: "Manage simulators (list/boot/shutdown)",
                usage: "xcode simulator <list|boot|shutdown> [name|udid|all]", flags: ["--json"]),
    CommandSpec(name: "screenshot", summary: "Take a screenshot of a running simulator",
                usage: "xcode screenshot [--simulator <name|udid>] [<output.png>]",
                flags: ["--simulator", "--json"]),
    CommandSpec(name: "log", summary: "Stream live logs from a simulator app",
                usage: "xcode log [--simulator <name|udid>] [--bundle-id <id>] [extra log stream args]",
                flags: ["--simulator", "--bundle-id"]),
    CommandSpec(name: "skills", summary: "Discover and read SKILL.md instruction sets",
                usage: "xcode skills <list|show> [name]", flags: ["--json"]),
    CommandSpec(name: "docs", summary: "Knowledge-base pointers for a query",
                usage: "xcode docs <query>", flags: ["--json"]),
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
        let data: [String: Any] = [
            "developerDir": dev,
            "fullXcode": Toolchain.hasFullXcode,
            "xcodebuild": xcodebuild,
            "swift": swift,
            "tuist": tuist,
        ]
        let human = """
        xcode-agent — toolchain info
          developer dir : \(dev)
          full Xcode    : \(Toolchain.hasFullXcode ? "yes" : "no")
          xcodebuild    : \(xcodebuild)
          swift         : \(swift)
          tuist         : \(tuist)
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
                     hint: "usage: xcode create <Name> [--template app|package] [--platform ios|macos] [--bundle-id <id>] [--no-generate]",
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
                     hint: "run `xcode create <Name>` or cd into a project", code: ExitCode.usage, ctx)
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
                     hint: "run `xcode create <Name>` or cd into a project", code: ExitCode.usage, ctx)
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
        var scheme: String?
        var bundleId: String?
        var extraArgs: [String] = []

        var idx = 0
        while idx < args.count {
            switch args[idx] {
            case "--simulator": idx += 1; if idx < args.count { simulatorTarget = args[idx] }
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
            runAppOnSimulator(project: project, simulatorTarget: simulatorTarget,
                              scheme: scheme, bundleId: bundleId, extraArgs: extraArgs, ctx)
        case .none:
            Out.fail("run", error: "no project found in current directory",
                     hint: "run `xcode create <Name>`", code: ExitCode.usage, ctx)
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
                     hint: "run `xcode build` for full diagnostics", code: ExitCode.runtime, ctx)
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

    /// Returns a booted simulator UDID, booting one if necessary.
    static func findOrBootSimulator(target: String?, _ ctx: Context) -> String {
        let result = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "--json"])
        guard result.exitCode == 0,
              let data    = result.stdout.data(using: .utf8),
              let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]]
        else {
            Out.fail("run", error: "could not list simulators",
                     hint: "check that simctl is available (requires full Xcode)", code: ExitCode.envNotReady, ctx)
        }

        let all = devices.values.flatMap { $0 }

        if let target = target {
            guard let sim  = all.first(where: {
                      ($0["udid"] as? String) == target || ($0["name"] as? String) == target
                  }),
                  let udid = sim["udid"] as? String else {
                Out.fail("run", error: "simulator not found: '\(target)'",
                         hint: "run `xcode simulator list` to see available devices",
                         code: ExitCode.runtime, ctx)
            }
            Shell.run("/usr/bin/xcrun", ["simctl", "boot", udid])
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
                Shell.run("/usr/bin/xcrun", ["simctl", "boot", udid])
                return udid
            }
        }

        Out.fail("run", error: "no iOS simulator available",
                 hint: "install a simulator runtime in Xcode Settings → Platforms",
                 code: ExitCode.envNotReady, ctx)
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

        let simUDID = RunCommand.findOrBootSimulator(target: simulatorTarget, ctx)
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

        let simUDID = RunCommand.findOrBootSimulator(target: simulatorTarget, ctx)

        // `simctl spawn <udid> log stream` runs the host's `log` tool inside
        // the simulator's process namespace, giving us the simulator's unified log.
        var logArgs = ["simctl", "spawn", simUDID, "log", "stream", "--level", "debug"]
        if let bid = bundleId {
            // Filter to the specific app via its bundle ID subsystem or image path.
            logArgs += ["--predicate",
                        "subsystem == \"\(bid)\" OR processImagePath CONTAINS \"\(bid)\""]
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
                print(result.stdout)
            } else {
                exit(Shell.runStreaming("/usr/bin/xcrun", ["simctl", "list", "devices", "available"]))
            }
        case "boot":
            guard let target = rest.first else {
                Out.fail("simulator", error: "missing simulator",
                         hint: "usage: xcode simulator boot <udid|name>", code: ExitCode.usage, ctx)
            }
            exit(Shell.runStreaming("/usr/bin/xcrun", ["simctl", "boot", target]))
        case "shutdown":
            let target = rest.first ?? "all"
            exit(Shell.runStreaming("/usr/bin/xcrun", ["simctl", "shutdown", target]))
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
                         hint: "usage: xcode skills show <name>", code: ExitCode.usage, ctx)
            }
            guard let skill = discover().first(where: { $0.name == target }),
                  let content = try? String(contentsOfFile: skill.path, encoding: .utf8) else {
                Out.fail("skills", error: "skill not found: \(target)",
                         hint: "run `xcode skills list`", code: ExitCode.runtime, ctx)
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

// MARK: - docs

enum DocsCommand {
    static func run(_ args: [String], _ ctx: Context) {
        let query = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            Out.fail("docs", error: "missing query",
                     hint: "usage: xcode docs <query>", code: ExitCode.usage, ctx)
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
