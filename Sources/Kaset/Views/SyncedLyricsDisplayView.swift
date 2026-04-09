import SwiftUI

// MARK: - SyncedLyricsDisplayView

struct SyncedLyricsDisplayView: View {
    let lyrics: SyncedLyrics
    let currentTimeMs: Int
    let onSeek: (Int) -> Void

    @State private var currentLineId: UUID?
    @State private var currentLineIndex: Int?
    /// Whether the user has manually scrolled (pauses auto-scroll).
    @State private var userIsScrolling = false
    /// Timer task to resume auto-scroll after user interaction.
    @State private var scrollResumeTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 60)

                    ForEach(Array(self.lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        let status = self.currentStatus(for: index)
                        if self.lyrics.isPauseLine(at: index) {
                            SyncedPauseDotsLineView(
                                dotStatuses: self.lyrics.pauseDotStatuses(forLineAt: index, at: self.currentTimeMs),
                                status: status,
                                onTap: { self.onSeek(line.timeInMs) }
                            )
                            .id(line.id)
                        } else {
                            SyncedLineView(
                                line: line,
                                status: status,
                                onTap: { self.onSeek(line.timeInMs) }
                            )
                            .id(line.id)
                        }
                    }

                    Spacer().frame(height: 120)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        self.userIsScrolling = true
                        self.scrollResumeTask?.cancel()
                    }
                    .onEnded { _ in
                        self.scrollResumeTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            if !Task.isCancelled {
                                self.userIsScrolling = false
                            }
                        }
                    }
            )
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
                if let currentIdx = lyrics.currentLineIndex(at: newTimeMs) {
                    let newId = self.lyrics.lines[currentIdx].id
                    if newId != self.currentLineId {
                        self.currentLineId = newId
                        self.currentLineIndex = currentIdx
                        if !self.userIsScrolling {
                            withAnimation(.spring(duration: 0.45, bounce: 0.0)) {
                                proxy.scrollTo(newId, anchor: .center)
                            }
                        }
                    }
                }
            }
            .onAppear {
                if let initialIdx = self.lyrics.currentLineIndex(at: self.currentTimeMs) {
                    self.currentLineIndex = initialIdx
                    self.currentLineId = self.lyrics.lines[initialIdx].id
                }
            }
            .onDisappear {
                self.scrollResumeTask?.cancel()
            }
        }
    }

    private func currentStatus(for lineIndex: Int) -> SyncedLyrics.LineStatus {
        guard let currentLineIndex else { return .upcoming }
        if lineIndex < currentLineIndex { return .previous }
        if lineIndex == currentLineIndex { return .current }
        return .upcoming
    }
}

// MARK: - SyncedLineView

@available(macOS 26.0, *)
struct SyncedPauseDotsLineView: View {
    let dotStatuses: [SyncedLyrics.PauseDotStatus]
    let status: SyncedLyrics.LineStatus
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { dotIndex in
                self.dotView(for: self.safeDotStatus(at: dotIndex))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .opacity(self.lineOpacity(for: self.status))
        .scaleEffect(self.lineScale(for: self.status), anchor: .leading)
        .animation(.easeInOut(duration: 0.35), value: self.dotStatuses)
        .animation(.easeInOut(duration: 0.35), value: self.status)
        .contentShape(Rectangle())
        .onTapGesture {
            self.onTap()
        }
    }

    @ViewBuilder
    private func dotView(for dotStatus: SyncedLyrics.PauseDotStatus) -> some View {
        let dot = Circle()
            .fill(Color.primary)
            .frame(width: 7, height: 7)
            .opacity(self.dotOpacity(for: dotStatus))

        if dotStatus == .active {
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: 0.72) / 0.72
                let yOffset = -2.8 * (0.5 + 0.5 * sin(phase * 2 * .pi))

                dot.offset(y: yOffset)
            }
        } else {
            dot
        }
    }

    private func safeDotStatus(at index: Int) -> SyncedLyrics.PauseDotStatus {
        guard self.dotStatuses.indices.contains(index) else { return .notSung }
        return self.dotStatuses[index]
    }

    private func dotOpacity(for status: SyncedLyrics.PauseDotStatus) -> Double {
        switch status {
        case .notSung:
            0.28
        case .active:
            1.0
        case .sung:
            0.65
        }
    }

    private func lineScale(for status: SyncedLyrics.LineStatus) -> CGFloat {
        switch status {
        case .current:
            1.0
        case .previous:
            0.95
        case .upcoming:
            0.965
        }
    }

    private func lineOpacity(for status: SyncedLyrics.LineStatus) -> Double {
        switch status {
        case .current:
            1.0
        case .previous:
            0.35
        case .upcoming:
            0.55
        }
    }
}

// MARK: - SyncedLineView

struct SyncedLineView: View {
    let line: SyncedLyricLine
    let status: SyncedLyrics.LineStatus
    let onTap: () -> Void

    private var displayText: String {
        let text = self.line.text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "♪" : self.line.text
    }

    var body: some View {
        Text(self.displayText)
            .font(.system(size: 16, weight: .bold))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.primary)
            .opacity(self.opacity(for: self.status))
            .scaleEffect(self.scale(for: self.status), anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .animation(.easeInOut(duration: 0.4), value: self.status)
            .contentShape(Rectangle())
            .onTapGesture {
                self.onTap()
            }
    }

    private func scale(for status: SyncedLyrics.LineStatus) -> CGFloat {
        switch status {
        case .current:
            1.0
        case .previous:
            0.95
        case .upcoming:
            0.965
        }
    }

    private func opacity(for status: SyncedLyrics.LineStatus) -> Double {
        switch status {
        case .current:
            1.0
        case .previous:
            0.35
        case .upcoming:
            0.55
        }
    }
}
