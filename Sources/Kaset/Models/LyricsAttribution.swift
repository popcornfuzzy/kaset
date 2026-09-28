import Foundation

// MARK: - LyricsAttribution

/// Who supplied a lyrics result, when the provider credits a person.
///
/// Community providers (Unison) credit the member who submitted a version and
/// expose a public profile for them; catalog providers leave this `nil` and are
/// identified by their `source` label alone.
struct LyricsAttribution: Equatable, Codable, Sendable {
    /// Name of the provider that supplied the lyrics (e.g. `"Unison"`).
    let providerName: String

    /// Display name of the member who submitted the lyrics, if known.
    let submitterName: String?

    /// Public profile page for the submitter, if the provider exposes one.
    let submitterProfileURL: URL?

    /// Avatar image for the submitter, if the provider exposes one.
    let submitterAvatarURL: URL?

    /// Whether there is a person to name in the credit.
    var hasSubmitter: Bool {
        self.submitterName != nil
    }
}
