import SwiftUI

// How service states read and look, in one place per enum. The MCP page, the
// Sources page and the Status page's health cards all draw from these, so a
// state cannot be "Stopped" in one place and "not running" in green elsewhere.

extension GarageMCPStatus {
    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .failed: "Failed"
        }
    }

    func detail(endpoint: URL) -> String {
        switch self {
        case .stopped: "MCP server is not running."
        case .starting: "Starting garage-mcp on \(endpoint.absoluteString)…"
        case .running: "Listening for requests on \(endpoint.absoluteString)."
        case .stopping: "Stopping garage-mcp…"
        case .failed(let message): message
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping: .blue
        case .stopped: .secondary
        case .failed: .red
        }
    }

    var isTransitioning: Bool {
        self == .starting || self == .stopping
    }
}

extension VolumeAccessStatus {
    var title: String {
        switch self {
        case .accessGranted: "Disk Access Granted"
        case .staleBookmark: "Disk Access Stale"
        case .accessDenied: "Disk Access Denied"
        case .notConfigured: "Disk Access Not Configured"
        }
    }

    var symbol: String {
        switch self {
        case .accessGranted: "checkmark.seal.fill"
        case .staleBookmark: "exclamationmark.triangle.fill"
        case .accessDenied: "xmark.octagon.fill"
        case .notConfigured: "lock.trianglebadge.exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .accessGranted: .green
        case .staleBookmark: .yellow
        case .accessDenied: .red
        case .notConfigured: .orange
        }
    }
}
