// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Bonk",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Bonk",
            path: "Sources/Bonk",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
