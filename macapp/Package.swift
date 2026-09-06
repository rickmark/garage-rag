// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Garage",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "LlamaClient",
            targets: ["LlamaClient"]
        ),
    ],
    targets: [
        .target(
            name: "LlamaClient",
            path: "Sources/LlamaClient"
        ),
        .executableTarget(
            name: "GarageApp",
            dependencies: ["LlamaClient"],
            path: "Sources/GarageApp"
        ),
        .executableTarget(
            name: "LlamaXPCService",
            dependencies: ["LlamaClient"],
            path: "Sources/LlamaXPCService"
        ),
        .executableTarget(
            name: "PythonXPCService",
            path: "Sources/PythonXPCService"
        ),
        .testTarget(
            name: "GarageAppUnitTests",
            dependencies: ["GarageApp", "LlamaClient"],
            path: "Tests/GarageAppUnitTests"
        ),
        .testTarget(
            name: "GarageAppUITests",
            dependencies: ["GarageApp"],
            path: "Tests/GarageAppUITests"
        ),
        .testTarget(
            name: "LlamaClientTests",
            dependencies: ["LlamaClient"],
            path: "Tests/LlamaClientTests"
        ),
    ]
)
