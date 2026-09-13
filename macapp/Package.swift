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
        .library(
            name: "IngestClient",
            targets: ["IngestClient"]
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
        .target(
            name: "IngestClient",
            path: "Sources/IngestClient"
        ),
        .executableTarget(
            name: "GarageApp",
            dependencies: ["LlamaClient", "ModelDownloadClient", "IngestClient"],
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
            dependencies: ["IngestClient"],
            path: "Sources/GarageEmbedXPCService"
        ),
        .executableTarget(
            name: "GarageIngestXPCService",
            dependencies: ["IngestClient"],
            path: "Sources/GarageIngestXPCService"
        ),
        .executableTarget(
            name: "GarageXPCService",
            path: "Sources/GarageXPCService"
        ),
        .testTarget(
            name: "GarageAppUnitTests",
            dependencies: ["GarageApp", "LlamaClient", "ModelDownloadClient", "IngestClient"],
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
