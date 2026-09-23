import SwiftUI

/// A small ladybug tab pinned to the trailing edge of the main window that
/// opens the bug reporter.
///
/// It sits flush against the window edge and stays a narrow tab until the
/// pointer reaches it, so it is always there without claiming room from the
/// views underneath. The reporter itself is a sheet owned by `ContentView`;
/// the nub only asks for it.
struct BugNub: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .garageShowBugReport, object: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                    .foregroundStyle(.red)
                if isHovering {
                    Text("Report a Bug")
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(height: 26)
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8))
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .opacity(isHovering ? 1 : 0.75)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .help("Report a Bug… (⇧⌘B)")
        .accessibilityLabel("Report a Bug")
        .accessibilityIdentifier("bugNub")
    }
}
