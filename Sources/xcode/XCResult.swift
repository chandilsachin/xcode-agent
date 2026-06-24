import Foundation

/// Parses an `.xcresult` bundle using `xcresulttool` for per-test details.
/// Requires full Xcode (xcresulttool is not included in Command Line Tools).
///
/// Uses the modern `xcresulttool get test-results tests` API (Xcode 16+).
/// Falls back to the legacy `get object --legacy` API for older Xcode installs.
enum XCResult {

    struct TestCase {
        let identifier: String
        let name: String
        let status: String        // "passed" | "failed" | "skipped"
        let duration: Double      // seconds
        var failureMessage: String?

        var jsonDict: [String: Any] {
            var d: [String: Any] = [
                "identifier": identifier,
                "name": name,
                "status": status,
                "duration": duration,
            ]
            if let msg = failureMessage { d["failureMessage"] = msg }
            return d
        }
    }

    struct Summary {
        let tests: [TestCase]
        var totalTests: Int  { tests.count }
        var passed:     Int  { tests.filter { $0.status == "passed"  }.count }
        var failed:     Int  { tests.filter { $0.status == "failed"  }.count }
        var skipped:    Int  { tests.filter { $0.status == "skipped" }.count }
        var durationSeconds: Double { tests.reduce(0.0) { $0 + $1.duration } }
    }

    /// Parse an xcresult bundle. Returns nil if xcresulttool is unavailable,
    /// the bundle doesn't exist, or no test data is present.
    static func parse(path: String) -> Summary? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return parseModern(path: path) ?? parseLegacy(path: path)
    }

    // MARK: - Modern API (Xcode 16+)

    /// `xcresulttool get test-results tests --path <path> --format json`
    private static func parseModern(path: String) -> Summary? {
        let result = Shell.run("/usr/bin/xcrun",
            ["xcresulttool", "get", "test-results", "tests", "--path", path, "--format", "json"])
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let testNodes = json["testNodes"] as? [[String: Any]]
        else { return nil }

        var cases: [TestCase] = []
        for node in testNodes { collectModern(node, into: &cases) }
        return cases.isEmpty ? nil : Summary(tests: cases)
    }

    /// Recursively walk the `testNodes` tree. Leaves with `nodeType == "Test Case"` are tests.
    private static func collectModern(_ node: [String: Any], into cases: inout [TestCase]) {
        let nodeType = node["nodeType"] as? String ?? ""

        if nodeType == "Test Case" {
            let name       = node["name"] as? String ?? ""
            let identifier = node["nodeIdentifier"] as? String ?? name
            let rawResult  = node["result"] as? String ?? ""
            let duration   = node["durationInSeconds"] as? Double ?? 0.0

            let status: String
            switch rawResult {
            case "Passed":  status = "passed"
            case "Failed":  status = "failed"
            case "Skipped": status = "skipped"
            default:        status = rawResult.isEmpty ? "unknown" : rawResult.lowercased()
            }

            var failureMsg: String?
            if status == "failed", let children = node["children"] as? [[String: Any]] {
                failureMsg = children
                    .filter { ($0["nodeType"] as? String) == "Failure Message" }
                    .compactMap { $0["name"] as? String }
                    .joined(separator: "; ")
                    .nonEmpty
            }

            cases.append(TestCase(
                identifier:     identifier,
                name:           name,
                status:         status,
                duration:       duration,
                failureMessage: failureMsg
            ))
        } else if let children = node["children"] as? [[String: Any]] {
            for child in children { collectModern(child, into: &cases) }
        }
    }

    // MARK: - Legacy API (Xcode 15 and earlier)

    /// `xcresulttool get object --legacy --path <path> --format json`
    private static func parseLegacy(path: String) -> Summary? {
        guard let root = legacyGet(path: path, id: nil) else { return nil }

        // Navigate: actions._values[0].actionResult.testsRef.id._value
        guard
            let actions     = (root["actions"] as? [String: Any])?["_values"] as? [[String: Any]],
            let firstAction = actions.first,
            let ar          = firstAction["actionResult"] as? [String: Any],
            let testsRef    = ar["testsRef"] as? [String: Any],
            let refId       = (testsRef["id"] as? [String: Any])?["_value"] as? String
        else { return nil }

        guard let planSummaries = legacyGet(path: path, id: refId) else { return nil }

        var cases: [TestCase] = []
        let summaries = (planSummaries["summaries"] as? [String: Any])?["_values"] as? [[String: Any]] ?? []
        for summary in summaries {
            let ts = (summary["testableSummaries"] as? [String: Any])?["_values"] as? [[String: Any]] ?? []
            for ts2 in ts {
                let topTests = (ts2["tests"] as? [String: Any])?["_values"] as? [[String: Any]] ?? []
                for node in topTests { collectLegacy(node, into: &cases, xcresultPath: path) }
            }
        }
        return cases.isEmpty ? nil : Summary(tests: cases)
    }

    private static func collectLegacy(_ node: [String: Any], into cases: inout [TestCase], xcresultPath: String) {
        let typeName = (node["_type"] as? [String: Any])?["_name"] as? String ?? ""
        if typeName == "ActionTestMetadata" {
            let identifier  = (node["identifier"]  as? [String: Any])?["_value"] as? String ?? ""
            let name        = (node["name"]        as? [String: Any])?["_value"] as? String ?? identifier
            let rawStatus   = (node["testStatus"]  as? [String: Any])?["_value"] as? String ?? ""
            let durationStr = (node["duration"]    as? [String: Any])?["_value"] as? String ?? "0"
            let status: String
            switch rawStatus {
            case "Success": status = "passed"
            case "Failure": status = "failed"
            case "Skipped": status = "skipped"
            default:        status = rawStatus.isEmpty ? "unknown" : rawStatus.lowercased()
            }

            var failureMsg: String?
            if status == "failed",
               let summaryRef = node["summaryRef"] as? [String: Any],
               let summaryId  = (summaryRef["id"] as? [String: Any])?["_value"] as? String,
               let detail     = legacyGet(path: xcresultPath, id: summaryId),
               let failures   = (detail["failureSummaries"] as? [String: Any])?["_values"] as? [[String: Any]],
               let first      = failures.first {
                failureMsg = (first["message"] as? [String: Any])?["_value"] as? String
            }

            cases.append(TestCase(identifier: identifier, name: name, status: status,
                                  duration: Double(durationStr) ?? 0.0, failureMessage: failureMsg))
        } else if let subtests = (node["subtests"] as? [String: Any])?["_values"] as? [[String: Any]] {
            for sub in subtests { collectLegacy(sub, into: &cases, xcresultPath: xcresultPath) }
        }
    }

    private static func legacyGet(path: String, id: String?) -> [String: Any]? {
        var args = ["xcresulttool", "get", "object", "--legacy", "--path", path, "--format", "json"]
        if let id { args += ["--id", id] }
        let result = Shell.run("/usr/bin/xcrun", args)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
