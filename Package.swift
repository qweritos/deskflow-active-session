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
    ],
    targets: [
        .executableTarget(
            name: "DeskflowSessionSupervisor"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
