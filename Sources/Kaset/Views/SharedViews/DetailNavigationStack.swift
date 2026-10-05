import SwiftUI

// MARK: - DetailNavigationStack

/// The detail column's navigation stack, which owns its path.
///
/// The destination views are registered by `.navigationDestinations(client:artistPath:)` on the content,
/// exactly as they were with a plain `NavigationStack`.
///
/// It exists for the routes that show a page straight from the sidebar (`SidebarSelection.playlist` and
/// Liked Music): a page that is a stack's root has no list behind it, so without a stack of its own its
/// value-based links — the Go to Artist / Go to Album items in song context menus, for instance — would
/// have nowhere to go.
///
/// The content receives the path there is no other way for a page to reach: `NavigationLink(value:)`
/// pushes by itself, but the pages that navigate with a button (the album header's artist credit needs
/// one; see `PlaylistDetailView.artistCredit(_:)`) can only push by appending to the path of the stack
/// that shows them.
@available(macOS 26.0, *)
struct DetailNavigationStack<Content: View>: View {
    @State private var path = NavigationPath()
    /// Names this page for the window's back control (see `PageNavigationStack`), and must differ from
    /// every other page's. It is passed in because the *caller* knows which page this is — a playlist's
    /// stack and Liked Music's are the same view showing different pages.
    private let id: String
    private let content: (Binding<NavigationPath>) -> Content

    init(id: String, @ViewBuilder content: @escaping (Binding<NavigationPath>) -> Content) {
        self.id = id
        self.content = content
    }

    var body: some View {
        // A `PageNavigationStack`, so a page opened straight from the sidebar states its own back control
        // to the window's toolbar exactly as a page with a stack of its own does.
        PageNavigationStack(id: self.id, path: self.$path) {
            self.content(self.$path)
        }
    }
}
