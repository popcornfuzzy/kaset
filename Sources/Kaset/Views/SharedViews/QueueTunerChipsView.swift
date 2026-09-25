import SwiftUI

// MARK: - QueueTunerChipsView

/// Filter chips that re-tune the current automix queue.
///
/// The chips come from YouTube Music itself (`musicQueueRenderer.subHeaderChipCloud`), so the row
/// shows exactly the tunings the service offers for the playing queue — never a hard-coded list.
/// Selecting a chip replaces the upcoming songs with that tuned mix while the current track keeps
/// playing.
@available(macOS 26.0, *)
struct QueueTunerChipsView: View {
    /// Chips to show, in server order.
    let chips: [QueueTunerChip]
    /// Whether a tuning request is in flight; the row shows progress and ignores taps meanwhile.
    let isLoading: Bool
    /// Called when the user picks a chip.
    let onSelect: (QueueTunerChip) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(self.chips) { chip in
                    QueueTunerChipButton(
                        chip: chip,
                        isLoading: self.isLoading,
                        onSelect: self.onSelect
                    )
                }

                if self.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 2)
                        .accessibilityLabel(String(localized: "Tuning mix"))
                }
            }
            .padding(.vertical, 2)
            .padding(.trailing, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .opacity(self.isLoading ? 0.75 : 1)
        .animation(.snappy(duration: 0.2), value: self.isLoading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Queue.tunerRow)
    }
}

// MARK: - QueueTunerChipButton

@available(macOS 26.0, *)
private struct QueueTunerChipButton: View {
    let chip: QueueTunerChip
    let isLoading: Bool
    let onSelect: (QueueTunerChip) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            self.onSelect(self.chip)
        } label: {
            Text(self.chip.label)
                .font(.system(size: 11, weight: self.chip.isSelected ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(self.foregroundStyle)
                .background(self.backgroundStyle)
                .clipShape(.capsule)
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(self.chip.isSelected ? 0 : 0.12))
                }
                .scaleEffect(self.isHovering && !self.chip.isSelected && !self.isLoading ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .disabled(self.isLoading)
        .onHover { hovering in
            self.isHovering = hovering
        }
        .help(self.chip.label)
        .animation(.snappy(duration: 0.2), value: self.chip.isSelected)
        .animation(.snappy(duration: 0.15), value: self.isHovering)
        .accessibilityIdentifier(AccessibilityID.Queue.tunerChip(self.chip.id))
        .accessibilityLabel(self.chip.label)
        .accessibilityAddTraits(self.chip.isSelected ? [.isSelected] : [])
        .accessibilityHint(String(localized: "Retune the mix"))
    }

    private var foregroundStyle: AnyShapeStyle {
        if self.chip.isSelected {
            return AnyShapeStyle(.white)
        }
        return AnyShapeStyle(self.isHovering ? .primary : .secondary)
    }

    private var backgroundStyle: AnyShapeStyle {
        if self.chip.isSelected {
            return AnyShapeStyle(Color.red.opacity(0.9))
        }
        return AnyShapeStyle(Color.primary.opacity(self.isHovering ? 0.14 : 0.07))
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview("Queue Tuner Chips") {
    QueueTunerChipsView(
        chips: [
            QueueTunerChip(id: "All", label: "All", isSelected: true, playlistId: "RDAMVMx", params: nil),
            QueueTunerChip(id: "Discover", label: "Discover", isSelected: false, playlistId: "RDATa", params: nil),
            QueueTunerChip(id: "Deep cuts", label: "Deep cuts", isSelected: false, playlistId: "RDATb", params: nil),
            QueueTunerChip(id: "Party", label: "Party", isSelected: false, playlistId: "RDATc", params: nil),
        ],
        isLoading: false,
        onSelect: { _ in }
    )
    .frame(width: 280)
    .padding()
}
