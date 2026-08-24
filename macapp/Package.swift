// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Garage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GarageApp",
            path: "Sources/GarageApp"
        )
    ]
)
