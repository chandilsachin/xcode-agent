import Foundation

/// File scaffolds for `xcode create`.
enum Templates {
    /// Scaffold a Tuist-managed SwiftUI app: `Project.swift` manifest + sources.
    static func scaffoldTuistApp(name: String, dir: String, platform: String,
                                 bundleId: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/Sources", withIntermediateDirectories: true)

        let destinations = platform == "macos" ? ".macOS" : ".iOS"
        let manifest = """
        import ProjectDescription

        let project = Project(
            name: "\(name)",
            targets: [
                .target(
                    name: "\(name)",
                    destinations: \(destinations),
                    product: .app,
                    bundleId: "\(bundleId)",
                    infoPlist: .extendingDefault(with: [
                        "UILaunchScreen": [:],
                    ]),
                    sources: ["Sources/**"],
                    resources: []
                ),
            ]
        )
        """

        let app = """
        import SwiftUI

        @main
        struct \(name)App: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }

        struct ContentView: View {
            var body: some View {
                Text("Hello from \(name) 👋")
                    .padding()
            }
        }
        """

        try manifest.write(toFile: dir + "/Project.swift", atomically: true, encoding: .utf8)
        try app.write(toFile: dir + "/Sources/\(name)App.swift", atomically: true, encoding: .utf8)
        try gitignore().write(toFile: dir + "/.gitignore", atomically: true, encoding: .utf8)
    }

    /// Scaffold a plain Swift Package executable.
    static func scaffoldPackage(name: String, dir: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/Sources/\(name)", withIntermediateDirectories: true)

        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription

        let package = Package(
            name: "\(name)",
            targets: [
                .executableTarget(name: "\(name)"),
            ]
        )
        """

        let main = "print(\"Hello from \(name) 👋\")\n"

        try manifest.write(toFile: dir + "/Package.swift", atomically: true, encoding: .utf8)
        try main.write(toFile: dir + "/Sources/\(name)/main.swift", atomically: true, encoding: .utf8)
        try gitignore().write(toFile: dir + "/.gitignore", atomically: true, encoding: .utf8)
    }

    static func gitignore() -> String {
        """
        .DS_Store
        .build/
        DerivedData/
        # Tuist generates these from Project.swift (the source of truth):
        *.xcodeproj
        *.xcworkspace
        Derived/
        .tuist-derived/
        """
    }
}
