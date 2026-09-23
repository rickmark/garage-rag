import Foundation
import Sparkle

/// Sparkle-backed updater, compiled into every configuration except the App
/// Store one. See `AppStoreUpdaterBackend.swift` for the other half.
@MainActor
enum UpdaterBackend {
    static let unavailableReason: String? = nil

    @MainActor
    static func makeDriver(configuration: UpdaterConfiguration) -> UpdaterDriving? {
        SparkleUpdaterDriver(configuration: configuration)
    }
}

@MainActor
final class SparkleUpdaterDriver: NSObject, UpdaterDriving {
    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    var onStateChange: (() -> Void)?

    /// Sparkle reads the feed URL and public key out of the app's Info.plist
    /// itself; `configuration` is only the proof that both are there, resolved
    /// before we start the updater so a misconfigured build fails visibly in
    /// the UI instead of silently at signature-check time.
    init(configuration _: UpdaterConfiguration) {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        // `canCheckForUpdates` goes false for the duration of a check, which is
        // what disables the menu item while one is running.
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.onStateChange?()
            }
        }
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            guard newValue != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = newValue
            onStateChange?()
        }
    }

    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
