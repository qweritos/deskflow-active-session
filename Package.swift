// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "deskflow-active-session",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "deskflow-session-supervisor",
            targets: ["DeskflowSessionSupervisor"]
        ),
        .executable(
            name: "deskflow-session-manager",
            targets: ["DeskflowSessionManager"]
        ),
        .executable(
            name: "deskflow-manager-helper",
            targets: ["DeskflowManagerHelper"]
        ),
        .executable(
            name: "deskflow-manager-installer-tool",
            targets: ["DeskflowManagerInstallerTool"]
        ),
        .library(
            name: "DeskflowManagerCore",
            targets: ["DeskflowManagerCore"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "DeskflowSessionSupervisor"
        ),
        .target(
            name: "DeskflowManagerCore"
        ),
        .executableTarget(
            name: "DeskflowSessionManager",
            dependencies: ["DeskflowManagerCore"]
        ),
        .executableTarget(
            name: "DeskflowManagerHelper",
            dependencies: ["DeskflowManagerCore"]
        ),
        .executableTarget(
            name: "DeskflowManagerInstallerTool"
        ),
        .testTarget(
            name: "DeskflowManagerCoreTests",
            dependencies: ["DeskflowManagerCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
