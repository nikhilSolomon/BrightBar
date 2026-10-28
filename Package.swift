// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BrightBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BrightBar", targets: ["BrightBar"])
    ],
    targets: [
        .executableTarget(
            name: "BrightBar",
            path: "Sources/BrightBar",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
