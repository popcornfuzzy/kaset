import SwiftUI

// MARK: - NavigateToArtistAction

/// Pushes an artist page onto the enclosing `DetailNavigationStack`.
///
/// A value-based `NavigationLink` is the usual way to do this, but it cannot be used inside a `List`
/// row: the row becomes selectable, the table paints its selection over the whole row (accent while
/// the window is key, gray while it is not), and once the row's link has pushed its page it keeps the
/// activation — a second click on the same link is swallowed and the artist page stops opening. Plain
/// buttons push through this action instead. See ADR-0023.
struct NavigateToArtistAction: Sendable {
    private let push: @MainActor @Sendable (Artist) -> Void

    init(push: @escaping @MainActor @Sendable (Artist) -> Void) {
        self.push = push
    }

    @MainActor
    func callAsFunction(_ artist: Artist) {
        self.push(artist)
    }
}

extension EnvironmentValues {
    /// Pushes an artist page onto the enclosing detail stack. Does nothing without a
    /// `DetailNavigationStack` above the view.
    @Entry var navigateToArtist = NavigateToArtistAction { _ in }
}

// MARK: - DetailNavigationStack

/// The detail column's navigation stack, which owns its path so `navigateToArtist` can push.
///
/// The destination views are registered by `.navigationDestinations(client:)` on the content, exactly
/// as they were with a plain `NavigationStack`.
@available(macOS 26.0, *)
struct DetailNavigationStack<Content: View>: View {
    @State private var path = NavigationPath()
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationStack(path: self.$path) {
            self.content
                .environment(\.navigateToArtist, NavigateToArtistAction { artist in
                    self.path.append(artist)
                })
        }
    }
}
