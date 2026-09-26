import Foundation

// MARK: - LyricsProviderStatusService

/// Probes each lyrics provider's host and exposes a red/green availability
/// status for the hidden diagnostics card in Lyrics settings.
///
/// A provider counts as available when its host answers with any non-server
/// error response — a `404` on the root path still means the service is up.
@MainActor
@Observable
final class LyricsProviderStatusService {
    enum Status: Equatable, Sendable {
        case unknown
        case checking
        case available
        case unavailable
    }

    private(set) var statuses: [SettingsManager.LyricsProviderID: Status] = [:]
    private(set) var lastChecked: Date?

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 6
            configuration.timeoutIntervalForResource = 8
            self.session = URLSession(configuration: configuration)
        }
    }

    func status(for id: SettingsManager.LyricsProviderID) -> Status {
        self.statuses[id] ?? .unknown
    }

    /// Probes every provider concurrently and updates the statuses as results
    /// arrive.
    func refresh() async {
        self.lastChecked = Date()
        for id in SettingsManager.LyricsProviderID.allCases {
            self.statuses[id] = .checking
        }

        let session = self.session
        await withTaskGroup(of: (SettingsManager.LyricsProviderID, Status).self) { group in
            for id in SettingsManager.LyricsProviderID.allCases {
                group.addTask {
                    (id, await Self.probe(id, session: session))
                }
            }
            for await (id, status) in group {
                self.statuses[id] = status
            }
        }
    }

    nonisolated static func probe(_ id: SettingsManager.LyricsProviderID, session: URLSession) async -> Status {
        guard let url = id.probeURL else { return .unknown }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.setValue("Kaset", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            // Any response below 5xx means the host is reachable.
            return http.statusCode < 500 ? .available : .unavailable
        } catch {
            return .unavailable
        }
    }
}

// MARK: - Probe endpoints

extension SettingsManager.LyricsProviderID {
    /// A cheap endpoint used only to check whether the provider's host is
    /// reachable. These are the same hosts the providers query for lyrics.
    var probeURL: URL? {
        switch self {
        case .betterLyrics: URL(string: "https://lyrics-api.boidu.dev/")
        case .paxsenix: URL(string: "https://lyrics.paxsenix.org/")
        case .kugou: URL(string: "https://lyrics.kugou.com/")
        case .lrclib: URL(string: "https://lrclib.net/")
        }
    }
}
