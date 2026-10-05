import AppKit
import SwiftUI

// MARK: - PageToolbarContribution

/// A page's contribution to the window's toolbar: the page's own controls (search, sort, refresh),
/// drawn in the titlebar.
///
/// A macOS window has **one** toolbar and a `ToolbarItem` is positioned against the *window*, so with a
/// sidebar in the middle of the window no placement keeps a page's controls off it. The platform's
/// answer is a tracking separator: an item that sits on a split view's divider and bounds the region to
/// its left — which is what the window shell installs
/// ([ADR-0030](../../docs/adr/0030-appkit-window-shell.md)), and what the item order in
/// `WindowToolbarItems.identifiers` uses. These controls are therefore real toolbar items, laid out
/// against the Now Playing column's divider and unable to land on the column at any width.
///
/// The contribution is a *view*, not a description of one: the page's controls read the page's model,
/// and a hosted view observes that model itself, so a search field in the titlebar and the list it
/// filters are looking at exactly the same state.
@available(macOS 26.0, *)
struct PageToolbarContribution {
    /// Identity of the page that published it. Two contributions with the same id are the same
    /// contribution; a different id means the reader is on a different page, and the toolbar rebuilds
    /// the item — which is also what keeps one page's half-typed query or focused field out of the next.
    let id: String
    /// The controls, drawn as one group in the toolbar's page region.
    let content: AnyView
}

// MARK: - PageToolbarModel

/// The window's register of what the page on screen wants in the toolbar.
///
/// A page publishes on appearance and retracts on disappearance, and both calls are keyed by the page's
/// id: a retraction from a page that is no longer the published one is ignored, so the order of the
/// outgoing page's `onDisappear` against the incoming page's `onAppear` cannot leave the window showing
/// the wrong page's controls.
@available(macOS 26.0, *)
@MainActor
@Observable
final class PageToolbarModel {
    private(set) var contribution: PageToolbarContribution?

    func contribute(_ contribution: PageToolbarContribution) {
        self.contribution = contribution
    }

    /// Takes this page's controls away — unless another page has already published its own.
    func retract(id: String) {
        guard self.contribution?.id == id else { return }
        self.contribution = nil
    }
}

// MARK: - PageToolbarModifier

/// Publishes a page's controls to the window for as long as the page is on screen.
@available(macOS 26.0, *)
private struct PageToolbarModifier<Controls: View>: ViewModifier {
    @Environment(PageToolbarModel.self) private var pageToolbar: PageToolbarModel?

    let id: String
    @ViewBuilder var controls: Controls

    func body(content: Content) -> some View {
        content
            .onAppear {
                self.pageToolbar?.contribute(
                    PageToolbarContribution(
                        id: self.id,
                        // Identity by page: switching pages must not carry a search field's text or
                        // focus into the page that replaces it.
                        content: AnyView(self.controls.id(self.id))
                    )
                )
            }
            .onDisappear {
                self.pageToolbar?.retract(id: self.id)
            }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Publishes this page's toolbar controls to the window's toolbar while the page is on screen.
    ///
    /// The window has one toolbar, so a page does not *declare* items — it states what they should be
    /// for as long as it is the page on screen (see `PageToolbarModel`).
    func pageToolbar<Controls: View>(
        id: String,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        self.modifier(PageToolbarModifier(id: id, controls: controls))
    }
}

// MARK: - PageRefreshButton

/// A page's refresh control, as a toolbar item.
///
/// A page's manual refresh is a *background* refresh: it keeps the list on screen and swaps it when the
/// new one arrives, so the page's own `LoadingState` cannot say whether one is running (it is `.loaded`
/// throughout). The page's model owns that flag instead (`isRefreshing`), which is what lets this control
/// in the titlebar and the page below it read the same state from two different view trees.
@available(macOS 26.0, *)
struct PageRefreshButton: View {
    let help: LocalizedStringKey
    /// Asked during this view's own render, not captured as a value: the answer lives on the page's
    /// model, and reading it here is what ties the toolbar item to that model — a value read when the
    /// page published its controls would be a snapshot, and the spinner would never start.
    let isRefreshing: () -> Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(self.isRefreshing() ? 360 : 0))
                .animation(
                    self.isRefreshing() ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                    value: self.isRefreshing()
                )
        }
        .help(self.help)
        .disabled(self.isRefreshing())
    }
}
