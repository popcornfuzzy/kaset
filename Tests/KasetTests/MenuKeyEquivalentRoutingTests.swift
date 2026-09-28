import AppKit
import Testing

/// The fullscreen player's key monitor hands every key to the app's menu before anything inside the
/// player can take it (`FullscreenNowPlayingView.installKeyMonitorIfNeeded`, ADR-0026). That only
/// works if the menu answers the keys the app declares, and the one that was reported broken in the
/// player — `Space` — is exactly the key AppKit treats differently: a key equivalent with an **empty
/// modifier mask** is the case the normal event route gives the responder chain a crack at first,
/// which is how a focused control in the player was eating it.
///
/// So this pins the assumption the fix rests on: an unmodified `Space` key-down handed straight to
/// the menu item is performed. If AppKit ever stops doing that, the monitor needs an explicit case
/// for it rather than a silent regression.
@MainActor
@Suite(.tags(.model))
struct MenuKeyEquivalentRoutingTests {
    @MainActor
    private final class Recorder: NSObject {
        private(set) var fired = 0

        @objc func fire(_ sender: Any?) {
            self.fired += 1
        }
    }

    private static func keyDown(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
        // Not force-unwrapped: if AppKit ever refuses to build the event, the test should say so
        // rather than trap.
        return event ?? NSEvent()
    }

    /// The menu the monitor hands the event to, built the way the app's commands are.
    private static func menu(
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        target: Recorder
    ) -> NSMenu {
        let item = NSMenuItem(title: "Command", action: #selector(Recorder.fire(_:)), keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }

    /// The same menu, installed as the app's main menu, so the item's action is actually dispatched:
    /// a menu that is not the main menu matches the key but has no application to send the action
    /// through, which is what the first version of this test measured.
    private static func appMenu(keyEquivalent: String, modifiers: NSEvent.ModifierFlags, target: Recorder) -> NSMenu {
        let menu = Self.menu(keyEquivalent: keyEquivalent, modifiers: modifiers, target: target)
        NSApplication.shared.mainMenu = menu
        return menu
    }

    @Test("An unmodified Space reaches the menu and is performed")
    func unmodifiedSpaceIsPerformed() {
        let recorder = Recorder()
        let menu = Self.appMenu(keyEquivalent: " ", modifiers: [], target: recorder)
        defer { NSApplication.shared.mainMenu = nil }

        let handled = menu.performKeyEquivalent(with: Self.keyDown(" ", keyCode: 49))
        Self.pump()

        #expect(handled, "the menu declined an unmodified Space")
        #expect(recorder.fired == 1, "the menu claimed Space without performing it")
    }

    /// Menu actions are dispatched on the run loop rather than inside the key-equivalent call.
    private static func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    @Test("A command-modified arrow reaches the menu and is performed")
    func modifiedArrowIsPerformed() {
        let recorder = Recorder()
        // What `keyboardShortcut(.rightArrow, modifiers: .command)` builds: the function-key
        // scalar as the equivalent, and the event's characters carrying the same scalar.
        let arrow = String(NSEvent.SpecialKey.rightArrow.unicodeScalar)
        let menu = Self.appMenu(keyEquivalent: arrow, modifiers: .command, target: recorder)
        defer { NSApplication.shared.mainMenu = nil }

        let handled = menu.performKeyEquivalent(with: Self.keyDown(arrow, keyCode: 124, flags: .command))
        Self.pump()

        #expect(handled, "the menu declined ⌘→")
        #expect(recorder.fired == 1)
    }

    /// The mask is what decides, which is why passing the event on unchanged when the menu declines
    /// it is safe: a `Space` the app did not claim stays a `Space` for whatever has focus.
    @Test("A modified Space is not matched by an unmodified command")
    func maskIsHonoured() {
        let recorder = Recorder()
        let menu = Self.menu(keyEquivalent: " ", modifiers: .command, target: recorder)

        #expect(!menu.performKeyEquivalent(with: Self.keyDown(" ", keyCode: 49)))
        #expect(recorder.fired == 0)
    }
}
