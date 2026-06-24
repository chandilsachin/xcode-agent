import Foundation

/// What kind of buildable project lives in a directory.
enum ProjectKind {
    case tuist
    case xcworkspace(String)
    case xcodeproj(String)
    case package
    case none
}

enum Project {
    /// Detect the project in `dir`, preferring the most specific model first.
    ///
    /// Order matters: a Tuist project also contains a `Package.swift` for its
    /// dependencies and generates an `.xcworkspace`, so Tuist manifests win.
    static func detect(_ dir: String = FileManager.default.currentDirectoryPath) -> ProjectKind {
        let fm = FileManager.default

        // Tuist manifest is the source of truth when present.
        if fm.fileExists(atPath: dir + "/Project.swift")
            || fm.fileExists(atPath: dir + "/Workspace.swift")
            || fm.fileExists(atPath: dir + "/Tuist.swift")
            || fm.fileExists(atPath: dir + "/Tuist") {
            return .tuist
        }

        if let entries = try? fm.contentsOfDirectory(atPath: dir) {
            if let workspace = entries.first(where: { $0.hasSuffix(".xcworkspace") }) {
                return .xcworkspace(dir + "/" + workspace)
            }
            if let project = entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
                return .xcodeproj(dir + "/" + project)
            }
        }

        if fm.fileExists(atPath: dir + "/Package.swift") {
            return .package
        }

        return .none
    }
}
