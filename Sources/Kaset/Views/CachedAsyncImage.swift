import SwiftUI

// MARK: - CachedAsyncImage

/// A cached version of AsyncImage that uses ImageCache.
/// Includes a smooth crossfade transition when the image loads.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let fallbackURL: URL?
    /// Target size for image downsampling. Images are downsampled to this size to reduce memory usage.
    /// Pass the actual display size of the image for optimal memory efficiency.
    var targetSize: CGSize = .init(width: 320, height: 320)
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var isLoaded = false

    init(
        url: URL?,
        fallbackURL: URL? = nil,
        targetSize: CGSize = .init(width: 320, height: 320),
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.targetSize = targetSize
        self.content = content
        self.placeholder = placeholder
    }

    /// Whether to animate the image appearance.
    private var shouldAnimate: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        ZStack {
            if let image {
                self.content(Image(nsImage: image))
                    .opacity(self.isLoaded ? 1 : 0)
                    .animation(self.shouldAnimate ? .easeIn(duration: 0.25) : nil, value: self.isLoaded)
            } else {
                self.placeholder()
            }
        }
        .onChange(of: self.url) { _, _ in
            // Reset state when URL changes for proper UX
            self.image = nil
            self.isLoaded = false
        }
        .onChange(of: self.fallbackURL) { _, _ in
            // Reset state when fallback URL changes as well.
            self.image = nil
            self.isLoaded = false
        }
        .task(id: self.loadTaskID) {
            let loadedImage = await self.loadImage()
            guard !Task.isCancelled else { return }
            self.image = loadedImage
            self.isLoaded = true
        }
    }

    private var loadTaskID: String {
        "\(self.url?.absoluteString ?? "nil")|\(self.fallbackURL?.absoluteString ?? "nil")"
    }

    private func loadImage() async -> NSImage? {
        guard let url else {
            if let fallbackURL {
                return await ImageCache.shared.image(for: fallbackURL, targetSize: self.targetSize)
            }
            return nil
        }

        var candidates: [URL] = [url]

        if let fallbackURL {
            let hqCandidates = fallbackURL.highQualityThumbnailCandidates.filter { $0 != fallbackURL }
            candidates.append(contentsOf: hqCandidates)
            candidates.append(fallbackURL)
        }

        var seen: Set<String> = []
        for candidate in candidates {
            guard seen.insert(candidate.absoluteString).inserted else { continue }
            if let image = await ImageCache.shared.image(for: candidate, targetSize: self.targetSize) {
                return image
            }
        }

        return nil
    }
}

// MARK: - SizedProgressView

/// A simple ProgressView wrapper with proper sizing to avoid AppKit constraint warnings.
struct SizedProgressView: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(width: 20, height: 20)
    }
}

extension CachedAsyncImage where Placeholder == SizedProgressView {
    /// Convenience initializer with default ProgressView placeholder.
    init(url: URL?, fallbackURL: URL? = nil, @ViewBuilder content: @escaping (Image) -> Content) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.content = content
        self.placeholder = { SizedProgressView() }
    }
}
