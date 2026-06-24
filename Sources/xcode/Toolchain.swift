import Foundation

/// Detects the active Apple toolchain and adjacent tools so commands can degrade
/// gracefully when full Xcode / Tuist are not installed.
enum Toolchain {
    static var developerDir: String? {
        let result = Shell.run("/usr/bin/xcode-select", ["-p"])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !path.isEmpty ? path : nil
    }

    /// True only when a full Xcode.app is selected (needed for xcodebuild/simctl).
    static var hasFullXcode: Bool {
        (developerDir ?? "").contains(".app/Contents/Developer")
    }

    static var xcodebuildVersion: String? {
        guard hasFullXcode else { return nil }
        let result = Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"])
        guard result.exitCode == 0 else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var swiftVersion: String? {
        let result = Shell.run("/usr/bin/xcrun", ["swift", "--version"])
        let text = result.exitCode == 0
            ? result.stdout
            : Shell.run("/usr/bin/swift", ["--version"]).stdout
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when `simctl` is reachable (requires full Xcode).
    static var hasSimctl: Bool {
        let result = Shell.run("/usr/bin/xcrun", ["--find", "simctl"])
        return result.exitCode == 0
            && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Absolute path to `tuist`, or nil if not on PATH.
    static var tuistPath: String? { which("tuist") }

    static func which(_ tool: String) -> String? {
        let result = Shell.run("/usr/bin/which", [tool])
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !path.isEmpty ? path : nil
    }
}

/// Require full Xcode or exit (code 3) with actionable guidance.
func requireFullXcode(_ command: String, _ ctx: Context) {
    guard Toolchain.hasFullXcode else {
        Out.fail(command,
                 error: "requires full Xcode (active toolchain is Command Line Tools)",
                 hint: "install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer",
                 code: ExitCode.envNotReady, ctx)
    }
}

/// Require Tuist or exit (code 4) with an install hint.
func requireTuist(_ command: String, _ ctx: Context) -> String {
    guard let path = Toolchain.tuistPath else {
        Out.fail(command,
                 error: "tuist not found on PATH",
                 hint: "install tuist: brew install tuist  (or: curl -Ls https://install.tuist.io | bash)",
                 code: ExitCode.toolNotFound, ctx)
    }
    return path
}
