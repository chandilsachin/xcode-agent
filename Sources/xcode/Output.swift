import Foundation

/// Per-invocation options shared by every command.
struct Context {
    let json: Bool
}

/// Stable, documented exit codes (see DESIGN.md). Agents branch on these
/// instead of scraping text.
enum ExitCode {
    static let ok: Int32 = 0
    static let runtime: Int32 = 1
    static let usage: Int32 = 2
    static let envNotReady: Int32 = 3
    static let toolNotFound: Int32 = 4
}

/// Output helpers implementing the agent-friendly I/O contract: one JSON object
/// on stdout under `--json` (logs go to stderr), human-readable text otherwise.
enum Out {
    /// Emit a success envelope `{ ok, command, data, error, hint }`.
    static func success(_ command: String, data: Any = [String: Any](),
                        human: String, _ ctx: Context) {
        if ctx.json {
            printJSON(["ok": true, "command": command, "data": data,
                       "error": NSNull(), "hint": NSNull()])
        } else {
            print(human)
        }
    }

    /// Emit a failure envelope and exit with `code`. Errors/hints go to stderr
    /// in human mode so stdout stays clean.
    static func fail(_ command: String, error: String, hint: String? = nil,
                     code: Int32, _ ctx: Context) -> Never {
        if ctx.json {
            printJSON(["ok": false, "command": command, "data": [String: Any](),
                       "error": error, "hint": hint as Any? ?? NSNull()])
        } else {
            stderr("error: \(error)")
            if let hint { stderr("hint: \(hint)") }
        }
        exit(code)
    }

    static func printJSON(_ object: Any) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            print("{}")
            return
        }
        print(string)
    }

    static func stderr(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
