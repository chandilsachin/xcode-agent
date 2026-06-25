// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "xcode-agent",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "xcode-agent", targets: ["xcode"])
    ],
    targets: [
        .executableTarget(
            name: "xcode",
            path: "Sources/xcode"
        )
    ]
)
