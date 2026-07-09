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

    /// Bump DriverTemplates.revision whenever the embedded driver sources
    /// change; this stamp invalidates materialized sources AND running drivers.
    static var revisionStamp: String { version + "+" + DriverTemplates.revision }

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
        healthRevision(port: port) != nil
    }

    /// Revision stamp of the driver currently serving on this port, or nil if
    /// none is reachable.
    static func healthRevision(port: UInt16) -> String? {
        guard let response = request(port: port, method: "GET", path: "/health", timeout: 2),
              response.ok else { return nil }
        return (response.payload["revision"] as? String) ?? ""
    }

    // MARK: Lifecycle

    /// Make sure the driver is serving for this simulator; returns its port.
    /// Builds and launches on first use (slow); subsequent calls are instant.
    static func ensureRunning(udid: String, command: String, _ ctx: Context) -> UInt16 {
        let port = portFor(udid: udid)
        if let running = healthRevision(port: port) {
            if running == revisionStamp { return port }
            // A driver from an older CLI is still serving; replace it.
            Out.stderr("Restarting UI driver (was revision \(running), need \(revisionStamp))…")
            _ = request(port: port, method: "POST", path: "/shutdown", timeout: 5)
            Thread.sleep(forTimeInterval: 2)
        }

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
           stamped == revisionStamp { return }

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
            try revisionStamp.write(toFile: versionMarker, atomically: true, encoding: .utf8)
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
        env["TEST_RUNNER_AGENT_DRIVER_REVISION"] = revisionStamp
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

    /// Bump whenever any template below changes — invalidates cached driver
    /// builds and running drivers on user machines (CLI version alone isn't
    /// enough: templates can change between RCs of the same version).
    static let revision = "5"

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
            let revision = env["AGENT_DRIVER_REVISION"] ?? ""

            let server = DriverServer(port: port, revision: revision)
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
                let id = req.body["id"] as? String
                let label = req.body["label"] as? String
                guard let bundleId = req.body["bundleId"] as? String, id != nil || label != nil else {
                    return ["ok": false, "error": "tapElement requires bundleId and one of id/label"]
                }
                guard let app = foregroundApp(bundleId) else {
                    return ["ok": false, "error": "could not bring \(bundleId) to the foreground"]
                }
                let query: XCUIElementQuery
                let needle: String
                if let id = id {
                    query = app.descendants(matching: .any).matching(identifier: id)
                    needle = "id '\(id)'"
                } else {
                    // Match by exact accessibility label — reaches controls SwiftUI
                    // leaves unidentified (segmented Picker segments, alert buttons…).
                    query = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label!))
                    needle = "label '\(label!)'"
                }
                let element = query.firstMatch
                guard element.waitForExistence(timeout: num("timeout") ?? 5) else {
                    return ["ok": false, "error": "element \(needle) not found in \(bundleId)"]
                }
                // A SwiftUI Toggle/switch carries its accessibility id on a full-width
                // container whose center is the label, not the control. Drill to the
                // innermost switch descendant so the tap actually flips it.
                var target = element
                if element.elementType == .switch {
                    let inner = element.descendants(matching: .switch)
                    if inner.count > 0 { target = inner.element(boundBy: inner.count - 1) }
                }
                target.tap()
                return ["ok": true]

            case ("POST", "/input"):
                guard let text = req.body["text"] as? String,
                      let bundleId = req.body["bundleId"] as? String else {
                    return ["ok": false, "error": "input requires text and bundleId"]
                }
                guard let app = foregroundApp(bundleId) else {
                    return ["ok": false, "error": "could not bring \(bundleId) to the foreground"]
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

            case ("POST", "/hierarchy"):
                guard let bundleId = req.body["bundleId"] as? String else {
                    return ["ok": false, "error": "hierarchy requires bundleId"]
                }
                guard let app = foregroundApp(bundleId) else {
                    return ["ok": false, "error": "could not bring \(bundleId) to the foreground"]
                }
                _ = app.descendants(matching: .any).firstMatch.waitForExistence(timeout: num("timeout") ?? 5)
                return ["ok": true, "elements": [stableSnapshotTree(app)]]

            default:
                return ["ok": false, "error": "unknown endpoint \(req.method) \(req.path)"]
            }
        }

        /// Activate `bundleId` and return its XCUIApplication once frontmost.
        static func foregroundApp(_ bundleId: String) -> XCUIApplication? {
            let app = XCUIApplication(bundleIdentifier: bundleId)
            if app.state != .runningForeground { app.activate() }
            _ = app.wait(for: .runningForeground, timeout: 5)
            return app.state == .runningForeground ? app : nil
        }

        /// SwiftUI builds an element's accessibility subtree lazily, so a snapshot
        /// taken the instant the app comes foreground can be collapsed (e.g. a
        /// Stepper's +/- buttons appear as one anonymous `Other`). Re-snapshot until
        /// the node count stops growing, bounded so a genuinely small screen is fast.
        static func stableSnapshotTree(_ element: XCUIElement) -> [String: Any] {
            func count(_ n: [String: Any]) -> Int {
                let kids = (n["children"] as? [[String: Any]]) ?? []
                return 1 + kids.reduce(0) { $0 + count($1) }
            }
            var best = snapshotTree(element)
            var bestCount = count(best)
            for _ in 0..<4 {
                Thread.sleep(forTimeInterval: 0.2)
                let next = snapshotTree(element)
                let nextCount = count(next)
                if nextCount <= bestCount { break }
                best = next
                bestCount = nextCount
            }
            return best
        }

        /// Convert an XCUIElementSnapshot into the same shape `ui describe` emits,
        /// so the CLI can reuse its existing tree renderer and JSON envelope.
        static func snapshotTree(_ element: XCUIElement) -> [String: Any] {
            func typeName(_ t: XCUIElement.ElementType) -> String {
                // Human-readable role names matching accessibility conventions.
                switch t {
                case .button: return "Button"
                case .staticText: return "StaticText"
                case .textField: return "TextField"
                case .secureTextField: return "SecureTextField"
                case .image: return "Image"
                case .cell: return "Cell"
                case .navigationBar: return "NavigationBar"
                case .switch: return "Switch"
                case .slider: return "Slider"
                case .scrollView: return "ScrollView"
                case .collectionView: return "CollectionView"
                case .table: return "Table"
                case .other: return "Other"
                case .window: return "Window"
                case .application: return "Application"
                default: return "Element"
                }
            }
            func node(_ s: XCUIElementSnapshot) -> [String: Any] {
                let f = s.frame
                var dict: [String: Any] = [
                    "type": typeName(s.elementType),
                    "AXLabel": s.label,
                    "AXUniqueId": s.identifier,
                    "frame": ["x": Double(f.origin.x), "y": Double(f.origin.y),
                              "width": Double(f.size.width), "height": Double(f.size.height)],
                ]
                if let v = s.value as? String { dict["AXValue"] = v }
                dict["children"] = s.children.map { node($0) }
                return dict
            }
            if let snapshot = try? element.snapshot() { return node(snapshot) }
            return ["type": "Application", "AXLabel": "", "AXUniqueId": "", "children": []]
        }
    }

    /// Minimal single-request-per-connection HTTP server on NWListener.
    /// /health and /shutdown answer on the network queue; everything else is
    /// queued for the test's main thread (XCUITest APIs are not thread-safe).
    final class DriverServer {
        struct Request { let method: String; let path: String; let body: [String: Any] }
        struct Job { let request: Request; let respond: ([String: Any]) -> Void }

        private let port: UInt16
        private let revision: String
        private var listener: NWListener?
        private let queue = DispatchQueue(label: "agent-driver.server")
        private let lock = NSLock()
        private var jobs: [Job] = []
        private var shutdown = false

        init(port: UInt16, revision: String) {
            self.port = port
            self.revision = revision
        }

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
                Self.send(conn, ["ok": true, "service": "agent-driver", "revision": revision])
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
