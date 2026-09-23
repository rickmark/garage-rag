import Foundation
import Security

/// The App Group the app and its XPC services share, and the data directory that lives in it.
///
/// Both distributions sign with it: the App Store build (sandboxed) and the Developer ID build
/// (not sandboxed). The identifier carries the team prefix, the macOS form, which a Developer ID
/// app may use without a provisioning profile. Keeping the data in the group container is what
/// lets both builds open the same database, models and logs.
public enum GarageAppGroup {
    public static let identifier = "DWVXMLB45Y.group.me.rickmark.garage-rag"

    /// Folder name below `Library/Application Support`, in the group container or the per-user one.
    public static let dataFolderName = "GarageApp"

    /// True when this process is signed with the group entitlement. Locally signed and test builds
    /// are not; on macOS 15+ touching a group container without it can prompt the user, so they
    /// never try.
    public static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String] else {
            return false
        }
        return groups.contains(identifier)
    }()

    /// `<group container>/Library/Application Support/GarageApp`, or nil when this process has no
    /// entitlement for the group.
    public static var sharedDataDirectory: URL? {
        guard isEntitled,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return nil
        }
        return container
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(dataFolderName, isDirectory: true)
    }

    /// Where builds before the group container kept their data: `~/Library/Application Support/GarageApp`
    /// for the Developer ID build, the sandbox container's Application Support for the App Store build.
    public static var legacyDataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(dataFolderName, isDirectory: true)
    }

    /// The directory for the database, models, logs and `garage.json`: the shared one when entitled,
    /// otherwise the per-user one.
    public static var dataDirectory: URL {
        sharedDataDirectory ?? legacyDataDirectory
    }
}
