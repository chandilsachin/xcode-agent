import Foundation

let version = "0.1.0"

// Extract the global --json flag from anywhere in the argument list.
var jsonMode = false
var positional: [String] = []
for arg in CommandLine.arguments.dropFirst() {
    if arg == "--json" {
        jsonMode = true
    } else {
        positional.append(arg)
    }
}
let ctx = Context(json: jsonMode)

func printRootHelp() {
    print("""
    xcode-agent \(version) — an agent-friendly CLI for Xcode/iOS development

    usage: xcode <command> [options] [--json]

    commands:
    """)
    for spec in commandRegistry {
        print("  \(spec.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(spec.summary)")
    }
    print("""

    global flags:
      --json   emit a single JSON object on stdout (logs go to stderr)

    run `xcode commands --json` for machine-readable command metadata.
    """)
}

guard let command = positional.first else {
    printRootHelp()
    exit(ExitCode.ok)
}
let rest = Array(positional.dropFirst())

switch command {
case "info":              InfoCommand.run(rest, ctx)
case "doctor":            DoctorCommand.run(rest, ctx)
case "commands":          CommandsCommand.run(rest, ctx)
case "create":            CreateCommand.run(rest, ctx)
case "build":             BuildCommand.run(rest, ctx)
case "run":               RunCommand.run(rest, ctx)
case "test":              TestCommand.run(rest, ctx)
case "screenshot":        ScreenshotCommand.run(rest, ctx)
case "log":               LogCommand.run(rest, ctx)
case "simulator", "sim":  SimulatorCommand.run(rest, ctx)
case "devices":           DevicesCommand.run(rest, ctx)
case "clean":             CleanCommand.run(rest, ctx)
case "open":              OpenCommand.run(rest, ctx)
case "lint":              LintCommand.run(rest, ctx)
case "skills":            SkillsCommand.run(rest, ctx)
case "docs":              DocsCommand.run(rest, ctx)
case "version", "--version", "-v":
    if ctx.json { Out.printJSON(["version": version]) } else { print("xcode-agent \(version)") }
case "help", "--help", "-h":
    printRootHelp()
default:
    Out.fail(command, error: "unknown command: \(command)",
             hint: "run `xcode help` to list commands", code: ExitCode.usage, ctx)
}
