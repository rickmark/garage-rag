import Foundation
import Security

/// The App Group the app and its XPC services share, and the data directory that lives in it.
///
/// Both distributions sign with it: the App Store build (sandboxed) and the Developer ID build
/// (not sandboxed). The identifier carries the team prefix, the macOS form, which a Developer ID
/// app may use for the group *container* without a provisioning profile. Keeping the data in the
/// group container is what lets both builds open the same database, models and logs. The same
/// identifier is the access group of the shared Keychain item (`GaragePostgresEndpoint`); that use
/// needs an application identifier backed by a provisioning profile, which the Developer ID and App
/// Store builds of the app and of the launcher helper bundles embed.
public enum GarageAppGroup {
    public static let identifier = "DWVXMLB45Y.group.me.rickmark.garage-rag"

    /// Folder name below `Library/Application Support`, in the group container or the per-user one.
    public static let dataFolderName = "GarageApp"

    /// True when this process is signed with the group entitlement. Locally signed and test builds
    /// are not; on macOS 15+ touching a group container without it can prompt the user, so they
    /// never try.
    public static let isEntitled: Bool = {
        guard let groups = entitlementValue("com.apple.security.application-groups") as? [String] else {
            return false
        }
        return groups.contains(identifier)
    }()

    /// True in the App Sandbox (the App Store build). An unsandboxed build (Developer ID) can also
    /// reach the per-user Application Support folder, the one people and support instructions look in.
    public static let isSandboxed: Bool = {
        (entitlementValue("com.apple.security.app-sandbox") as? Bool) == true
    }()

    private static func entitlementValue(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }

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

    /// The directory for the database, models, logs and `garage.json`: the `--data-directory`
    /// override when given, else the shared one when entitled, otherwise the per-user one.
    public static var dataDirectory: URL {
        dataDirectoryOverride ?? sharedDataDirectory ?? legacyDataDirectory
    }

    /// The folder `--data-directory <path>` names, or nil. XPC services never get the app's
    /// arguments, so in them this is always nil.
    public static let dataDirectoryOverride: URL? = {
        do {
            return try dataDirectoryOverride(in: CommandLine.arguments, realDirectories: realDataDirectories)
        } catch {
            // Falling back to the real folder would let a test reset the real database.
            fatalError("\(error)")
        }
    }()

    public struct UnsafeDataDirectory: Error, CustomStringConvertible {
        public let description: String
    }

    /// Parses `--data-directory <path>`. Throws when the path is missing or relative, or when it is,
    /// contains, or lies inside one of `realDirectories` (after following links: the per-user folder
    /// is usually a link to the group one).
    public static func dataDirectoryOverride(in arguments: [String], realDirectories: [URL]) throws -> URL? {
        guard let flag = arguments.firstIndex(of: GarageAppLaunch.dataDirectoryArgument) else { return nil }
        guard flag + 1 < arguments.count, arguments[flag + 1].hasPrefix("/") else {
            throw UnsafeDataDirectory(description: "\(GarageAppLaunch.dataDirectoryArgument) needs an absolute path")
        }
        let url = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true).standardizedFileURL
        let candidate = resolvedComponents(url)
        for real in realDirectories {
            let realComponents = resolvedComponents(real)
            if candidate.starts(with: realComponents) || realComponents.starts(with: candidate) {
                throw UnsafeDataDirectory(
                    description: "refusing \(GarageAppLaunch.dataDirectoryArgument) \(url.path): it overlaps \(real.path)"
                )
            }
        }
        return url
    }

    /// Where real data can live: the per-user folder, the group container and the App Store
    /// sandbox container. Built from the real home folder, without touching the group container.
    public static var realDataDirectories: [URL] {
        let home = URL(fileURLWithPath: realHomeDirectory, isDirectory: true)
        return [
            legacyDataDirectory,
            home.appendingPathComponent("Library/Application Support/\(dataFolderName)", isDirectory: true),
            home.appendingPathComponent("Library/Group Containers/\(identifier)", isDirectory: true),
            home.appendingPathComponent("Library/Containers/me.rickmark.garage-rag", isDirectory: true),
        ]
    }

    /// The account's home folder, also in the sandbox (where `NSHomeDirectory()` is the container).
    private static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// Path components after resolving links in the longest existing prefix, so a folder that does
    /// not exist yet still compares correctly against one that does.
    private static func resolvedComponents(_ url: URL) -> [String] {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return existing.resolvingSymlinksInPath().pathComponents + missing
    }
}
