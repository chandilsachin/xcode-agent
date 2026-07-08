import Foundation

/// XCUITest-based UI interaction backend.
///
/// idb-companion's HID path breaks whenever Apple changes the simulator
/// protocol (it silently drops events on Xcode 27 beta). This backend instead
/// materializes a tiny UI-test runner ("AgentDriver") on the user's machine,
/// builds it once per CLI version with `xcodebuild build-for-testing`, and
/// launches it with `test-without-building`. The test hosts a localhost HTTP
/// server (WebDriverAgent-style) inside the simulator process space and
/// performs gestures through public XCUITest APIs — which Apple keeps working
/// across Xcode releases.
enum UIDriver {

    // MARK: Paths & ports

    static var baseDir: String { NSHomeDirectory() + "/.xcode-agent/driver" }
    static var srcDir: String { baseDir + "/AgentDriver" }
    static var derivedDataDir: String { baseDir + "/DerivedData" }
    static var stateDir: String { NSHomeDirectory() + "/.xcode-agent/state" }

    /// Deterministic per-simulator port (stable across processes, unlike hashValue).
    static func portFor(udid: String) -> UInt16 {
        var h: UInt32 = 5381
        for b in udid.utf8 { h = h &* 33 &+ UInt32(b) }
        return UInt16(8300 + (h % 600))
    }

    static func lastAppStateFile(udid: String) -> String {
        stateDir + "/last-app-" + udid
    }

    /// Bundle id of the last app launched via `xcode-agent run` on this simulator.
    static func lastLaunchedBundleId(udid: String) -> String? {
        (try? String(contentsOfFile: lastAppStateFile(udid: udid), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func recordLaunchedApp(bundleId: String, udid: String) {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        try? bundleId.write(toFile: lastAppStateFile(udid: udid), atomically: true, encoding: .utf8)
    }

    // MARK: HTTP client

    struct DriverResponse {
        let ok: Bool
        let error: String?
        let payload: [String: Any]
    }

    /// Synchronous JSON-over-HTTP request to the driver. Returns nil when the
    /// driver is unreachable (connection refused / timeout).
    static func request(port: UInt16, method: String, path: String,
                        body: [String: Any]? = nil, timeout: TimeInterval = 30) -> DriverResponse? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var response: DriverResponse?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, error in
            defer { sem.signal() }
            guard error == nil, let data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            response = DriverResponse(ok: (json["ok"] as? Bool) ?? false,
                                      error: json["error"] as? String,
                                      payload: json)
        }.resume()
        sem.wait()
        return response
    }

    static func isHealthy(port: UInt16) -> Bool {
        request(port: port, method: "GET", path: "/health", timeout: 2)?.ok == true
    }

    // MARK: Lifecycle

    /// Make sure the driver is serving for this simulator; returns its port.
    /// Builds and launches on first use (slow); subsequent calls are instant.
    static func ensureRunning(udid: String, command: String, _ ctx: Context) -> UInt16 {
        let port = portFor(udid: udid)
        if isHealthy(port: port) { return port }

        materializeSourcesIfNeeded(command, ctx)
        generateProjectIfNeeded(command, ctx)
        let xctestrun = buildForTestingIfNeeded(command, ctx)
        launchDriver(xctestrun: xctestrun, udid: udid, port: port, command, ctx)

        Out.stderr("Waiting for UI driver on port \(port)…")
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if isHealthy(port: port) { return port }
            Thread.sleep(forTimeInterval: 1)
        }
        Out.fail(command,
                 error: "UI driver did not become ready within 120s",
                 hint: "check the driver log: \(baseDir)/driver-\(udid).log",
                 code: ExitCode.runtime, ctx)
    }

    /// Wipe + rewrite the driver sources when missing or from another CLI version.
    static func materializeSourcesIfNeeded(_ command: String, _ ctx: Context) {
        let fm = FileManager.default
        let versionMarker = srcDir + "/.cli-version"
        if let stamped = try? String(contentsOfFile: versionMarker, encoding: .utf8),
           stamped == version { return }

        try? fm.removeItem(atPath: srcDir)
        try? fm.removeItem(atPath: derivedDataDir)
        do {
            try fm.createDirectory(atPath: srcDir + "/HostSources", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: srcDir + "/UITestSources", withIntermediateDirectories: true)
            try DriverTemplates.projectManifest.write(
                toFile: srcDir + "/Project.swift", atomically: true, encoding: .utf8)
            // Tuist refuses to run without a root marker (Tuist.swift or .git).
            try DriverTemplates.tuistConfig.write(
                toFile: srcDir + "/Tuist.swift", atomically: true, encoding: .utf8)
            try DriverTemplates.hostApp.write(
                toFile: srcDir + "/HostSources/AgentDriverHostApp.swift", atomically: true, encoding: .utf8)
            try DriverTemplates.driverServer.write(
                toFile: srcDir + "/UITestSources/AgentDriverTests.swift", atomically: true, encoding: .utf8)
            try version.write(toFile: versionMarker, atomically: true, encoding: .utf8)
        } catch {
            Out.fail(command, error: "could not write driver sources to \(srcDir): \(error.localizedDescription)",
                     code: ExitCode.runtime, ctx)
        }
    }

    static func generateProjectIfNeeded(_ command: String, _ ctx: Context) {
        if FileManager.default.fileExists(atPath: srcDir + "/AgentDriver.xcworkspace") { return }
        guard let tuist = Toolchain.which("tuist") else {
            Out.fail(command, error: "tuist not found on PATH (needed once to generate the UI driver project)",
                     hint: "install: brew install tuist", code: ExitCode.toolNotFound, ctx)
        }
        Out.stderr("Generating UI driver project (one-time)…")
        let result = Shell.run(tuist, ["generate", "--no-open"], cwd: srcDir)
        guard result.exitCode == 0 else {
            Out.fail(command, error: "tuist generate failed for the UI driver: \(result.stderr.suffix(400))",
                     code: ExitCode.runtime, ctx)
        }
    }

    /// Build the runner once; reuse the .xctestrun for every simulator.
    static func buildForTestingIfNeeded(_ command: String, _ ctx: Context) -> String {
        if let existing = findXCTestRun() { return existing }
        Out.stderr("Building UI driver (one-time, ~30-90s)…")
        let result = Shell.run("/usr/bin/xcrun", [
            "xcodebuild", "build-for-testing",
            "-workspace", srcDir + "/AgentDriver.xcworkspace",
            "-scheme", "AgentDriver",
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", derivedDataDir,
        ])
        guard result.exitCode == 0, let xctestrun = findXCTestRun() else {
            Out.fail(command, error: "xcodebuild build-for-testing failed for the UI driver (exit \(result.exitCode))",
                     hint: "re-run with: xcodebuild build-for-testing -workspace \(srcDir)/AgentDriver.xcworkspace -scheme AgentDriver -destination 'generic/platform=iOS Simulator'",
                     code: ExitCode.runtime, ctx)
        }
        return xctestrun
    }

    static func findXCTestRun() -> String? {
        let productsDir = derivedDataDir + "/Build/Products"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: productsDir) else { return nil }
        return entries.filter { $0.hasSuffix(".xctestrun") }
            .map { productsDir + "/" + $0 }
            .max { (lhs, rhs) in
                let l = (try? FileManager.default.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
                let r = (try? FileManager.default.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
                return l < r
            }
    }

    /// Launch `xcodebuild test-without-building` detached; it keeps serving
    /// after the CLI exits and shuts itself down after an idle timeout.
    static func launchDriver(xctestrun: String, udid: String, port: UInt16,
                             _ command: String, _ ctx: Context) {
        Out.stderr("Starting UI driver on simulator \(udid)…")
        let logPath = baseDir + "/driver-\(udid).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild", "test-without-building",
                             "-xctestrun", xctestrun,
                             "-destination", "id=\(udid)"]
        var env = ProcessInfo.processInfo.environment
        env["TEST_RUNNER_AGENT_DRIVER_PORT"] = String(port)
        env["TEST_RUNNER_AGENT_DRIVER_IDLE_TIMEOUT"] = "1800"
        process.environment = env
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Out.fail(command, error: "could not launch the UI driver: \(error.localizedDescription)",
                     code: ExitCode.runtime, ctx)
        }
    }

    static func stop(udid: String) -> Bool {
        let port = portFor(udid: udid)
        return request(port: port, method: "POST", path: "/shutdown", timeout: 5)?.ok == true
    }
}

// MARK: - Embedded driver sources

/// Sources written to `~/.xcode-agent/driver/AgentDriver` and built on the
/// user's machine (UI test bundles can't be pre-built portably).
enum DriverTemplates {

    static let tuistConfig = #"""
    import ProjectDescription

    let tuist = Tuist()
    """#

    static let projectManifest = #"""
    import ProjectDescription

    let project = Project(
        name: "AgentDriver",
        targets: [
            .target(
                name: "AgentDriverHost",
                destinations: .iOS,
                product: .app,
                bundleId: "com.xcode-agent.driver.host",
                deploymentTargets: .iOS("17.0"),
                infoPlist: .extendingDefault(with: [
                    "UILaunchScreen": [:],
                ]),
                sources: ["HostSources/**"],
                resources: []
            ),
            .target(
                name: "AgentDriverUITests",
                destinations: .iOS,
                product: .uiTests,
                bundleId: "com.xcode-agent.driver.uitests",
                deploymentTargets: .iOS("17.0"),
                sources: ["UITestSources/**"],
                dependencies: [.target(name: "AgentDriverHost")]
            ),
        ],
        schemes: [
            .scheme(
                name: "AgentDriver",
                buildAction: .buildAction(targets: ["AgentDriverHost", "AgentDriverUITests"]),
                testAction: .targets(["AgentDriverUITests"])
            ),
        ]
    )
    """#

    static let hostApp = #"""
    import SwiftUI

    // Minimal host app required by the UI test bundle; never interacted with.
    @main
    struct AgentDriverHostApp: App {
        var body: some Scene {
            WindowGroup { Text("xcode-agent UI driver host") }
        }
    }
    """#

    static let driverServer = #"""
    import XCTest
    import Network
    import Foundation

    /// HTTP command server hosted inside the UI test process. The xcode-agent
    /// CLI posts JSON commands; gestures run through public XCUITest APIs.
    final class AgentDriverTests: XCTestCase {

        func testRunDriverServer() throws {
            continueAfterFailure = true
            let env = ProcessInfo.processInfo.environment
            let port = UInt16(env["AGENT_DRIVER_PORT"] ?? "") ?? 8265
            let idleTimeout = TimeInterval(env["AGENT_DRIVER_IDLE_TIMEOUT"] ?? "") ?? 1800

            let server = DriverServer(port: port)
            try server.start()
            var lastActivity = Date()

            while !server.shutdownRequested {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                while let job = server.nextJob() {
                    job.respond(Self.handle(job.request))
                    lastActivity = Date()
                }
                if Date().timeIntervalSince(lastActivity) > idleTimeout { break }
            }
            server.stopListening()
        }

        // MARK: Command handling (runs on the test's main thread)

        static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        static func screenPoint(_ x: Double, _ y: Double) -> XCUICoordinate {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: x, dy: y))
        }

        static func handle(_ req: DriverServer.Request) -> [String: Any] {
            func num(_ key: String) -> Double? {
                (req.body[key] as? Double) ?? (req.body[key] as? Int).map(Double.init)
            }
            switch (req.method, req.path) {
            case ("POST", "/tap"):
                guard let x = num("x"), let y = num("y") else {
                    return ["ok": false, "error": "tap requires numeric x and y"]
                }
                if let duration = num("duration"), duration > 0 {
                    screenPoint(x, y).press(forDuration: duration)
                } else {
                    screenPoint(x, y).tap()
                }
                return ["ok": true]

            case ("POST", "/swipe"):
                guard let x1 = num("x1"), let y1 = num("y1"),
                      let x2 = num("x2"), let y2 = num("y2") else {
                    return ["ok": false, "error": "swipe requires numeric x1 y1 x2 y2"]
                }
                let duration = num("duration") ?? 0.1
                screenPoint(x1, y1).press(forDuration: duration, thenDragTo: screenPoint(x2, y2))
                return ["ok": true]

            case ("POST", "/tapElement"):
                guard let id = req.body["id"] as? String,
                      let bundleId = req.body["bundleId"] as? String else {
                    return ["ok": false, "error": "tapElement requires id and bundleId"]
                }
                let app = XCUIApplication(bundleIdentifier: bundleId)
                let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
                guard element.waitForExistence(timeout: num("timeout") ?? 5) else {
                    return ["ok": false, "error": "element '\(id)' not found in \(bundleId)"]
                }
                element.tap()
                return ["ok": true]

            case ("POST", "/input"):
                guard let text = req.body["text"] as? String,
                      let bundleId = req.body["bundleId"] as? String else {
                    return ["ok": false, "error": "input requires text and bundleId"]
                }
                let app = XCUIApplication(bundleIdentifier: bundleId)
                guard app.state == .runningForeground else {
                    return ["ok": false, "error": "app \(bundleId) is not frontmost (state \(app.state.rawValue))"]
                }
                app.typeText(text)
                return ["ok": true]

            case ("POST", "/button"):
                guard let name = (req.body["name"] as? String)?.lowercased() else {
                    return ["ok": false, "error": "button requires name"]
                }
                switch name {
                case "home":
                    XCUIDevice.shared.press(.home)
                    return ["ok": true]
                default:
                    return ["ok": false, "error": "button '\(name)' is not supported by the xcuitest backend (only: home)"]
                }

            default:
                return ["ok": false, "error": "unknown endpoint \(req.method) \(req.path)"]
            }
        }
    }

    /// Minimal single-request-per-connection HTTP server on NWListener.
    /// /health and /shutdown answer on the network queue; everything else is
    /// queued for the test's main thread (XCUITest APIs are not thread-safe).
    final class DriverServer {
        struct Request { let method: String; let path: String; let body: [String: Any] }
        struct Job { let request: Request; let respond: ([String: Any]) -> Void }

        private let port: UInt16
        private var listener: NWListener?
        private let queue = DispatchQueue(label: "agent-driver.server")
        private let lock = NSLock()
        private var jobs: [Job] = []
        private var shutdown = false

        init(port: UInt16) { self.port = port }

        var shutdownRequested: Bool {
            lock.lock(); defer { lock.unlock() }
            return shutdown
        }

        func nextJob() -> Job? {
            lock.lock(); defer { lock.unlock() }
            return jobs.isEmpty ? nil : jobs.removeFirst()
        }

        func start() throws {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw NSError(domain: "AgentDriver", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "bad port \(port)"])
            }
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
            self.listener = listener
        }

        func stopListening() {
            listener?.cancel()
        }

        private func accept(_ conn: NWConnection) {
            conn.start(queue: queue)
            receive(conn, buffer: Data())
        }

        private func receive(_ conn: NWConnection, buffer: Data) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self else { conn.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                if let request = Self.parse(buf) {
                    self.dispatch(request, conn)
                } else if error == nil && !complete {
                    self.receive(conn, buffer: buf)
                } else {
                    conn.cancel()
                }
            }
        }

        private func dispatch(_ request: Request, _ conn: NWConnection) {
            switch request.path {
            case "/health":
                Self.send(conn, ["ok": true, "service": "agent-driver"])
            case "/shutdown":
                lock.lock(); shutdown = true; lock.unlock()
                Self.send(conn, ["ok": true])
            default:
                lock.lock()
                jobs.append(Job(request: request) { json in Self.send(conn, json) })
                lock.unlock()
            }
        }

        /// Returns nil while the request is still incomplete (more bytes coming).
        static func parse(_ data: Data) -> Request? {
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let requestParts = lines.first?.components(separatedBy: " ") ?? []
            guard requestParts.count >= 2 else { return nil }

            var contentLength = 0
            for line in lines.dropFirst() {
                let kv = line.split(separator: ":", maxSplits: 1)
                if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let bodyData = data[headerEnd.upperBound...]
            guard bodyData.count >= contentLength else { return nil }
            let body = (try? JSONSerialization.jsonObject(with: Data(bodyData.prefix(contentLength))))
                as? [String: Any] ?? [:]
            return Request(method: requestParts[0], path: requestParts[1], body: body)
        }

        static func send(_ conn: NWConnection, _ json: [String: Any]) {
            let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(payload)
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
    """#
}
