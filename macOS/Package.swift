// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Droply",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DroplyCore", targets: ["DroplyCore"]),
        .executable(name: "DroplyMac", targets: ["DroplyMac"]),
        .executable(name: "DroplyAdmin", targets: ["DroplyAdmin"])
    ],
    targets: [
        .target(
            name: "DroplyCore",
            path: "Sources/DroplyCore"
        ),
        .executableTarget(
            name: "DroplyMac",
            dependencies: ["DroplyCore"],
            path: "Sources/DroplyMac"
        ),
        .executableTarget(
            name: "DroplyAdmin",
            dependencies: ["DroplyCore"],
            path: "Sources/DroplyAdmin"
        ),
        .testTarget(
            name: "DroplyCoreTests",
            dependencies: ["DroplyCore"],
            path: "Tests/DroplyCoreTests"
        )
    ]
)
