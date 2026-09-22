import SwiftUI

/// Scrollable, selectable monospaced text on a faint panel: test details, error
/// tails, crash reports.
public struct MonospaceOutputBox: View {
    public let text: String
    public var maxHeight: CGFloat

    public init(_ text: String, maxHeight: CGFloat) {
        self.text = text
        self.maxHeight = maxHeight
    }

    public var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: maxHeight)
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The "Last Command Output" group box the Status, MCP and Database pages show
/// under their actions. Renders nothing while `text` is empty.
public struct LastCommandOutputBox: View {
    public let text: String
    public var maxHeight: CGFloat

    public init(text: String, maxHeight: CGFloat = 220) {
        self.text = text
        self.maxHeight = maxHeight
    }

    public var body: some View {
        if !text.isEmpty {
            GroupBox("Last Command Output") {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: maxHeight)
                .padding(8)
            }
        }
    }
}
