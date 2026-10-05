import SwiftUI

// MARK: - PageNavigationModel

/// The window's register of whether the page on screen has anywhere to go back to.
///
/// The window's toolbar is the app's own `NSToolbar` (see `WindowToolbarController`), so it holds the app's
/// items and nothing else — which means the back control a pushed page needs is the app's to supply too.
/// SwiftUI has one, and it draws it in *SwiftUI's* toolbar, the one the app replaces: taking that toolbar
/// back takes the back button with it, leaving a page that can be pushed into and not come back out of.
/// The reader's report is exact — on the pushed page "the other buttons are there but the back button
/// disappears".
///
/// So a page's stack states, while it is on screen, whether it can be popped and how to pop it. Both calls
/// are keyed by the page's id, the way `PageToolbarModel`'s are: a retraction from a page that is no longer
/// the published one is ignored, so the order of the outgoing page's `onDisappear` against the incoming
/// page's publication cannot leave the window showing a back control for a page that is gone.
@available(macOS 26.0, *)
@MainActor
@Observable
final class PageNavigationModel {
    /// Whether the page on screen can be popped. Read by the window when it builds the toolbar's items.
    private(set) var canGoBack = false

    /// The page that published the current state, and how it pops itself.
    private var owner: String?
    private var goBackAction: (@MainActor () -> Void)?

    /// States that the page `id` is on screen and whether it has somewhere to go back to.
    func publish(id: String, canGoBack: Bool, goBack: @escaping @MainActor () -> Void) {
        self.owner = id
        self.canGoBack = canGoBack
        self.goBackAction = goBack
    }

    /// Takes a page's back control away — unless another page has already published its own.
    func retract(id: String) {
        guard self.owner == id else { return }
        self.owner = nil
        self.canGoBack = false
        self.goBackAction = nil
    }

    /// Pops the page on screen's navigation stack. A no-op when there is nothing to pop.
    ///
    /// The published action is only run while the page still says there is somewhere to go back to: the
    /// toolbar item that calls this is drawn from the same flag, and an action that outlived its page must
    /// never be able to pop a stack the reader is no longer looking at.
    func goBack() {
        guard self.canGoBack else { return }
        self.goBackAction?()
    }
}

// MARK: - PageNavigationStack

/// A page's navigation stack, which publishes its back control to the window.
///
/// The stack itself is a plain `NavigationStack`: what this adds is the one thing a page cannot state on
/// its own — that it has somewhere to go back to — so the window's toolbar can draw the control that takes
/// it there. Replacing the pages' `NavigationStack` with this is the whole of a page's part; the path stays
/// the page's own `@State`, so everything that pushes into it keeps working unchanged.
///
/// `id` names the page for the window's register. It must be stable for as long as the page is on screen
/// and distinct per page, because it is what keeps one page's retraction from clearing another's.
@available(macOS 26.0, *)
struct PageNavigationStack<Content: View>: View {
    @Environment(PageNavigationModel.self) private var pageNavigation: PageNavigationModel?

    let id: String
    @Binding var path: NavigationPath
    private let content: () -> Content

    init(id: String, path: Binding<NavigationPath>, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self._path = path
        self.content = content
    }

    var body: some View {
        NavigationStack(path: self.$path) {
            self.content()
        }
        .onAppear { self.publish() }
        // The depth is the whole of the answer, and it changes for every push and pop — whether they came
        // from a link, a `navigationDestination`, or the page appending to the path itself.
        .onChange(of: self.path.count) { _, _ in self.publish() }
        .onDisappear { self.pageNavigation?.retract(id: self.id) }
    }

    private func publish() {
        guard let pageNavigation = self.pageNavigation else { return }
        let path = self.$path
        pageNavigation.publish(id: self.id, canGoBack: !self.path.isEmpty) {
            guard !path.wrappedValue.isEmpty else { return }
            path.wrappedValue.removeLast()
        }
    }
}
