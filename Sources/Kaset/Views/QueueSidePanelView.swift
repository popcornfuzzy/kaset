import SwiftUI

// MARK: - QueueSidePanelView

@available(macOS 26.0, *)
struct QueueSidePanelView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(FavoritesManager.self) private var favoritesManager

    /// Fixed panel width, or `nil` for a panel that fills whatever width it is given.
    ///
    /// The classic overlay uses the default. The embedded Now Playing sidebar passes `nil`: its column
    /// is resized by dragging a divider, and a width the app *states* here can only ever be the width of
    /// a previous layout pass — which is what left the queue's rows and their trailing controls a frame
    /// behind the column edge during a drag. Filling the width it is inside has no such copy to be stale.
    var width: CGFloat? = 400

    /// Whether the panel draws its own "Up Next" header. The Now Playing sidebar turns it off
    /// because that panel already has a header (with its own back button) above it.
    var showsHeader: Bool = true

    /// Whether the panel draws its own card: the material background and the rounded corners. The
    /// Now Playing sidebar turns it off, because there the queue's rows sit directly on the sidebar
    /// rather than on a panel floating over the window.
    var usesMaterialBackground: Bool = true

    var body: some View {
        // Use regular material: GlassEffectContainer breaks NSTableView drag-and-drop
        // (drop target gap and acceptDrop never fire when the table is inside glass).
        VStack(spacing: 0) {
            if self.showsHeader {
                QueueSidePanelHeader()

                Divider()
                    .opacity(0.3)
            }

            // Automix tuning row, when the server offers tunings for the playing queue
            if !self.playerService.queueTunerChips.isEmpty {
                QueueTunerChipsView(
                    chips: self.playerService.queueTunerChips,
                    isLoading: self.playerService.isApplyingQueueTuner,
                    onSelect: { chip in
                        Task {
                            await self.playerService.applyQueueTunerChip(chip)
                        }
                    }
                )

                Divider()
                    .opacity(0.3)
            }

            if self.playerService.queue.isEmpty {
                self.emptyQueueView
            } else {
                QueueListControllerRepresentable(
                    panelWidth: self.width,
                    queue: self.playerService.queue,
                    currentIndex: self.playerService.queueHighlightIndex ?? -1,
                    isPlaying: self.playerService.isPlaying,
                    favoritesManager: self.favoritesManager,
                    onSelect: { index in
                        Task {
                            await self.playerService.playFromQueue(at: index)
                        }
                    },
                    onReorder: { source, destination in
                        self.playerService.reorderQueue(from: IndexSet(integer: source), to: destination)
                    },
                    onRemove: { videoId in
                        Task {
                            self.playerService.removeFromQueue(videoIds: Set([videoId]))
                        }
                    },
                    onStartRadio: { song in
                        Task {
                            await self.playerService.playWithRadio(song: song)
                        }
                    }
                )
                .accessibilityIdentifier(AccessibilityID.Queue.scrollView)
            }

            Divider()
                .opacity(0.3)

            QueueFooterActions()
        }
        // `nil` here is a real value: the modifier leaves the panel free to fill its container.
        .frame(width: self.width)
        .modifier(QueuePanelChrome(usesMaterial: self.usesMaterialBackground))
        .accessibilityIdentifier(AccessibilityID.Queue.container)
    }

    private var emptyQueueView: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("No Queue")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Play songs from a playlist or album to build your queue.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityID.Queue.emptyState)
    }
}

// MARK: - QueueListControllerRepresentable

@available(macOS 26.0, *)
struct QueueListControllerRepresentable: NSViewControllerRepresentable {
    /// Fixed width of the panel the table is inside, or `nil` when the panel fills its container.
    ///
    /// The classic overlay states its width; the embedded Now Playing sidebar passes `nil` and the column
    /// follows the scroll view's *actual* width in `viewDidLayout`, so a divider drag needs no round trip
    /// through SwiftUI state to be reflected in the rows.
    var panelWidth: CGFloat?
    let queue: [Song]
    let currentIndex: Int
    let isPlaying: Bool
    let favoritesManager: FavoritesManager
    let onSelect: (Int) -> Void
    let onReorder: (Int, Int) -> Void
    let onRemove: (String) -> Void
    let onStartRadio: (Song) -> Void

    func makeNSViewController(context: Context) -> QueueListViewController {
        let viewController = QueueListViewController()
        viewController.coordinator = context.coordinator
        context.coordinator.viewController = viewController
        return viewController
    }

    func updateNSViewController(_ viewController: QueueListViewController, context: Context) {
        viewController.applyPanelWidth(self.panelWidth)
        context.coordinator.queue = self.queue
        context.coordinator.currentIndex = self.currentIndex
        context.coordinator.isPlaying = self.isPlaying
        context.coordinator.favoritesManager = self.favoritesManager

        if !context.coordinator.isDragging {
            viewController.tableView?.reloadData()
        }

        // Update current track highlighting and waveform animation
        if let tableView = viewController.tableView {
            for row in 0 ..< self.queue.count {
                if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueTableCellView {
                    cellView.updateAppearance(
                        isCurrentTrack: row == self.currentIndex,
                        isPlaying: self.isPlaying,
                        index: row
                    )
                }
            }

            tableView.syncRevealedDeleteUI()

            context.coordinator.syncAutoScroll(in: tableView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            queue: self.queue,
            currentIndex: self.currentIndex,
            isPlaying: self.isPlaying,
            favoritesManager: self.favoritesManager,
            onSelect: self.onSelect,
            onReorder: self.onReorder,
            onRemove: self.onRemove,
            onStartRadio: self.onStartRadio
        )
    }

    // MARK: - View Controller

    class QueueListViewController: NSViewController {
        var tableView: DraggableTableView?
        weak var coordinator: Coordinator?

        override func loadView() {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.backgroundColor = .clear
            scrollView.drawsBackground = false
            scrollView.hasHorizontalScroller = false // Disable horizontal scrolling
            scrollView.horizontalScrollElasticity = .none // No horizontal bounce

            let tableView = DraggableTableView()
            tableView.headerView = nil
            tableView.selectionHighlightStyle = .none
            tableView.backgroundColor = .clear
            tableView.allowsEmptySelection = true
            tableView.allowsColumnResizing = false
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            tableView.intercellSpacing = NSSize(width: 0, height: 0)
            tableView.rowHeight = 56

            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("QueueColumn"))
            column.title = ""
            column.minWidth = 350
            column.maxWidth = 400
            column.width = 350 // Matches container width minus scroll bar space
            tableView.addTableColumn(column)

            let dragType = NSPasteboard.PasteboardType("com.kaset.queueitem")
            tableView.registerForDraggedTypes([dragType, .string])
            tableView.verticalMotionCanBeginDrag = true
            tableView.draggingDestinationFeedbackStyle = .gap // Show gap where item will be dropped

            scrollView.documentView = tableView
            self.tableView = tableView
            self.view = scrollView
        }

        /// Fixed width of the panel this table is inside, remembered so it can be applied the moment the
        /// table exists — `updateNSViewController` can run before the view is loaded.
        var panelWidth: CGFloat?

        /// States the panel's width. `nil` means "follow the panel you are inside".
        func applyPanelWidth(_ width: CGFloat?) {
            self.panelWidth = width
            self.sizeColumnToPanel()
        }

        /// Sizes the queue column to the panel it is inside. The rows keep a small gutter for the
        /// scroll indicator, which is what the classic 400pt panel's 350pt column already did.
        ///
        /// The panel's *own* width is read from the view rather than only from the stated number: a
        /// divider drag changes the view's width immediately, while the stated number arrives with the
        /// next SwiftUI update, and reading the view is what makes the rows track the column edge.
        private func sizeColumnToPanel() {
            guard let column = self.tableView?.tableColumns.first else { return }
            let availableWidth = self.view.bounds.width > 0 ? self.view.bounds.width : nil
            let panelWidth = availableWidth ?? self.panelWidth
            guard let panelWidth, panelWidth > 0 else { return }
            let target = max(220, panelWidth - 50)
            guard column.width != target else { return }
            // Keep `minWidth <= maxWidth` at every step. Raising the minimum past the maximum is an
            // invalid table-column configuration, and the embedded sidebar can be dragged wider than
            // the classic panel's fixed 400pt maximum. No `reloadData` here: a column-width change
            // relayouts the visible rows on its own, and reloading mid SwiftUI layout is what could
            // re-enter the layout pass.
            if column.maxWidth < target {
                column.maxWidth = target
            }
            column.minWidth = target
            column.width = target
            column.maxWidth = target
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            if let tableView {
                tableView.delegate = self.coordinator
                tableView.dataSource = self.coordinator
                tableView.coordinator = self.coordinator
                tableView.onUserScroll = { [weak coordinator = self.coordinator] in
                    coordinator?.registerUserScrollInteraction()
                }
                self.sizeColumnToPanel()
            }
        }

        /// The column follows the view's width on every layout pass. This is what makes the queue keep
        /// up with a divider drag: AppKit lays the scroll view out at its new width and this reads that
        /// width in the same pass, where a width handed down from SwiftUI state would be one pass old.
        override func viewDidLayout() {
            super.viewDidLayout()
            self.sizeColumnToPanel()
        }
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var queue: [Song]
        var currentIndex: Int
        var isPlaying: Bool
        var favoritesManager: FavoritesManager
        let onSelect: (Int) -> Void
        let onReorder: (Int, Int) -> Void
        let onRemove: (String) -> Void
        let onStartRadio: (Song) -> Void
        weak var viewController: QueueListViewController?
        var isDragging = false
        private var hasPerformedInitialScroll = false
        private var previousCurrentIndex: Int?
        private var isUserScrolling = false
        private var resumeAutoScrollTimer: Timer?
        private let dragType = NSPasteboard.PasteboardType("com.kaset.queueitem")

        init(queue: [Song], currentIndex: Int, isPlaying: Bool, favoritesManager: FavoritesManager,
             onSelect: @escaping (Int) -> Void, onReorder: @escaping (Int, Int) -> Void, onRemove: @escaping (String) -> Void, onStartRadio: @escaping (Song) -> Void)
        {
            self.queue = queue
            self.currentIndex = currentIndex
            self.isPlaying = isPlaying
            self.favoritesManager = favoritesManager
            self.onSelect = onSelect
            self.onReorder = onReorder
            self.onRemove = onRemove
            self.onStartRadio = onStartRadio
            super.init()
        }

        func registerUserScrollInteraction() {
            self.isUserScrolling = true
            self.resumeAutoScrollTimer?.invalidate()

            self.resumeAutoScrollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isUserScrolling = false
                    if let tableView = self.viewController?.tableView {
                        self.scrollToCurrentSong(in: tableView, animated: true)
                    }
                }
            }
        }

        func syncAutoScroll(in tableView: NSTableView) {
            guard let tableView = tableView as? DraggableTableView else { return }

            let currentChanged = self.previousCurrentIndex != self.currentIndex
            self.previousCurrentIndex = self.currentIndex

            if !self.hasPerformedInitialScroll {
                self.hasPerformedInitialScroll = true
                self.scrollToCurrentSong(in: tableView, animated: false)
                return
            }

            guard currentChanged, !self.isUserScrolling else { return }
            self.scrollToCurrentSong(in: tableView, animated: true)
        }

        @MainActor
        private func scrollToCurrentSong(in tableView: DraggableTableView, animated: Bool) {
            guard self.queue.indices.contains(self.currentIndex) else { return }
            guard let scrollView = tableView.enclosingScrollView else {
                tableView.scrollRowToVisible(self.currentIndex)
                return
            }

            let rowRect = tableView.rect(ofRow: self.currentIndex)
            guard rowRect != .zero else {
                tableView.scrollRowToVisible(self.currentIndex)
                return
            }

            let clipView = scrollView.contentView
            let maxOffsetY = max(0, tableView.bounds.height - clipView.bounds.height)
            let centeredOffsetY = min(max(0, rowRect.midY - clipView.bounds.height / 2), maxOffsetY)
            let targetPoint = NSPoint(x: clipView.bounds.origin.x, y: centeredOffsetY)

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.35
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    clipView.animator().setBoundsOrigin(targetPoint)
                }
            } else {
                clipView.setBoundsOrigin(targetPoint)
            }

            scrollView.reflectScrolledClipView(clipView)
        }

        /// Removes the row with slide-out animation, then calls onRemove.
        /// - Parameter slideDirection: -1 = slide left, +1 = slide right (matches swipe direction).
        func removeRowWithAnimation(row: Int, song: Song, slideDirection: CGFloat) {
            guard let tableView = viewController?.tableView else {
                self.onRemove(song.videoId)
                return
            }
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else {
                self.onRemove(song.videoId)
                return
            }
            let videoId = song.videoId
            let offsetX = slideDirection * rowView.bounds.width
            let originalFrame = rowView.frame
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                rowView.animator().alphaValue = 0
                rowView.animator().frame.origin.x += offsetX
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    // Reset row view so it can be reused without a stuck frame/alpha (fixes misaligned rows).
                    rowView.alphaValue = 1
                    rowView.frame = originalFrame
                    self?.onRemove(videoId)
                }
            }
        }

        func numberOfRows(in _: NSTableView) -> Int {
            self.queue.count
        }

        func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            let cellView = QueueTableCellView()
            let song = self.queue[row]
            cellView.configure(
                song: song,
                index: row,
                isCurrentTrack: row == self.currentIndex,
                isPlaying: self.isPlaying,
                actions: QueueCellActions(
                    onPlay: { [weak self] in self?.onSelect(row) },
                    onRevealRemove: {
                        guard let draggableTableView = tableView as? DraggableTableView
                        else { return }
                        draggableTableView.revealDeleteActionForRow(row)
                    }
                )
            )
            if let draggableTableView = tableView as? DraggableTableView {
                cellView.setInlineRemoveButtonHidden(draggableTableView.isDeleteActionRevealed(for: row))
            }
            // The row that is playing cannot be reordered, and a row that looks like the others but
            // refuses to land anywhere reads as broken: hovering it says why.
            cellView.toolTip = row == self.currentIndex
                ? String(localized: "Playing — this row stays where it is")
                : nil
            return cellView
        }

        func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
            56
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            let selectedRow = tableView.selectedRow
            if selectedRow >= 0 {
                tableView.deselectAll(nil)
            }
        }

        /// Drag Source
        ///
        /// Every row offers a drag, the playing one included. A row silenced here is a row that
        /// **disappears**: the table hides the pressed row as it prepares the drag and the drag session
        /// is what shows it again, so a `nil` writer — a drag that never begins — leaves the row hidden
        /// for good (see `DraggableTableView.restoreRowsAfterFailedDrag`).
        ///
        /// The playing row is locked at the *drop*, not at the drag: `dropIsAllowed` refuses every
        /// position for it, so it can be lifted but has nowhere to land, and the model refuses the same
        /// moves (`PlayerService.reorderMovesPlayingRow`).
        func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let item = NSPasteboardItem()
            item.setString(String(row), forType: self.dragType)
            self.isDragging = true
            return item
        }

        func tableView(_: NSTableView, draggingSession _: NSDraggingSession, willBeginAt _: NSPoint, forRowIndexes _: IndexSet) {
            // Dragging session began
        }

        func tableView(_: NSTableView, draggingSession _: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
            self.isDragging = false
        }

        /// Drop Destination
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            if let draggableTableView = tableView as? DraggableTableView {
                draggableTableView.handleDragAutoScroll(draggingLocationInWindow: info.draggingLocation)
            }
            guard dropOperation == .above else { return [] }
            guard let str = info.draggingPasteboard.string(forType: dragType),
                  let srcRow = Int(str) else { return [] }
            // Refused here as well as in `acceptDrop`, so a refused drop shows no gap either — the
            // reader never sees the queue make room for something that is not going to happen.
            guard self.dropIsAllowed(from: srcRow, to: row) else { return [] }
            return .move
        }

        func tableView(_: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation _: NSTableView.DropOperation) -> Bool {
            guard let str = info.draggingPasteboard.string(forType: dragType),
                  let srcRow = Int(str) else { return false }
            guard self.dropIsAllowed(from: srcRow, to: row) else { return false }
            self.onReorder(srcRow, row)
            self.isDragging = false
            return true
        }

        /// Whether a dragged row may be dropped where the pointer is.
        ///
        /// The row that is playing is locked: it can be neither the row dragged — every position under
        /// it is refused, so a lifted playing row has nowhere to land — nor a row that moves as a
        /// result. The second half is the rule the model states, so the table's feedback and the model
        /// can never disagree (see `PlayerService.reorderMovesPlayingRow`).
        /// Internal rather than private so the rule can be read off the coordinator itself, which is
        /// where the table's feedback comes from (see `QueueRowDragStrandTests`).
        func dropIsAllowed(from source: Int, to destination: Int) -> Bool {
            guard source != self.currentIndex, destination != source else { return false }
            return !PlayerService.reorderMovesPlayingRow(
                from: source, to: destination, currentIndex: self.currentIndex
            )
        }

        // MARK: - Context Menu

        /// The menu for the row under a right click, built by the table (`DraggableTableView.menu(for:)`).
        ///
        /// A plain method, not an `NSTableViewDelegate` hook: **there is no `menuForRow` in AppKit**, so
        /// the delegate method this used to be was never called and a right click on a queue row opened
        /// nothing at all — which is why the queue's context menu had to be brought back to the Now
        /// Playing sidebar by hand.
        func menu(forRow row: Int) -> NSMenu? {
            guard row >= 0, let song = queue[safe: row] else { return nil }
            let menu = NSMenu()
            let manager = self.favoritesManager
            let isPinned = MainActor.assumeIsolated { manager.isPinned(song: song) }

            let favoritesItem = NSMenuItem(
                title: isPinned ? "Remove from Favorites" : "Add to Favorites",
                action: #selector(Coordinator.contextMenuFavorites(_:)),
                keyEquivalent: ""
            )
            favoritesItem.target = self
            favoritesItem.representedObject = song
            favoritesItem.image = NSImage(systemSymbolName: isPinned ? "heart.slash" : "heart", accessibilityDescription: nil)
            menu.addItem(favoritesItem)

            menu.addItem(NSMenuItem.separator())

            let startRadioItem = NSMenuItem(title: "Start Radio", action: #selector(Coordinator.contextMenuStartRadio(_:)), keyEquivalent: "")
            startRadioItem.target = self
            startRadioItem.representedObject = song
            startRadioItem.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)
            menu.addItem(startRadioItem)

            menu.addItem(NSMenuItem.separator())

            if song.shareURL != nil {
                let shareItem = NSMenuItem(title: "Share", action: #selector(Coordinator.contextMenuShare(_:)), keyEquivalent: "")
                shareItem.target = self
                shareItem.representedObject = song
                shareItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
                menu.addItem(shareItem)
                menu.addItem(NSMenuItem.separator())
            }

            if row != self.currentIndex {
                let removeItem = NSMenuItem(title: "Remove from Queue", action: #selector(Coordinator.contextMenuRemove(_:)), keyEquivalent: "")
                removeItem.target = self
                removeItem.representedObject = song
                removeItem.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)
                menu.addItem(removeItem)
            }

            return menu
        }

        @objc private func contextMenuFavorites(_ sender: NSMenuItem) {
            guard let song = sender.representedObject as? Song else { return }
            let manager = self.favoritesManager
            MainActor.assumeIsolated { manager.toggle(song: song) }
        }

        @objc private func contextMenuStartRadio(_ sender: NSMenuItem) {
            guard let song = sender.representedObject as? Song else { return }
            self.onStartRadio(song)
        }

        @objc private func contextMenuShare(_ sender: NSMenuItem) {
            guard let song = sender.representedObject as? Song, let url = song.shareURL else { return }
            MainActor.assumeIsolated {
                ShareContextMenu.showSharePicker(for: url)
            }
        }

        @objc private func contextMenuRemove(_ sender: NSMenuItem) {
            guard let song = sender.representedObject as? Song else { return }
            self.onRemove(song.videoId)
        }
    }
}

// MARK: - DraggableTableView

@available(macOS 26.0, *)
class DraggableTableView: NSTableView {
    weak var coordinator: QueueListControllerRepresentable.Coordinator?
    var onUserScroll: (() -> Void)?

    /// Accumulated scroll deltas during the current gesture (used to detect swipe-to-remove).
    private var horizontalSwipeAccumulator: CGFloat = 0
    private var verticalSwipeAccumulator: CGFloat = 0
    /// Row index under the cursor when the gesture *started* (.began), so we remove that row even if content scrolls by .ended.
    private var swipeRemoveTargetRow: Int = -1
    /// When non-nil, we're showing real-time slide feedback; value is the row view's initial origin.x to restore on cancel.
    private var swipeTrackedInitialOriginX: CGFloat?
    /// Cooldown after a remove so we don't trigger again from leftover events.
    private var swipeRemoveCooldownUntil: CFAbsoluteTime = 0
    /// Minimum horizontal delta to "commit" and start moving the row (avoids vertical scroll moving a row).
    private static let swipeCommitThreshold: CGFloat = 10
    /// Horizontal swipe distance (pt) beyond which release counts as delete. Increase for a more deliberate confirm, decrease for quicker remove.
    private static let swipeRemoveDeltaThreshold: CGFloat = 100
    private static let swipeRemoveCooldown: CFAbsoluteTime = 0.5
    /// Max horizontal drag (multiple of row width) for real-time feedback.
    private static let swipeMaxDragFactor: CGFloat = 1.2
    /// Width of the revealed delete action area.
    private static let swipeRevealWidth: CGFloat = 92
    /// Edge zone used for auto-scroll while dragging rows.
    private static let dragAutoScrollEdgeZone: CGFloat = 120
    /// Minimum and maximum drag autoscroll speed in points per second.
    private static let dragAutoScrollMinSpeed: CGFloat = 14
    private static let dragAutoScrollMaxSpeed: CGFloat = 72

    /// Currently revealed delete action state.
    private var revealedDeleteRow: Int = -1
    private var revealedDeleteDirection: CGFloat = 0
    private var revealedDeleteInitialOriginX: CGFloat = 0
    private weak var revealedDeleteBackgroundView: NSView?
    /// Set while the remove animation is playing. Its own row is hidden and slides out, so the repair in
    /// `restoreRowsAfterFailedDrag` must leave it alone (see `handleRevealedDeleteButtonClick`).
    private var isRemovingRow = false
    private var lastDragAutoScrollTimestamp: CFAbsoluteTime?

    /// Disable built-in autoscroll during drag (it is too aggressive and causes jump-to-end behavior).
    override func autoscroll(with _: NSEvent) -> Bool {
        false
    }

    /// The right-click menu for the row under the pointer.
    ///
    /// This is the only place AppKit asks a table for a row's menu: `NSTableViewDelegate` has no
    /// `menuForRow` hook, so the menu the rows carry has to be resolved here from the event's own
    /// location. Returning `nil` for a click that lands below the last row leaves the table's own
    /// (empty) menu in place rather than opening an unrelated one.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = self.convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return nil }
        return self.coordinator?.menu(forRow: row)
    }

    /// Smooth drag autoscroll based on the live drag location from `validateDrop`.
    func handleDragAutoScroll(draggingLocationInWindow: NSPoint) {
        guard let scrollView = self.enclosingScrollView else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let deltaTime: CFTimeInterval
        if let last = self.lastDragAutoScrollTimestamp {
            // Clamp dt so variable callback frequency cannot cause sudden jump speeds.
            deltaTime = min(max(now - last, 1.0 / 240.0), 1.0 / 30.0)
        } else {
            deltaTime = 1.0 / 120.0
        }
        self.lastDragAutoScrollTimestamp = now

        let local = self.convert(draggingLocationInWindow, from: nil)
        let visibleRect = self.visibleRect
        let edgeZone = Self.dragAutoScrollEdgeZone
        let topThreshold = visibleRect.maxY - edgeZone
        let bottomThreshold = visibleRect.minY + edgeZone

        let direction: CGFloat
        let distanceToEdge: CGFloat

        if local.y >= topThreshold {
            direction = 1
            distanceToEdge = max(0, visibleRect.maxY - local.y)
        } else if local.y <= bottomThreshold {
            direction = -1
            distanceToEdge = max(0, local.y - visibleRect.minY)
        } else {
            self.lastDragAutoScrollTimestamp = nil
            return
        }

        let clamped = min(max(distanceToEdge, 0), edgeZone)
        let proximity = 1 - (clamped / edgeZone) // 0 = far from edge, 1 = at edge
        let speed = Self.dragAutoScrollMinSpeed + (Self.dragAutoScrollMaxSpeed - Self.dragAutoScrollMinSpeed) * proximity
        let step = speed * CGFloat(deltaTime)

        let clipView = scrollView.contentView
        let maxOriginY = max(0, self.bounds.height - clipView.bounds.height)
        let targetY = min(max(0, clipView.bounds.origin.y + direction * step), maxOriginY)

        guard abs(targetY - clipView.bounds.origin.y) > 0.01 else { return }

        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
    }

    func revealDeleteActionForRow(_ row: Int) {
        guard let coord = self.coordinator,
              row >= 0,
              row != coord.currentIndex,
              coord.queue[safe: row] != nil
        else { return }
        if self.revealedDeleteRow == row { return }
        if let song = coord.queue[safe: row] {
            self.revealDeleteAction(for: row, direction: -1, initialX: 0, song: song)
        }
    }

    func isDeleteActionRevealed(for row: Int) -> Bool {
        self.revealedDeleteRow == row
    }

    func syncRevealedDeleteUI() {
        for row in 0 ..< self.numberOfRows {
            if let cellView = self.view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueTableCellView {
                cellView.setInlineRemoveButtonHidden(self.isDeleteActionRevealed(for: row))
            }
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        self.setupTable()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setupTable()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupTable()
    }

    private func setupTable() {
        // Enable gap feedback style for drag-and-drop
        self.draggingDestinationFeedbackStyle = .gap
    }

    /// Two-finger horizontal trackpad swipe: row follows finger in real time; release past threshold to remove, or return to cancel.
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        if event.phase == .began, self.revealedDeleteRow >= 0 {
            self.clearRevealedDeleteAction(animated: true)
        }

        if abs(dx) > 0 || abs(dy) > 0 {
            self.onUserScroll?()
        }

        switch event.phase {
        case .began:
            self.handleSwipeBegan(dx: dx, dy: dy, event: event)
        case .changed:
            self.handleSwipeChanged(dx: dx, dy: dy)
        case .ended, .cancelled:
            if self.handleSwipeEnded(event: event) { return }
        default:
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                self.horizontalSwipeAccumulator = 0
                self.verticalSwipeAccumulator = 0
                self.swipeRemoveTargetRow = -1
                self.swipeTrackedInitialOriginX = nil
            }
        }

        super.scrollWheel(with: event)
    }

    /// Handles the `.began` phase of a trackpad swipe gesture.
    private func handleSwipeBegan(dx: CGFloat, dy: CGFloat, event: NSEvent) {
        self.horizontalSwipeAccumulator = dx
        self.verticalSwipeAccumulator = dy
        self.swipeRemoveTargetRow = -1
        self.swipeTrackedInitialOriginX = nil
        if self.coordinator != nil {
            let point = event.locationInWindow
            let localPoint = self.convert(point, from: nil)
            let rowAtStart = self.row(at: localPoint)
            self.swipeRemoveTargetRow = rowAtStart
        }
    }

    /// Handles the `.changed` phase of a trackpad swipe gesture, sliding the row in real time.
    private func handleSwipeChanged(dx: CGFloat, dy: CGFloat) {
        guard self.revealedDeleteRow < 0 else { return }

        self.horizontalSwipeAccumulator += dx
        self.verticalSwipeAccumulator += dy
        // Real-time row slide: once horizontal movement passes commit threshold, move the row with the finger.
        if let coord = coordinator,
           swipeRemoveTargetRow >= 0,
           swipeRemoveTargetRow != coord.currentIndex,
           coord.queue[safe: swipeRemoveTargetRow] != nil,
           abs(horizontalSwipeAccumulator) > Self.swipeCommitThreshold,
           abs(horizontalSwipeAccumulator) > abs(verticalSwipeAccumulator)
        {
            guard let rowView = self.rowView(atRow: swipeRemoveTargetRow, makeIfNecessary: false) else {
                return
            }
            let rowSlotFrame = self.rect(ofRow: swipeRemoveTargetRow)
            if self.swipeTrackedInitialOriginX == nil {
                self.swipeTrackedInitialOriginX = rowSlotFrame.origin.x
            }
            let initialX = self.swipeTrackedInitialOriginX!
            let maxDrag = rowView.bounds.width * Self.swipeMaxDragFactor
            // Left-swipe only: never move row to the right.
            let clamped = max(-maxDrag, min(0, self.horizontalSwipeAccumulator))
            var f = rowView.frame
            f.origin.x = initialX + clamped
            rowView.frame = f
        }
    }

    /// Handles the `.ended` / `.cancelled` phase of a trackpad swipe gesture. Returns `true` if the event was fully consumed.
    private func handleSwipeEnded(event: NSEvent) -> Bool {
        let accH = self.horizontalSwipeAccumulator
        let accV = self.verticalSwipeAccumulator
        let rowAtEnd = self.row(at: self.convert(event.locationInWindow, from: nil))
        self.horizontalSwipeAccumulator = 0
        self.verticalSwipeAccumulator = 0

        if let initialX = swipeTrackedInitialOriginX {
            self.swipeTrackedInitialOriginX = nil
            guard let coord = coordinator,
                  swipeRemoveTargetRow >= 0,
                  let song = coord.queue[safe: swipeRemoveTargetRow]
            else {
                self.swipeRemoveTargetRow = -1
                return false
            }
            let row = self.swipeRemoveTargetRow
            self.swipeRemoveTargetRow = -1
            guard let rowView = self.rowView(atRow: row, makeIfNecessary: false) else {
                return false
            }

            let passed = CFAbsoluteTimeGetCurrent() >= self.swipeRemoveCooldownUntil
                && abs(accH) >= Self.swipeRemoveDeltaThreshold
                && abs(accH) > abs(accV)
                && accH < 0
                && row != coord.currentIndex

            if passed {
                self.revealDeleteAction(for: row, direction: -1, initialX: initialX, song: song)
                return true
            } else {
                // Cancel: animate row back to initial position.
                let rowSlotFrame = self.rect(ofRow: row)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    var f = rowView.frame
                    f.origin.x = rowSlotFrame.origin.x
                    rowView.animator().frame = f
                } completionHandler: {}
                return true
            }
        }

        if CFAbsoluteTimeGetCurrent() < self.swipeRemoveCooldownUntil { return false }
        guard abs(accH) >= Self.swipeRemoveDeltaThreshold,
              abs(accH) > abs(accV),
              accH < 0
        else { return false }
        guard let coord = coordinator else { return false }
        let row = self.swipeRemoveTargetRow >= 0 ? self.swipeRemoveTargetRow : rowAtEnd
        self.swipeRemoveTargetRow = -1
        if row < 0 { return false }
        if row == coord.currentIndex { return false }
        guard let song = coord.queue[safe: row] else { return false }
          self.revealDeleteAction(for: row, direction: -1, initialX: 0, song: song)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if self.revealedDeleteRow >= 0 {
            self.clearRevealedDeleteAction(animated: true)
            return
        }
        super.mouseDown(with: event)
    }

    /// Puts back any row a press left hidden or shifted.
    ///
    /// A press hides the row under the pointer while the table prepares a drag — the drag session shows
    /// it again when it ends. A press that never became a drag (no drag source, or a drag that was
    /// abandoned before it began) therefore strands that row **invisible until relaunch**, since a
    /// recycled row view keeps the hidden flag. The release is the one moment that can tell the press
    /// apart from the drag: a live drag has the mouse, and this event is for the press that stayed a
    /// press. A swipe's revealed action and the remove animation are the two states that hide or move a
    /// row on purpose, and neither is touched.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        self.restoreRowsAfterFailedDrag()
    }

    /// Shows the rows a press left hidden, and slides back the ones it left out of their slot.
    private func restoreRowsAfterFailedDrag() {
        guard self.revealedDeleteRow < 0, !self.isRemovingRow else { return }
        for row in 0 ..< self.numberOfRows {
            guard let rowView = self.rowView(atRow: row, makeIfNecessary: false) else { continue }
            if rowView.isHidden { rowView.isHidden = false }
            if rowView.alphaValue < 1 { rowView.alphaValue = 1 }
            let slotX = self.rect(ofRow: row).origin.x
            if rowView.frame.origin.x != slotX {
                var frame = rowView.frame
                frame.origin.x = slotX
                rowView.frame = frame
            }
        }
    }

    private func revealDeleteAction(for row: Int, direction: CGFloat, initialX _: CGFloat, song _: Song) {
        guard let coord = self.coordinator,
              let rowView = self.rowView(atRow: row, makeIfNecessary: false),
              coord.queue[safe: row] != nil
        else { return }

        if self.revealedDeleteRow >= 0 {
            self.clearRevealedDeleteAction(animated: false)
        }

        let deleteButton = NSButton(title: "Remove", target: self, action: #selector(self.handleRevealedDeleteButtonClick(_:)))
        deleteButton.bezelStyle = .regularSquare
        deleteButton.isBordered = false
        deleteButton.setButtonType(.momentaryPushIn)
        deleteButton.title = ""
        deleteButton.tag = row
        deleteButton.wantsLayer = true
        deleteButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        deleteButton.layer?.cornerRadius = 8
        deleteButton.layer?.masksToBounds = true
        deleteButton.alphaValue = 0

        let buttonContent = NSStackView()
        buttonContent.orientation = .horizontal
        buttonContent.alignment = .centerY
        buttonContent.spacing = 6
        buttonContent.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove from Queue")
        iconView.contentTintColor = .white
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 12).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let label = NSTextField(labelWithString: "Remove")
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white

        buttonContent.addArrangedSubview(iconView)
        buttonContent.addArrangedSubview(label)
        deleteButton.addSubview(buttonContent)
        NSLayoutConstraint.activate([
            buttonContent.centerXAnchor.constraint(equalTo: deleteButton.centerXAnchor),
            buttonContent.centerYAnchor.constraint(equalTo: deleteButton.centerYAnchor),
        ])

        let revealWidth = Self.swipeRevealWidth
        let rowSlotFrame = self.rect(ofRow: row)
        let actionX = direction < 0
            ? rowSlotFrame.maxX - revealWidth
            : rowSlotFrame.minX
        deleteButton.frame = NSRect(x: actionX, y: rowSlotFrame.minY + 4, width: revealWidth, height: max(0, rowSlotFrame.height - 8))

        self.addSubview(deleteButton, positioned: .below, relativeTo: rowView)

        self.revealedDeleteRow = row
        self.revealedDeleteDirection = direction
        self.revealedDeleteInitialOriginX = rowSlotFrame.origin.x
        self.revealedDeleteBackgroundView = deleteButton
        self.syncRevealedDeleteUI()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            var frame = rowView.frame
            frame.origin.x = rowSlotFrame.origin.x + (direction < 0 ? -revealWidth : revealWidth)
            rowView.animator().frame = frame
            deleteButton.animator().alphaValue = 1
        }
    }

    @objc private func handleRevealedDeleteButtonClick(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0,
              let coord = self.coordinator,
              row != coord.currentIndex,
              let song = coord.queue[safe: row],
              let rowView = self.rowView(atRow: row, makeIfNecessary: false)
        else {
            self.clearRevealedDeleteAction(animated: true)
            return
        }

        guard let swipeSnapshot = self.makeSwipeSnapshot(for: rowView) else {
            self.clearRevealedDeleteAction(animated: true)
            return
        }

        let direction = self.revealedDeleteDirection == 0 ? -1 : self.revealedDeleteDirection
        let rowSlotFrame = self.rect(ofRow: row)
        let initialX = rowSlotFrame.origin.x
        let targetX = initialX + direction * (rowView.bounds.width + 56)
        let actionView = self.revealedDeleteBackgroundView

        var rowsToShift: [(NSView, CGFloat)] = []
        if row + 1 < self.numberOfRows,
           let nextRowView = self.rowView(atRow: row + 1, makeIfNecessary: false)
        {
            let verticalShift = rowView.frame.minY - nextRowView.frame.minY
            for belowRow in (row + 1) ..< self.numberOfRows {
                if let belowRowView = self.rowView(atRow: belowRow, makeIfNecessary: false) {
                    rowsToShift.append((belowRowView, verticalShift))
                }
            }
        }

        // Hide the real row during animation so text never overlaps with adjacent rows.
        rowView.isHidden = true
        self.isRemovingRow = true
        self.addSubview(swipeSnapshot, positioned: .above, relativeTo: rowView)

        self.swipeRemoveCooldownUntil = CFAbsoluteTimeGetCurrent() + Self.swipeRemoveCooldown

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            var frame = swipeSnapshot.frame
            frame.origin.x = targetX
            swipeSnapshot.animator().frame = frame
            actionView?.animator().alphaValue = 0
            for (belowRowView, verticalShift) in rowsToShift {
                var belowFrame = belowRowView.frame
                belowFrame.origin.y += verticalShift
                belowRowView.animator().frame = belowFrame
            }
        } completionHandler: {
            Task { @MainActor in
                var frame = rowView.frame
                frame.origin.x = initialX
                rowView.frame = frame
                rowView.isHidden = false
                self.isRemovingRow = false
                swipeSnapshot.removeFromSuperview()
                actionView?.removeFromSuperview()
                self.revealedDeleteBackgroundView = nil
                self.revealedDeleteRow = -1
                self.revealedDeleteDirection = 0
                self.revealedDeleteInitialOriginX = 0
                self.syncRevealedDeleteUI()
                self.coordinator?.onRemove(song.videoId)
            }
        }
    }

    private func makeSwipeSnapshot(for rowView: NSView) -> NSImageView? {
        let bounds = rowView.bounds
        guard !bounds.isEmpty,
              let rep = rowView.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }

        rowView.cacheDisplay(in: bounds, to: rep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)

        let imageView = NSImageView(frame: rowView.frame)
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        return imageView
    }

    private func clearRevealedDeleteAction(animated: Bool) {
        guard self.revealedDeleteRow >= 0,
              let rowView = self.rowView(atRow: self.revealedDeleteRow, makeIfNecessary: false)
        else {
            self.revealedDeleteBackgroundView?.removeFromSuperview()
            self.revealedDeleteBackgroundView = nil
            self.revealedDeleteRow = -1
            self.revealedDeleteDirection = 0
            self.revealedDeleteInitialOriginX = 0
            return
        }

        let rowSlotFrame = self.rect(ofRow: self.revealedDeleteRow)
        let initialX = rowSlotFrame.origin.x
        let actionView = self.revealedDeleteBackgroundView

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                var frame = rowView.frame
                frame.origin.x = initialX
                rowView.animator().frame = frame
                actionView?.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    self.resetRevealedDeleteState(actionView: actionView)
                }
            }
        } else {
            var frame = rowView.frame
            frame.origin.x = initialX
            rowView.frame = frame
            self.resetRevealedDeleteState(actionView: actionView)
        }
    }

    private func resetRevealedDeleteState(actionView: NSView?) {
        actionView?.removeFromSuperview()
        self.revealedDeleteBackgroundView = nil
        self.revealedDeleteRow = -1
        self.revealedDeleteDirection = 0
        self.revealedDeleteInitialOriginX = 0
        self.syncRevealedDeleteUI()
    }
}

// MARK: - QueuePanelChrome

/// The panel's chrome: the material card the classic overlay is, or nothing at all when the queue is
/// embedded in the Now Playing sidebar.
@available(macOS 26.0, *)
private struct QueuePanelChrome: ViewModifier {
    let usesMaterial: Bool

    func body(content: Content) -> some View {
        if self.usesMaterial {
            content
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        } else {
            content
        }
    }
}

// MARK: - QueueSidePanelHeader

@available(macOS 26.0, *)
private struct QueueSidePanelHeader: View {
    @Environment(PlayerService.self) private var playerService

    var body: some View {
        HStack {
            Text("Up Next")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Text("\(self.playerService.queue.count) songs", comment: "Queue song count")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                self.playerService.toggleQueueDisplayMode()
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .help(String(localized: "Close side panel"))
            .accessibilityLabel(String(localized: "Close side panel"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - QueueFooterActions

/// The queue's own footer controls: undo, redo, shuffle and clear.
///
/// Internal rather than file-private so its layout can be measured offscreen at the widths the Now
/// Playing column can be dragged to (see `QueueFooterLayoutTests`).
@available(macOS 26.0, *)
struct QueueFooterActions: View {
    @Environment(PlayerService.self) private var playerService

    /// The actions, with or without their names.
    ///
    /// The names are what the reader wants, but this row is in the Now Playing column, which can be
    /// dragged down to 300pt: with four titled controls in a row that narrow, SwiftUI keeps the labels
    /// and *wraps* them — "Undo" over two lines, "Shuffle" cut in half, the row twice as tall as its
    /// buttons. So the row states two versions of itself and `ViewThatFits` picks the first that fits:
    /// names while there is room for them, glyphs (each with a tooltip and a VoiceOver label) when there
    /// is not. A narrower row is read as one line of icons rather than four broken words.
    ///
    /// The two versions measure 257pt and 94pt, so a row that holds all four names needs about 289pt of
    /// panel width (the row's own 16pt insets included). The column's floor is 300pt, and the queue is the
    /// one page the column does not inset (its rows are their own bands — see `NowPlayingSidebarQueuePage`),
    /// so the
    /// narrowest column has the 300pt the names need and shows them; the glyph version is the row's answer
    /// to being squeezed below that, which the column itself cannot do. Nothing in between can wrap:
    /// `fixedSize` is on each button, so an over-long candidate overflows its row instead of breaking a
    /// word, and `ViewThatFits` never picks it in the first place (`QueueFooterLayoutTests` measures
    /// both versions and the switch).
    var body: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                self.actions(showsTitles: true)
                self.actions(showsTitles: false)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func actions(showsTitles: Bool) -> some View {
        HStack(spacing: 12) {
            self.button(
                title: String(localized: "Undo"),
                systemImage: "arrow.uturn.backward",
                showsTitle: showsTitles,
                isEnabled: self.playerService.canUndoQueue
            ) {
                self.playerService.undoQueue()
            }

            self.button(
                title: String(localized: "Redo"),
                systemImage: "arrow.uturn.forward",
                showsTitle: showsTitles,
                isEnabled: self.playerService.canRedoQueue
            ) {
                self.playerService.redoQueue()
            }

            self.button(
                title: String(localized: "Shuffle"),
                systemImage: "shuffle",
                showsTitle: showsTitles,
                isEnabled: !self.playerService.queue.isEmpty
            ) {
                self.playerService.shuffleQueue()
            }

            self.button(
                title: String(localized: "Clear"),
                systemImage: "trash",
                showsTitle: showsTitles,
                isEnabled: !self.playerService.queue.isEmpty,
                tint: .red
            ) {
                Task {
                    if self.playerService.isPlaying {
                        await self.playerService.stop()
                    }
                    self.playerService.clearQueueEntirely()
                }
            }
        }
    }

    private func button(
        title: String,
        systemImage: String,
        showsTitle: Bool,
        isEnabled: Bool,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            self.label(title: title, systemImage: systemImage, showsTitle: showsTitle)
                .foregroundStyle(tint ?? .primary)
                // No wrapping in either version, and no ambiguity about which one fits: an unwrapped
                // label is what makes the titled row's width the sum of its words, so `ViewThatFits`
                // compares real widths instead of two candidates that both "fit" by wrapping.
                .fixedSize(horizontal: true, vertical: false)
                .font(.system(size: 12))
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    /// The glyph, and the name when there is room for it.
    ///
    /// The glyph is in both versions so the row reads as the same four controls either way. Dropping
    /// the name leaves the `Label`'s accessibility value alone — `.help` states it for the pointer — and
    /// the button's own `accessibilityLabel` states it for VoiceOver.
    @ViewBuilder
    private func label(title: String, systemImage: String, showsTitle: Bool) -> some View {
        if showsTitle {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                // One line, never two. `fixedSize` is what keeps the row from being *squeezed* at all,
                // and this is the belt to its braces: even if the row were compressed by a future
                // edit, the worst a name can do is truncate rather than break mid-word.
                .lineLimit(1)
        } else {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview("Queue Side Panel") {
    let playerService = PlayerService()
    QueueSidePanelView()
        .environment(playerService)
        .environment(FavoritesManager.shared)
        .frame(height: 600)
}
