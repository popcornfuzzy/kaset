import SwiftUI

// MARK: - LyricsClockReader

/// Draws a lyric sheet against the live playback clock, and keeps the clock stream to itself.
///
/// The position arrives from the hidden WebView's lyrics poll ten times a second
/// (`PlayerService.currentTimeMs`). A sheet needs it; the surface *around* a sheet does not — a
/// panel's glass, a column's artwork and cards, the fullscreen player's backdrop do not change with
/// playback — so the surface that read the stream itself was rebuilt ten times a second to hand a
/// sheet a number only the sheet uses.
///
/// This is the leaf that reads it. `Observation` tracks a property per view body, so the
/// invalidation stops here: the sheet is rebuilt with the position, and everything above it is left
/// alone. The fullscreen flag is read here for the same reason — whether the player is presented is
/// not a reason to rebuild the window behind it, and it is what tells a sheet it is covered.
@available(macOS 26.0, *)
struct LyricsClockReader<Content: View>: View {
    @Environment(PlayerService.self) private var playerService
    @ViewBuilder let content: (_ currentTimeMs: Int, _ isPlaying: Bool, _ isFullscreenPresented: Bool) -> Content

    var body: some View {
        self.content(
            self.playerService.currentTimeMs,
            self.playerService.isPlaying,
            self.playerService.showFullscreenNowPlaying
        )
    }
}

// MARK: - LyricsStateView

/// The state a lyric surface shows when it has no sheet to draw: loading, no track, or no lyrics.
///
/// Shared by the classic lyrics panel and the Now Playing sidebar so both state the same things the
/// same way — the same wording, the same icons, the same provider name — with `compact` shrinking the
/// type for the sidebar's three-line preview. Extracted from `LyricsView`; see ADR-0029.
@available(macOS 26.0, *)
struct LyricsStateView: View {
    /// Icon above the title, or `nil` while loading, when a progress indicator takes its place.
    let icon: String?
    let title: String
    let message: String?
    var isLoading = false
    /// Smaller type and spacing for the sidebar's preview.
    var compact = false

    var body: some View {
        VStack(spacing: self.compact ? 8 : 12) {
            if self.isLoading {
                ProgressView()
                    .controlSize(self.compact ? .small : .regular)
                    .frame(width: self.compact ? 16 : 20, height: self.compact ? 16 : 20)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: self.compact ? 26 : 40))
                    .foregroundStyle(.tertiary)
            }

            Text(self.title)
                .font(self.compact ? .subheadline : .headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(self.compact ? .caption : .subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, self.compact ? 12 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - LyricsSearchingCaption

/// The caption a lyric surface shows while a lower-fidelity result is on screen and a better one may
/// still arrive from another provider.
///
/// The animation is left to the caller, which scopes it to this caption so a lyrics swap in the same
/// update is not animated along with it.
@available(macOS 26.0, *)
struct LyricsSearchingCaption: View {
    var onDark = false
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 10

    var body: some View {
        ShimmerLine(text: String(localized: "Still searching for lyrics"), onDark: self.onDark)
            .padding(.horizontal, self.horizontalPadding)
            .padding(.vertical, self.verticalPadding)
            .transition(.lyricsSearchingCaption)
    }
}

// MARK: - LyricsSourceFooter

/// The sticky footer under a lyric sheet: which provider supplied the lyrics, and the picker when it
/// offers more than one community version.
///
/// Shared by the classic panel and the sidebar's expanded lyric page.
@available(macOS 26.0, *)
struct LyricsSourceFooter: View {
    @Environment(SyncedLyricsService.self) private var syncedLyricsService

    let source: String?
    /// Horizontal inset of the row. The classic panel sits inside a 280pt card; the sidebar is wider.
    var horizontalPadding: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.3)

            HStack(spacing: 8) {
                if let source {
                    Text(source.hasPrefix("Source:") ? source : "Source: \(source)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                self.variantPicker
            }
            .padding(.horizontal, self.horizontalPadding)
            .padding(.vertical, 10)
        }
    }

    /// Menu for switching between the community versions the current provider offers. Hidden unless
    /// there is more than one.
    @ViewBuilder
    private var variantPicker: some View {
        let variants = self.syncedLyricsService.availableLyricsVariants
        if variants.count > 1 {
            Menu {
                ForEach(variants) { variant in
                    Button {
                        self.syncedLyricsService.selectLyricsVariant(id: variant.id)
                    } label: {
                        if variant.id == self.syncedLyricsService.selectedLyricsVariantID {
                            Label(variant.label, systemImage: "checkmark")
                        } else {
                            Text(variant.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "square.stack.3d.up")
                    Text(String(localized: "\(variants.count) versions"))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(String(localized: "Switch between community lyric versions"))
            .accessibilityLabel(String(localized: "Lyric versions"))
        }
    }
}
