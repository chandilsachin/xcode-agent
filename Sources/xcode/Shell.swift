import Foundation

/// Result of a captured subprocess run.
struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Thin wrapper around `Process` for shelling out to the Apple toolchain.
enum Shell {
    /// Run a tool and capture its output. Reads stdout/stderr concurrently to
    /// avoid pipe-buffer deadlocks on large output (e.g. `simctl list`).
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], cwd: String? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: 127, stdout: "",
                                 stderr: "failed to launch \(launchPath): \(error.localizedDescription)")
        }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "xcode-agent.shell.read", attributes: .concurrent)
        group.enter()
        queue.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        queue.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        process.waitUntilExit()
        group.wait()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Run a tool inheriting the terminal's stdout/stderr so logs stream live.
    /// Returns the child's exit code.
    @discardableResult
    static func runStreaming(_ launchPath: String, _ args: [String], cwd: String? = nil) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(
                "failed to launch \(launchPath): \(error.localizedDescription)\n".data(using: .utf8)!)
            return 127
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
