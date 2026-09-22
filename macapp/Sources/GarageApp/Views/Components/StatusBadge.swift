import SwiftUI

/// The small rounded tag the app uses for states, counts and categories.
///
/// One implementation for every page: the text takes `tint`, the background is
/// `tint` at low opacity unless `fill` overrides it (a neutral count, say).
public struct StatusBadge: View {
    public let text: String
    public let tint: Color
    public var fill: Color?
    public var monospaced: Bool
    public var weight: Font.Weight
    public var symbol: String?

    public init(
        _ text: String,
        tint: Color,
        fill: Color? = nil,
        monospaced: Bool = false,
        weight: Font.Weight = .bold,
        symbol: String? = nil
    ) {
        self.text = text
        self.tint = tint
        self.fill = fill
        self.monospaced = monospaced
        self.weight = weight
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.system(size: 9, weight: weight, design: monospaced ? .monospaced : .default))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(fill ?? tint.opacity(0.15))
        .foregroundStyle(tint)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// A neutral monospaced tag for identifiers (a source slug, a match kind).
public struct TagBadge: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        StatusBadge(text, tint: .primary, fill: Color.secondary.opacity(0.12), monospaced: true, weight: .medium)
    }
}

public struct CorpusClassBadge: View {
    public let corpusClass: String

    public init(corpusClass: String) {
        self.corpusClass = corpusClass
    }

    public var body: some View {
        StatusBadge(corpusClass.capitalized, tint: tint, monospaced: true)
    }

    private var tint: Color {
        switch corpusClass.lowercased() {
        case "code": return .purple
        case "communication": return .green
        default: return .blue
        }
    }
}

public struct TrustTierBadge: View {
    public let tier: String

    public init(tier: String) {
        self.tier = tier
    }

    public var body: some View {
        StatusBadge(tier.capitalized, tint: tint, monospaced: true)
    }

    private var tint: Color {
        switch tier.lowercased() {
        case "authored": return .teal
        case "reference": return .indigo
        case "received": return .orange
        default: return .secondary
        }
    }
}

public struct LogLevelBadge: View {
    public let level: LogLevel

    public init(level: LogLevel) {
        self.level = level
    }

    public var body: some View {
        StatusBadge(level.rawValue.uppercased(), tint: tint, monospaced: true, symbol: symbol)
    }

    private var symbol: String {
        switch level {
        case .debug: return "ant.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// stdout vs stderr origin of a log line.
public struct LogStreamBadge: View {
    public let stream: LogLine.Stream

    public init(stream: LogLine.Stream) {
        self.stream = stream
    }

    public var body: some View {
        StatusBadge(stream.rawValue, tint: stream == .stderr ? .red : .secondary, monospaced: true, weight: .medium)
    }
}
