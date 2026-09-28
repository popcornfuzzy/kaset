import SwiftUI

// MARK: - LyricsSubmitterCredit

/// Credits the community member who submitted the lyrics, with an optional link
/// to their provider profile.
///
/// Rendered at the end of the lyric sheet rather than pinned under it, so it
/// stays out of the reading area until the reader reaches the bottom. The link
/// uses ordinary text colours — never the system accent — so it reads as a
/// caption rather than a call to action.
@available(macOS 26.0, *)
struct LyricsSubmitterCredit: View {
    let attribution: LyricsAttribution
    /// Text and glyph colour. The fullscreen player passes white.
    var color: Color = .secondary

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let name = self.attribution.submitterName, !name.isEmpty {
            HStack(spacing: 7) {
                self.avatar
                self.label(name: name)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatar: some View {
        if let url = self.attribution.submitterAvatarURL {
            CachedAsyncImage(
                url: url,
                identity: self.attribution.submitterProfileURL?.absoluteString,
                targetSize: CGSize(width: 36, height: 36)
            ) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                self.monogram
            }
            .frame(width: 16, height: 16)
            .clipShape(.circle)
        } else {
            self.monogram
                .frame(width: 16, height: 16)
                .clipShape(.circle)
        }
    }

    /// Unison generates an avatar for every curator, but a submitter without an
    /// uploaded one comes back with no URL: fall back to their initial.
    private var monogram: some View {
        ZStack {
            Circle().fill(.quaternary)
            Text(self.initial)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(self.color)
        }
    }

    private var initial: String {
        guard let first = self.attribution.submitterName?.first else { return "?" }
        return String(first).uppercased()
    }

    // MARK: - Label

    @ViewBuilder
    private func label(name: String) -> some View {
        if let url = self.attribution.submitterProfileURL {
            Button {
                self.openURL(url)
            } label: {
                HStack(spacing: 3) {
                    Text(String(localized: "Lyrics by \(name)"))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(self.color)
            .help(String(localized: "Open the submitter's profile"))
            .accessibilityLabel(String(localized: "Lyrics by \(name), opens profile"))
        } else {
            Text(String(localized: "Lyrics by \(name)"))
                .font(.caption)
                .foregroundStyle(self.color)
        }
    }
}
