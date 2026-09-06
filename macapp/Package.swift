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
        .library(
            name: "ModelDownloadClient",
            targets: ["ModelDownloadClient"]
        ),
    ],
    targets: [
        .target(
            name: "LlamaClient",
            path: "Sources/LlamaClient"
        ),
        .target(
            name: "ModelDownloadClient",
            path: "Sources/ModelDownloadClient"
        ),
        .executableTarget(
            name: "GarageApp",
            dependencies: ["LlamaClient", "ModelDownloadClient"],
            path: "Sources/GarageApp"
        ),
        .executableTarget(
            name: "LlamaXPCService",
            dependencies: ["LlamaClient"],
            path: "Sources/LlamaXPCService"
        ),
        .executableTarget(
            name: "ModelDownloadXPCService",
            dependencies: ["ModelDownloadClient"],
            path: "Sources/ModelDownloadXPCService"
        ),
        .executableTarget(
            name: "GarageMCPServerService",
            path: "Sources/GarageMCPServerService"
        ),
        .executableTarget(
            name: "GarageEmbedXPCService",
            path: "Sources/GarageEmbedXPCService"
        ),
        .executableTarget(
            name: "GarageIngestXPCService",
            path: "Sources/GarageIngestXPCService"
        ),
        .executableTarget(
            name: "GarageXPCService",
            path: "Sources/GarageXPCService"
        ),
        .testTarget(
            name: "GarageAppUnitTests",
            dependencies: ["GarageApp", "LlamaClient", "ModelDownloadClient"],
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
