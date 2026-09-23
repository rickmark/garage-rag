import AppKit
import SwiftUI

/// A two-pane horizontal split that holds its divider at a fraction of the
/// available width rather than at a fixed offset.
///
/// `HSplitView` treats `idealWidth` as a hint it is free to ignore, and once the
/// user resizes the window it hands the extra space to whichever pane AppKit
/// picks, so a "one third / two thirds" layout drifts. Here the divider is a
/// fraction: it starts at `initialFraction`, dragging moves it, and resizing the
/// window keeps the proportion. The pane minimums win over the fraction when the
/// two disagree, the trailing pane's first.
struct ProportionalSplitView<Leading: View, Trailing: View>: View {
    private let minLeadingWidth: CGFloat
    private let minTrailingWidth: CGFloat
    private let leading: Leading
    private let trailing: Trailing

    @State private var fraction: CGFloat
    /// The fraction when the current drag began; nil between drags.
    @State private var dragStartFraction: CGFloat?

    init(
        initialFraction: CGFloat,
        minLeadingWidth: CGFloat = 0,
        minTrailingWidth: CGFloat = 0,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        _fraction = State(initialValue: initialFraction)
        self.minLeadingWidth = minLeadingWidth
        self.minTrailingWidth = minTrailingWidth
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let leadingWidth = Self.leadingWidth(
                fraction: fraction,
                totalWidth: totalWidth,
                minLeading: minLeadingWidth,
                minTrailing: minTrailingWidth
            )

            HStack(spacing: 0) {
                leading
                    .frame(width: leadingWidth)
                divider(totalWidth: totalWidth)
                trailing
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func divider(totalWidth: CGFloat) -> some View {
        Divider()
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            // A 1pt line is too thin to grab; widen the hit area without
            // taking any layout space from the panes.
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                guard totalWidth > 0 else { return }
                                let start = dragStartFraction ?? fraction
                                dragStartFraction = start
                                let proposed = start + value.translation.width / totalWidth
                                fraction = min(max(proposed, 0), 1)
                            }
                            .onEnded { _ in
                                // Store what is actually on screen, so a drag
                                // past a minimum doesn't leave a hidden overshoot
                                // to be dragged back through.
                                if totalWidth > 0 {
                                    fraction = Self.leadingWidth(
                                        fraction: fraction,
                                        totalWidth: totalWidth,
                                        minLeading: minLeadingWidth,
                                        minTrailing: minTrailingWidth
                                    ) / totalWidth
                                }
                                dragStartFraction = nil
                            }
                    )
            )
    }

    /// The leading pane's width for `fraction` of `totalWidth`, clamped so
    /// each pane keeps its minimum. When both minimums can't fit, the trailing
    /// pane keeps its minimum and the leading pane takes what is left.
    static func leadingWidth(
        fraction: CGFloat,
        totalWidth: CGFloat,
        minLeading: CGFloat,
        minTrailing: CGFloat
    ) -> CGFloat {
        let proposed = max(fraction * totalWidth, minLeading)
        return max(min(proposed, totalWidth - minTrailing), 0)
    }
}
