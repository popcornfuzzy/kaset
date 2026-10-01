import SwiftUI

/// A short caption line with a soft light sweep.
///
/// Used above the lyric sheet while a lower-fidelity result is already on screen
/// but a higher-fidelity provider is still searching. The sweep is driven by a
/// `TimelineView` rather than a repeating animation, so it runs at the display's
/// pace and stops the moment the line leaves; it is dropped entirely when the
/// system asks for reduced motion.
struct ShimmerLine: View {
    let text: String
    /// Set when the line sits on dark artwork rather than the app's own
    /// background — the fullscreen panel does — so both the label and its sheen
    /// stay legible whatever the system appearance is.
    var onDark = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Seconds for the highlight to travel the line once.
    private static let sweepPeriod: TimeInterval = 2.1

    var body: some View {
        self.label
            .frame(maxWidth: .infinity)
            .overlay {
                if !self.reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                        GeometryReader { proxy in
                            let width = max(proxy.size.width, 1)
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: self.highlight.opacity(0.0), location: 0.30),
                                    .init(color: self.highlight.opacity(0.9), location: 0.50),
                                    .init(color: self.highlight.opacity(0.0), location: 0.70),
                                    .init(color: .clear, location: 1.0),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: max(60, width * 0.55))
                            .blur(radius: 0.75)
                            .offset(x: self.sweepOffset(at: timeline.date, width: width))
                        }
                    }
                    .allowsHitTesting(false)
                    .mask(self.label)
                }
            }
    }

    private var label: some View {
        Text(self.text)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(self.onDark ? Color.white.opacity(0.7) : .secondary)
    }

    /// The highlight colour that actually reads in each appearance: a white sheen
    /// over light mode's dark text would be invisible, so light mode shines dark.
    private var highlight: Color {
        if self.onDark { return .white }
        return self.colorScheme == .dark ? .white : .primary
    }

    /// Where the highlight sits at a moment in time. The travel is eased so the
    /// light lingers at the edges and moves through the middle, and it starts and
    /// ends fully off the line so the loop has no visible seam.
    private func sweepOffset(at date: Date, width: CGFloat) -> CGFloat {
        let progress = date.timeIntervalSinceReferenceDate / Self.sweepPeriod
        let phase = progress - progress.rounded(.down) // 0 ..< 1
        let eased = phase * phase * (3 - 2 * phase) // smoothstep
        let travel = width * 2.8
        return eased * travel - travel / 2
    }
}

// MARK: - Transition

extension AnyTransition {
    /// The searching caption's enter/leave: a short lift, fade, and settle that
    /// lets the sheet below close the gap with the same spring.
    static var lyricsSearchingCaption: AnyTransition {
        .opacity
            .combined(with: .move(edge: .top))
            .combined(with: .scale(scale: 0.96, anchor: .top))
    }
}

#Preview {
    ShimmerLine(text: "Still searching for lyrics")
        .padding()
}
