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
    @State private var resumeScrollGeneration = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 60)

                    ForEach(Array(self.lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        let status = self.currentStatus(for: index)
                        if self.lyrics.isPauseLine(at: index) || (line.words == nil && line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            SyncedPauseDotsLineView(
                                dotStatuses: self.lyrics.pauseDotStatuses(forLineAt: index, at: self.currentTimeMs),
                                status: status,
                                onTap: { self.onSeek(line.timeInMs) }
                            )
                            .id(line.id)
                        } else {
                            SyncedLineView(
                                line: line,
                                lyrics: self.lyrics,
                                status: status,
                                currentTimeMs: self.currentTimeMs,
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
            // Attach scrolling state to the actual ScrollView rather than relying
            // on a competing gesture recognizer over its content.
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting:
                    self.userIsScrolling = true
                    self.resumeScrollGeneration += 1
                    self.scrollResumeTask?.cancel()
                case .decelerating:
                    let generation = self.resumeScrollGeneration
                    self.scrollResumeTask?.cancel()
                    self.scrollResumeTask = Task {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }
                        self.userIsScrolling = false
                        self.scrollToCurrentLine(using: proxy, animated: true)
                    }
                default:
                    break
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        self.userIsScrolling = true
                        self.resumeScrollGeneration += 1
                        self.scrollResumeTask?.cancel()
                    }
                    .onEnded { _ in
                        let generation = self.resumeScrollGeneration
                        self.scrollResumeTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled, generation == self.resumeScrollGeneration else { return }
                            self.userIsScrolling = false
                            self.scrollToCurrentLine(using: proxy, animated: true)
                        }
                    }
            )
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
                self.syncCurrentLine(using: newTimeMs, proxy: proxy, animate: !self.userIsScrolling)
            }
            .onAppear {
                self.syncCurrentLine(using: self.currentTimeMs, proxy: proxy, animate: false)
                SingletonPlayerWebView.shared.startLyricsPoll()
                SingletonPlayerWebView.shared.sendCurrentLyricsTime()
            }
            .task {
                // Lazy stacks may not have materialized the first target yet.
                // Retry the initial scroll after layout and WebView startup.
                for _ in 0 ..< 8 {
                    guard !Task.isCancelled else { return }
                    await Task.yield()
                    self.syncCurrentLine(using: self.currentTimeMs, proxy: proxy, animate: false)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            .onDisappear {
                self.scrollResumeTask?.cancel()
            }
        }
    }

    private func syncCurrentLine(using timeMs: Int, proxy: ScrollViewProxy, animate: Bool) {
        guard let index = self.lyrics.currentLineIndex(at: timeMs) else { return }
        let id = self.lyrics.lines[index].id
        self.currentLineIndex = index
        let lineChanged = id != self.currentLineId
        self.currentLineId = id
        guard lineChanged, !self.userIsScrolling else { return }
        if animate { withAnimation(.easeInOut(duration: 0.42)) { proxy.scrollTo(id, anchor: .center) } }
        else { proxy.scrollTo(id, anchor: .center) }
    }

    private func scrollToCurrentLine(using proxy: ScrollViewProxy, animated: Bool) {
        guard let index = self.currentLineIndex,
              self.lyrics.lines.indices.contains(index)
        else { return }
        let id = self.lyrics.lines[index].id
        if animated {
            withAnimation(.easeInOut(duration: 0.42)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
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

struct FlowKaraokeLine: View {
    let words: [TimedWord]
    let currentTimeMs: Int
    let color: Color

    var body: some View {
        Text(self.attributedText)
            .foregroundStyle(self.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.linear(duration: 0.08), value: self.currentTimeMs)
    }

    private var attributedText: AttributedString {
        var result = AttributedString()
        for (index, word) in self.words.enumerated() {
            var value = AttributedString(word.word)
            let progress = self.wordProgress(at: index)
            value.foregroundColor = self.color.opacity(progress > 0 ? 1 : 0.30)
            result.append(value)
        }
        return result
    }

    private func wordProgress(at index: Int) -> CGFloat {
        let word = self.words[index]
        let nextTime = self.words.indices.contains(index + 1) ? self.words[index + 1].timeInMs : word.timeInMs + 220
        return CGFloat(min(max(Double(self.currentTimeMs - word.timeInMs) / Double(max(1, nextTime - word.timeInMs)), 0), 1))
    }

    private func wordOpacity(at index: Int) -> Double {
        let progress = self.wordProgress(at: index)
        return progress >= 1 ? 1 : 0.30
    }
}

struct SyncedLineView: View {
    let line: SyncedLyricLine
    let lyrics: SyncedLyrics
    let status: SyncedLyrics.LineStatus
    let currentTimeMs: Int
    let onTap: () -> Void

    private var displayText: String {
        let text = self.line.text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "♪" : self.line.text
    }

    var body: some View {
        Group {
            if self.lyrics.isPauseLine(at: self.lyrics.lines.firstIndex(of: self.line) ?? -1) || (self.line.words == nil && self.line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                SyncedPauseDotsLineView(
                    dotStatuses: self.lyrics.pauseDotStatuses(forLineAt: self.lyrics.lines.firstIndex(of: self.line) ?? -1, at: self.currentTimeMs),
                    status: self.status,
                    onTap: self.onTap
                )
            } else if let words = self.line.words, !words.isEmpty {
                self.wordLine(words)
            } else {
                Text(self.displayText)
            }
        }
        .font(.system(size: 16, weight: .bold))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
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

    private func wordLine(_ words: [TimedWord]) -> some View {
        FlowKaraokeLine(words: words, currentTimeMs: self.currentTimeMs, color: .primary)
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
