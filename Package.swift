// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AWGAppRouter",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AWGAppRouterKit"),
        .executableTarget(name: "AWGAppRouter", dependencies: ["AWGAppRouterKit"]),
        .executableTarget(name: "awgapprouterd", dependencies: ["AWGAppRouterKit"]),
        .testTarget(name: "AWGAppRouterKitTests", dependencies: ["AWGAppRouterKit"]),
    ]
)
