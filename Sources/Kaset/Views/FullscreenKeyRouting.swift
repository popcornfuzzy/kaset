import Foundation

// MARK: - FullscreenKeyRouting

/// Which window a keystroke the fullscreen player sees actually belongs to.
///
/// The player installs one local key monitor for the length of a presentation
/// (`FullscreenNowPlayingView.installKeyMonitorIfNeeded`, [ADR-0026](../../../docs/adr/0026-fullscreen-key-routing.md)),
/// and a local monitor sees *every* key the app receives — including the ones typed into the mini
/// player panel, a settings window, or a sheet. So the monitor has to answer one question before it
/// does anything: is this the player's key, or somebody else's?
///
/// Getting it wrong is not symmetric. A key the monitor wrongly claims is a keystroke stolen from
/// whatever the reader was actually typing into; a key it wrongly disowns is `Escape` doing nothing
/// while the player covers the window — reported as "sometimes leaving the fullscreen player is not
/// possible, with `Escape` or with the button", where the button half is
/// `FullscreenKeyRouting.ownsWindow` being asked about a window the app had already moved on from.
///
/// The rule takes *numbers*, not windows, so it can be stated and pinned without an app: the host is
/// resolved per keystroke rather than remembered when the monitor was installed, because the app's
/// window list is not fixed (a settings window opens, the mini player panel is created, the main
/// window is re-keyed) and a number captured once is a number that can be wrong for every key after
/// it.
enum FullscreenKeyRouting {
    /// Whether a key-down belongs to the presented player.
    ///
    /// - `nil` on either side means "no window to compare" — an event AppKit did not attribute to a
    ///   window, or a presentation that happened before the app's main window could be identified.
    ///   Both answer `true`, which is what the monitor did before it had a host to compare against:
    ///   the player is on screen and covering a window, so an unattributable key is far more likely
    ///   to be the reader's keypress into the player than a stray one from elsewhere.
    /// - A sheet is never the player's: `Escape` in a sheet is that sheet's cancel action, and the
    ///   player must not close out from under it.
    static func owns(
        eventWindowNumber: Int?,
        hostWindowNumber: Int?,
        isSheet: Bool
    ) -> Bool {
        if isSheet { return false }
        guard let eventWindowNumber, let hostWindowNumber else { return true }
        return eventWindowNumber == hostWindowNumber
    }
}
