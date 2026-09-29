import SwiftUI

// MARK: - PlayerBarLoadingWash

/// The wash the player bar's glass wears while the shared WebView is bringing something up.
///
/// The bar's **own capsule is the mask**, and the wash is drawn *behind the bar's controls*, so the bar
/// itself is what says it is busy: nothing is covered, nothing is added next to it, and the controls the
/// user is reaching for stay exactly where they are. It is a light grey (the bar's own foreground colour
/// at low opacity, so it is grey on the light bar and a light lift on the dark one) because it is
/// feedback, not a progress bar — the point is that the user can see the bar is still working.
///
/// There are two things it can say:
///
/// - **A page load**, whose fraction WebKit reports itself. The wash deepens from the leading end and
///   crosses the capsule, so the wait has a direction and an end.
/// - **Anything else the bar waits for** — the page booting its player, playback starting, a load that
///   finished before the window had appeared — has nothing to measure, and pulses in place instead of
///   pretending to know how far along it is.
@available(macOS 26.0, *)
struct PlayerBarLoadingWash: View {
    let indicator: PlayerBarLoadingIndicator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The wash's colour: the bar's foreground, which is grey on the light bar and a lift on the dark
    /// one. The brand accent disappeared into the light bar's glass; this cannot.
    private static let tint = Color.primary

    /// How far the wash goes where the load has not reached, so the bar reads as busy from the first
    /// frame rather than growing out of nothing.
    private static let restingOpacity = 0.08
    /// Where the load has reached. Still a wash: this is feedback, not a second progress bar under the
    /// track's own.
    private static let filledOpacity = 0.22
    /// How far the wash recedes on its way down. It never goes out: a wash that disappears is exactly
    /// the "did I miss it?" it exists to answer.
    private static let dimFactor = 0.45
    /// One half of the pulse — up, or down.
    private static let pulseDuration = 1.1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Self.tint.opacity(Self.restingOpacity)

                if self.indicator.style == .determinate {
                    Self.tint.opacity(Self.filledOpacity)
                        // A sliver rather than nothing at the very start of a load, so the wash shows
                        // how far along it is from its first frame.
                        .frame(width: max(8, proxy.size.width * self.indicator.fraction))
                        .animation(self.reduceMotion ? nil : AppAnimation.standard, value: self.indicator.fraction)
                } else {
                    Self.tint.opacity(Self.filledOpacity)
                }
            }
            .mask(Capsule())
            .phaseAnimator(self.pulse) { wash, opacity in
                wash.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: Self.pulseDuration)
            }
        }
        .accessibilityHidden(true)
    }

    /// The phases the wash pulses through, or a single resting one under Reduce Motion, which cannot
    /// animate between two of them.
    private var pulse: [Double] {
        self.reduceMotion ? [1] : [Self.dimFactor, 1]
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    VStack(spacing: 24) {
        PlayerBarLoadingWash(indicator: PlayerBarLoadingIndicator(style: .determinate, fraction: 0.35))
            .frame(height: 52)
        PlayerBarLoadingWash(indicator: PlayerBarLoadingIndicator(style: .determinate, fraction: 1))
            .frame(height: 52)
        PlayerBarLoadingWash(indicator: PlayerBarLoadingIndicator(style: .indeterminate))
            .frame(height: 52)
    }
    .padding(40)
    .glassEffect(.regular.interactive(), in: .capsule)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(\.colorScheme, .light)
}
