import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - LyricsSettingsView

/// Settings for synced lyrics: enable/disable, per-provider toggles that can be
/// reordered to set priority, and a hidden provider-status card.
@available(macOS 26.0, *)
struct LyricsSettingsView: View {
    @Environment(SyncedLyricsService.self) private var syncedLyricsService
    @State private var settings = SettingsManager.shared
    @State private var statusService = LyricsProviderStatusService()
    @State private var showStatusCard = false
    @State private var isClearingLyricsCache = false
    /// The provider currently being dragged. Set on drag start and cleared on
    /// drop so the drop delegate can resolve the live reorder.
    @State private var draggingProvider: SettingsManager.LyricsProviderID?

    var body: some View {
        Form {
            // MARK: - Enable

            Section {
                Toggle("Enable Synced Lyrics", isOn: self.$settings.syncedLyricsEnabled)
                    .help("Fetch and display real-time synced lyrics when available")
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Synced lyrics highlight each line as the song plays. Higher-fidelity providers also light up words individually.")
            }

            // MARK: - Providers

            Section {
                ForEach(Array(self.settings.lyricsProviderOrder.enumerated()), id: \.element) { index, provider in
                    LyricsProviderRow(
                        provider: provider,
                        priority: index + 1,
                        isEnabled: self.enabledBinding(for: provider),
                        isDragging: self.draggingProvider == provider,
                        canMoveUp: index > 0,
                        canMoveDown: index < self.settings.lyricsProviderOrder.count - 1,
                        moveUp: { self.move(provider, by: -1) },
                        moveDown: { self.move(provider, by: 1) }
                    )
                    .onDrag {
                        self.draggingProvider = provider
                        return NSItemProvider(object: provider.rawValue as NSString)
                    } preview: {
                        LyricsProviderDragPreview(provider: provider)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: ProviderReorderDropDelegate(
                            provider: provider,
                            dragging: self.$draggingProvider,
                            reorder: { dragged, target in
                                withAnimation(.snappy(duration: 0.22)) {
                                    self.settings.moveLyricsProvider(dragged, to: target)
                                }
                            },
                            finalize: { self.reload() }
                        )
                    )
                    .contextMenu {
                        Button("Move Up") { self.move(provider, by: -1) }
                            .disabled(index == 0)
                        Button("Move Down") { self.move(provider, by: 1) }
                            .disabled(index == self.settings.lyricsProviderOrder.count - 1)
                    }
                }
                if self.settings.enabledLyricsProviders.isEmpty {
                    Label(
                        "No providers enabled — lyrics lookups are off.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Drag to reorder. All enabled providers are searched at once; the highest-fidelity result wins, and ties favor the higher position.")
            }

            // MARK: - Cache

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lyrics Cache")
                        Text("Clears cached lyrics for previously played songs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(self.isClearingLyricsCache ? String(localized: "Clearing...") : String(localized: "Clear Cache")) {
                        self.clearLyricsCache()
                    }
                    .disabled(self.isClearingLyricsCache)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Cache")
            }

            // MARK: - Hidden status card

            Section {
                Button {
                    withAnimation {
                        self.showStatusCard.toggle()
                    }
                    if self.showStatusCard {
                        Task { await self.statusService.refresh() }
                    }
                } label: {
                    HStack {
                        Image(systemName: "circle.grid.2x2")
                        Text("Provider Status")
                        Spacer()
                        Image(systemName: self.showStatusCard ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if self.showStatusCard {
                    ProviderStatusCard(statusService: self.statusService)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } footer: {
                if self.showStatusCard {
                    Text("Reachability check for each provider's server — green means the host responded.")
                } else {
                    Text("Hidden diagnostics. Click to check whether each provider's server is reachable.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("Lyrics")
    }

    // MARK: - Bindings

    private func enabledBinding(for provider: SettingsManager.LyricsProviderID) -> Binding<Bool> {
        Binding(
            get: { self.settings.isLyricsProviderEnabled(provider) },
            set: { enabled in
                self.settings.setLyricsProvider(provider, enabled: enabled)
                self.reload()
            }
        )
    }

    // MARK: - Actions

    private func move(_ provider: SettingsManager.LyricsProviderID, by offset: Int) {
        self.settings.moveLyricsProvider(provider, by: offset)
        self.reload()
    }

    private func reload() {
        self.syncedLyricsService.reloadProviderFromSettings()
    }

    private func clearLyricsCache() {
        self.isClearingLyricsCache = true
        self.syncedLyricsService.clearCache(keepCurrent: true)
        self.isClearingLyricsCache = false
    }
}

// MARK: - LyricsProviderRow

@available(macOS 26.0, *)
private struct LyricsProviderRow: View {
    let provider: SettingsManager.LyricsProviderID
    let priority: Int
    @Binding var isEnabled: Bool
    let isDragging: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(self.priority)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)

            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
                .help("Drag to reorder")
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(self.provider.displayName)
                Text(self.provider.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            self.moveControls

            Toggle("", isOn: self.$isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(self.provider.displayName)
        }
        .padding(.vertical, 2)
        .opacity(self.isDragging ? 0.35 : (self.isEnabled ? 1 : 0.5))
    }

    private var moveControls: some View {
        HStack(spacing: 0) {
            Button(action: self.moveUp) {
                Image(systemName: "chevron.up")
            }
            .disabled(!self.canMoveUp)
            .help("Move Up")
            .accessibilityLabel("Move Up")

            Button(action: self.moveDown) {
                Image(systemName: "chevron.down")
            }
            .disabled(!self.canMoveDown)
            .help("Move Down")
            .accessibilityLabel("Move Down")
        }
        .buttonStyle(.plain)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

// MARK: - LyricsProviderDragPreview

/// The floating snapshot shown while a provider row is dragged.
@available(macOS 26.0, *)
private struct LyricsProviderDragPreview: View {
    let provider: SettingsManager.LyricsProviderID

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.provider.displayName)
                    .font(.callout.weight(.medium))
                Text(self.provider.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }
}

// MARK: - ProviderReorderDropDelegate

/// Drives live, animated reordering while a provider handle is dragged: entering
/// a row moves the dragged provider to that row's position immediately, so the
/// list shifts out of the way as the pointer travels. The service is reloaded
/// once, when the drop completes — not on every hover move.
@available(macOS 26.0, *)
private struct ProviderReorderDropDelegate: DropDelegate {
    let provider: SettingsManager.LyricsProviderID
    @Binding var dragging: SettingsManager.LyricsProviderID?
    let reorder: (SettingsManager.LyricsProviderID, SettingsManager.LyricsProviderID) -> Void
    let finalize: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != provider else { return }
        self.reorder(dragging, provider)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard dragging != nil else { return false }
        dragging = nil
        self.finalize()
        return true
    }
}

// MARK: - ProviderStatusCard

@available(macOS 26.0, *)
private struct ProviderStatusCard: View {
    let statusService: LyricsProviderStatusService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(SettingsManager.LyricsProviderID.allCases) { provider in
                HStack(spacing: 10) {
                    StatusLED(status: self.statusService.status(for: provider))
                    Text(provider.displayName)
                    Spacer()
                    Text(Self.label(for: self.statusService.status(for: provider)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                if let lastChecked = statusService.lastChecked {
                    Text("Last checked \(lastChecked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Refresh") {
                    Task { await self.statusService.refresh() }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    private static func label(for status: LyricsProviderStatusService.Status) -> String {
        switch status {
        case .unknown: String(localized: "Not checked")
        case .checking: String(localized: "Checking…")
        case .available: String(localized: "Available")
        case .unavailable: String(localized: "Unreachable")
        }
    }
}

// MARK: - StatusLED

@available(macOS 26.0, *)
private struct StatusLED: View {
    let status: LyricsProviderStatusService.Status

    var body: some View {
        Circle()
            .fill(self.color)
            .frame(width: 10, height: 10)
            .overlay(
                Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: self.color.opacity(0.7), radius: 3)
            .accessibilityLabel(self.accessibilityLabel)
    }

    private var color: Color {
        switch self.status {
        case .unknown: .secondary
        case .checking: .yellow
        case .available: .green
        case .unavailable: .red
        }
    }

    private var accessibilityLabel: String {
        switch self.status {
        case .unknown: String(localized: "Not checked")
        case .checking: String(localized: "Checking…")
        case .available: String(localized: "Available")
        case .unavailable: String(localized: "Unreachable")
        }
    }
}
