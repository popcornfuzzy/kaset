import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The fullscreen player's key monitor sees every key the app receives, so it has to decide whose
/// key each one is before it acts (`FullscreenKeyRouting`, ADR-0026).
///
/// The two halves pull in opposite directions and both have been reported broken: a key the monitor
/// wrongly claims is stolen from the window the reader was typing into, and a key it wrongly disowns
/// is `Escape` doing nothing while the player covers the window — "sometimes leaving the fullscreen
/// player is not possible, with `Escape` or with the button". The window numbers are passed in rather
/// than a window, so both halves can be pinned without an app.
@MainActor
@Suite(.tags(.model))
struct FullscreenKeyRoutingTests {
    @Test("A key from the player's own window is the player's")
    func hostWindowKeyIsOwned() {
        #expect(FullscreenKeyRouting.owns(eventWindowNumber: 7, hostWindowNumber: 7, isSheet: false))
    }

    /// The reason the scope exists at all: a settings window or the floating mini player can be the
    /// window the reader is typing into while the player is up behind it.
    @Test("A key from another window is not the player's")
    func otherWindowKeyIsNotOwned() {
        #expect(!FullscreenKeyRouting.owns(eventWindowNumber: 8, hostWindowNumber: 7, isSheet: false))
    }

    /// A host the app could not identify must not make the player deaf: that is the state a
    /// presentation begun before the shell was installed is in, and the monitor answered every window
    /// before it had a host to compare against.
    @Test("A key with no window of its own is the player's")
    func unattributedKeyIsOwned() {
        #expect(FullscreenKeyRouting.owns(eventWindowNumber: nil, hostWindowNumber: 7, isSheet: false))
        #expect(FullscreenKeyRouting.owns(eventWindowNumber: 7, hostWindowNumber: nil, isSheet: false))
        #expect(FullscreenKeyRouting.owns(eventWindowNumber: nil, hostWindowNumber: nil, isSheet: false))
    }

    /// `Escape` in a sheet is that sheet's cancel action. The player must not close out from under a
    /// sheet it is presenting (`MainWindow`'s login and What's New sheets are shown over it).
    @Test("A sheet's keystroke is never the player's, even from the player's window")
    func sheetKeyIsNeverOwned() {
        #expect(!FullscreenKeyRouting.owns(eventWindowNumber: 7, hostWindowNumber: 7, isSheet: true))
        #expect(!FullscreenKeyRouting.owns(eventWindowNumber: nil, hostWindowNumber: 7, isSheet: true))
    }

    /// When two windows are live, the player's host is the one wearing the main window's autosave
    /// name — not merely the one that is key. Scoping to a key window instead is how the monitor ends
    /// up answering for the wrong window and leaving `Escape` dead in the player.
    @Test("The host is the window wearing the main window's name, not the key window")
    func hostIsTheNamedWindow() {
        // The other window is created and ordered front *first*, so it leads the app's window list
        // and would be the answer to "the first window" or "the frontmost window": only the autosave
        // name may decide.
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        other.setFrameAutosaveName("KasetTestsOtherWindow")
        other.orderFront(nil)
        let named = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        named.setFrameAutosaveName(AppDelegate.mainWindowAutosaveName)
        defer {
            named.orderOut(nil)
            other.orderOut(nil)
        }

        let host = FullscreenNowPlayingView.fullscreenHostWindow()
        #expect(host === named, "the host lookup did not resolve the window wearing the main window's name")
        #expect(FullscreenKeyRouting.owns(
            eventWindowNumber: host?.windowNumber,
            hostWindowNumber: named.windowNumber,
            isSheet: false
        ))
        #expect(!FullscreenKeyRouting.owns(
            eventWindowNumber: other.windowNumber,
            hostWindowNumber: named.windowNumber,
            isSheet: false
        ))
    }
}
