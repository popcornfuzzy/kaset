import SwiftUI

// MARK: - CastButton

/// Player bar button that opens the list of Cast devices.
///
/// Presentation deliberately mirrors `AddToPlaylistPopoverButton`, which is known to work: the
/// popover hangs directly off a plain `Button`, and nothing sits between the two. In particular
/// the accessibility modifiers are applied *outside* the popover, and the button is never disabled
/// — a `.disabled` anchor silently swallows clicks instead of surfacing the problem.
@available(macOS 26.0, *)
struct CastButton: View {
    @Environment(CastService.self) private var castService: CastService?

    @State private var isPresented = false

    var body: some View {
        self.deviceMenuButton
            .accessibilityIdentifier(AccessibilityID.PlayerBar.castButton)
            .accessibilityLabel(self.accessibilityLabel)
            .accessibilityValue(self.castService?.statusDescription ?? "")
    }

    /// The button and its popover, with no modifiers layered between them.
    private var deviceMenuButton: some View {
        Button {
            HapticService.toggle()
            if self.castService == nil {
                // Surfacing this here means a missing environment never looks like a dead button.
                DiagnosticsLogger.cast.error("Cast button tapped, but CastService is not in the environment")
            }
            self.isPresented.toggle()
        } label: {
            Image(systemName: "tv.badge.wifi")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(self.isActive ? .red : .primary.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.pressable)
        .popover(isPresented: self.$isPresented, arrowEdge: .top) {
            CastDevicePopover(castService: self.castService, isPresented: self.$isPresented)
        }
    }

    /// Whether audio is currently being sent to a device.
    private var isActive: Bool {
        self.castService?.isCasting == true
    }

    private var accessibilityLabel: String {
        guard let castService, let device = castService.activeDevice else {
            return String(localized: "Cast")
        }
        return String(localized: "Casting to \(device.name)")
    }
}

// MARK: - CastDevicePopover

/// Device list shown by ``CastButton``.
///
/// The service is passed in rather than read from the environment so that the popover never
/// depends on the environment propagating into a presented view.
@available(macOS 26.0, *)
struct CastDevicePopover: View {
    let castService: CastService?

    @Binding var isPresented: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                self.header
                self.statusLine
                self.content
            }
            .padding(12)
            .frame(width: 320)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        }
        .task {
            // Browsing only costs anything while the menu is open, and a cast session never
            // depends on the browser.
            self.castService?.startDiscovery()
        }
        .onDisappear {
            guard self.castService?.isCasting != true, self.castService?.isBusy != true else { return }
            self.castService?.stopDiscovery()
        }
        .onChange(of: self.castService?.state) { _, state in
            // Nothing left to pick once the stream is up.
            if case .casting = state {
                self.isPresented = false
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text("Cast to", comment: "Heading above the list of Chromecast devices")
                .font(.headline)

            Spacer()

            if self.castService != nil {
                Button {
                    HapticService.toggle()
                    self.castService?.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.PlayerBar.castRefreshButton)
                .accessibilityLabel(String(localized: "Look for devices again"))
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch self.castService?.state {
        case let .failed(message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

        case let .connecting(device):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)

                Text("Connecting to \(device.name)…", comment: "Shown while Kaset connects to a Chromecast")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        case .idle, .searching, .casting, .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let castService {
            self.deviceList(castService)

            if castService.activeDevice != nil {
                Divider()
                self.stopButton(castService)
            }
        } else {
            self.unavailableMessage
        }
    }

    private func deviceList(_ castService: CastService) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if castService.devices.isEmpty {
                    self.searchingPlaceholder
                } else {
                    ForEach(castService.devices) { device in
                        self.deviceRow(device, castService: castService)
                    }
                }
            }
        }
        .frame(minHeight: 96, maxHeight: 260)
    }

    private var searchingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("Looking for devices…", comment: "Shown while searching the network for Chromecasts")
                    .font(.system(size: 13, weight: .medium))

                Text(
                    "Make sure the device is on the same Wi-Fi network.",
                    comment: "Hint shown while searching for Chromecasts"
                )
                .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    private var unavailableMessage: some View {
        Text("Casting is unavailable.", comment: "Shown when the Cast service is not available")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 20)
    }

    private func deviceRow(_ device: CastDevice, castService: CastService) -> some View {
        let isActive = castService.activeDevice?.id == device.id

        return Button {
            HapticService.toggle()
            castService.cast(to: device)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "tv.badge.wifi" : "tv")
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(isActive ? .red : .primary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let model = device.model {
                        Text(model)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer(minLength: 8)

                if isActive {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.PlayerBar.castDeviceRow)
        .accessibilityLabel(device.name)
        .accessibilityValue(isActive ? String(localized: "Casting to \(device.name)") : "")
    }

    private func stopButton(_ castService: CastService) -> some View {
        Button {
            HapticService.toggle()
            castService.stopCasting()
            self.isPresented = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.circle")
                    .font(.system(size: 13))
                    .frame(width: 20)

                Text("Stop Casting")
                    .font(.system(size: 13, weight: .medium))

                Spacer(minLength: 0)
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.PlayerBar.castStopButton)
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    CastDevicePopover(castService: CastService(), isPresented: .constant(true))
}
