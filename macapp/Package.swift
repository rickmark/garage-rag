// swift-tools-version:5.10
// NOTE: This manifest only builds the client/XPC library targets (LlamaClient, ModelDownloadClient, IngestClient,
// MCPServerClient) for quick iteration. It does NOT build GarageApp or the XPC services: those need gRPC-Swift,
// SwiftProtobuf, PythonKit and the vendored Python/Postgres/llama.cpp from the Bazel build (see README.md).
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
        .library(
            name: "MCPServerClient",
            targets: ["MCPServerClient"]
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
        .target(
            name: "MCPServerClient",
            path: "Sources/MCPServerClient"
        ),
        .executableTarget(
            name: "GarageApp",
            dependencies: ["LlamaClient", "ModelDownloadClient", "IngestClient", "MCPServerClient"],
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
            dependencies: ["MCPServerClient"],
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
            dependencies: ["GarageApp", "LlamaClient", "ModelDownloadClient", "IngestClient", "MCPServerClient"],
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
