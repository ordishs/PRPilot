// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRPilotCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PRPilotModels", targets: ["PRPilotModels"]),
        .library(name: "CommandSupport", targets: ["CommandSupport"]),
        .library(name: "ReviewStore", targets: ["ReviewStore"]),
        .library(name: "GitHubKit", targets: ["GitHubKit"]),
        .library(name: "WorktreeKit", targets: ["WorktreeKit"]),
        .library(name: "DiffKit", targets: ["DiffKit"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(name: "PRPilotModels"),
        .target(name: "CommandSupport"),
        .target(name: "ReviewStore", dependencies: ["PRPilotModels"]),
        .target(name: "GitHubKit", dependencies: ["PRPilotModels", "CommandSupport"]),
        .target(name: "WorktreeKit", dependencies: ["CommandSupport"]),
        .target(name: "DiffKit", dependencies: ["CommandSupport"]),
        .target(
            name: "AgentKit",
            dependencies: [
                "PRPilotModels",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .target(
            name: "AppCore",
            dependencies: ["PRPilotModels", "ReviewStore", "GitHubKit", "CommandSupport", "WorktreeKit", "DiffKit", "AgentKit"]
        ),
        .testTarget(name: "PRPilotModelsTests", dependencies: ["PRPilotModels"]),
        .testTarget(name: "ReviewStoreTests", dependencies: ["ReviewStore", "PRPilotModels"]),
        .testTarget(name: "GitHubKitTests", dependencies: ["GitHubKit", "PRPilotModels", "CommandSupport"]),
        .testTarget(name: "CommandSupportTests", dependencies: ["CommandSupport"]),
        .testTarget(name: "WorktreeKitTests", dependencies: ["WorktreeKit", "CommandSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "PRPilotModels", "ReviewStore", "GitHubKit", "CommandSupport", "DiffKit", "AgentKit"]),
        .testTarget(name: "DiffKitTests", dependencies: ["DiffKit", "CommandSupport"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit"]),
    ]
)
