import SwiftUI

// MARK: - LyricsBackgroundVocalsView

/// Backing vocals sung over a lyric line, shown dimmed and a little smaller than
/// the lead so they read as accompaniment rather than as the line itself.
///
/// The text is passed already joined, in the provider's own spacing: the ordering
/// and spacing of the words belongs to the lyrics model, not to the renderer.
@available(macOS 26.0, *)
struct LyricsBackgroundVocalsView: View {
    let text: String
    var fontSize: CGFloat = 14
    var color: Color = .secondary
    var lineSpacing: CGFloat = 2

    var body: some View {
        Text(self.text)
            .font(.system(size: self.fontSize, weight: .semibold))
            .foregroundStyle(self.color)
            .lineSpacing(self.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
