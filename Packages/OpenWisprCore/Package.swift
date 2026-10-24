// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenWisprCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "OpenWisprCore", targets: ["OpenWisprCore"]),
    ],
    targets: [
        .target(name: "OpenWisprCore"),
        .testTarget(
            name: "OpenWisprCoreTests",
            dependencies: ["OpenWisprCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
