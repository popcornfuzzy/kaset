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
    private let content: (Binding<NavigationPath>) -> Content

    init(@ViewBuilder content: @escaping (Binding<NavigationPath>) -> Content) {
        self.content = content
    }

    var body: some View {
        NavigationStack(path: self.$path) {
            self.content(self.$path)
        }
    }
}
