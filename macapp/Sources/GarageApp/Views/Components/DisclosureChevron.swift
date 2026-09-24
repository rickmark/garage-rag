import SwiftUI

/// The chevron that expands and collapses a row. One chevron that rotates, rather than two
/// symbols swapped, so the change animates with the row; sized and padded to be an easy target.
struct DisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}
