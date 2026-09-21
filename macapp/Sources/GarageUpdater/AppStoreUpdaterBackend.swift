import Foundation

/// The App Store configuration ships no Sparkle at all: Apple rejects apps that
/// update themselves, and the framework would be dead weight inside the sandbox
/// anyway. `//macapp/Sources/GarageUpdater/BUILD.bazel` swaps this file in for
/// `SparkleUpdaterBackend.swift` under `//bazel:is_store`, which is also what
/// keeps `@sparkle` out of that build's dependency graph.
enum UpdaterBackend {
    static let unavailableReason: String? = "Garage from the Mac App Store updates through the App Store."

    static func makeDriver(configuration _: UpdaterConfiguration) -> UpdaterDriving? {
        nil
    }
}
