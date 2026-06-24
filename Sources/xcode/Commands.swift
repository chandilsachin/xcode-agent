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
    CommandSpec(name: "run", summary: "Build and run (Swift packages; app run is a later milestone)",
                usage: "xcode run [extra tool args]", flags: ["--json"]),
    CommandSpec(name: "test", summary: "Run tests and report a summary",
                usage: "xcode test [extra tool args]", flags: ["--json"]),
    CommandSpec(name: "simulator", summary: "Manage simulators (list/boot/shutdown)",
                usage: "xcode simulator <list|boot|shutdown> [name|udid|all]", flags: ["--json"]),
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
            runToolWithSummary(command: "test", tool: "/usr/bin/xcrun",
                               args: ["xcodebuild", "-workspace", path, "test"] + args, ctx)
        case .xcodeproj(let path):
            requireFullXcode("test", ctx)
            runToolWithSummary(command: "test", tool: "/usr/bin/xcrun",
                               args: ["xcodebuild", "-project", path, "test"] + args, ctx)
        case .package:
            runToolWithSummary(command: "test", tool: "/usr/bin/xcrun",
                               args: ["swift", "test"] + args, ctx)
        case .none:
            Out.fail("test", error: "no project found in current directory",
                     hint: "run `xcode create <Name>` or cd into a project", code: ExitCode.usage, ctx)
        }
    }
}

enum RunCommand {
    static func run(_ args: [String], _ ctx: Context) {
        switch Project.detect() {
        case .package:
            runToolWithSummary(command: "run", tool: "/usr/bin/xcrun",
                               args: ["swift", "run"] + args, ctx)
        case .tuist, .xcworkspace, .xcodeproj:
            requireFullXcode("run", ctx)
            Out.fail("run",
                     error: "running an app on a simulator (build → install → launch) is a later milestone",
                     hint: "for now: `xcode build`, `xcode simulator boot <name>`, then launch from Xcode",
                     code: ExitCode.runtime, ctx)
        case .none:
            Out.fail("run", error: "no project found in current directory",
                     hint: "run `xcode create <Name>`", code: ExitCode.usage, ctx)
        }
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
