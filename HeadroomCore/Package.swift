// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HeadroomCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "HeadroomCore",
            targets: ["HeadroomCore"]
        )
    ],
    targets: [
        .target(
            name: "HeadroomCore",
            dependencies: [],
            path: "Sources/HeadroomCore"
        ),
        .testTarget(
            name: "HeadroomCoreTests",
            dependencies: ["HeadroomCore"],
            path: "Tests/HeadroomCoreTests"
        )
    ]
)
