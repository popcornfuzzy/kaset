import Foundation
import SwiftUI

// MARK: - Collection Extensions

extension Collection {
    /// Safe subscript that returns nil if index is out of bounds.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - TimeInterval Extensions

extension TimeInterval {
    /// Formats the time interval as "mm:ss" or "h:mm:ss".
    var formattedDuration: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies a modifier conditionally.
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Applies a modifier if a value is present.
    @ViewBuilder
    func ifLet<Value>(_ value: Value?, transform: (Self, Value) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - URL Extensions

extension URL {
    /// Returns a higher quality YouTube thumbnail URL.
    var highQualityThumbnailURL: URL? {
        self.highQualityThumbnailCandidates.first
    }

    /// Returns ordered thumbnail URL candidates, best quality first and the exact URL last.
    ///
    /// The first candidate is the preferred HQ variant; the tail is a fallback chain, because the
    /// promoted sizes do not exist for every video: `maxresdefault.jpg` and large `=wN-hN` requests
    /// are missing for a share of them (YouTube answers those with HTTP 404, and `ImageCache` rejects
    /// that body instead of rendering the placeholder it contains). Callers that render artwork
    /// should walk the whole chain.
    var highQualityThumbnailCandidates: [URL] {
        guard host?.contains("ytimg.com") == true || host?.contains("googleusercontent.com") == true else {
            return [self]
        }

        let original = self
        let originalString = original.absoluteString
        var candidates: [URL] = []
        var seen: Set<String> = []

        func appendCandidate(_ urlString: String) {
            guard let url = URL(string: urlString) else { return }
            guard seen.insert(url.absoluteString).inserted else { return }
            candidates.append(url)
        }

        // 1) Promote known YouTube-style size tokens (largest first).
        let sizeUpgrades = [
            "w60-h60": ["w544-h544", "w320-h320", "w226-h226"],
            "w120-h120": ["w544-h544", "w320-h320", "w226-h226"],
            "w180-h180": ["w544-h544", "w320-h320", "w226-h226"],
            "w226-h226": ["w544-h544", "w320-h320"],
        ]

        for (token, replacements) in sizeUpgrades {
            guard originalString.contains(token) else { continue }
            for replacement in replacements {
                appendCandidate(originalString.replacingOccurrences(of: token, with: replacement))
            }
        }

        // 2) Promote googleusercontent '=sXX' style size parameters.
        let scalarUpgrades = ["=s60", "=s88", "=s120", "=s160"]
        for token in scalarUpgrades where originalString.contains(token) {
            appendCandidate(originalString.replacingOccurrences(of: token, with: "=s544"))
            appendCandidate(originalString.replacingOccurrences(of: token, with: "=s320"))
            appendCandidate(originalString.replacingOccurrences(of: token, with: "=s226"))
        }

        // 3) Promote the classic `i.ytimg.com` named stills.
        //
        // These names are the only shapes that host serves, so a still has to be requested by name: the
        // API answers a large share of tracks with `sddefault.jpg` (640x480) or `hqdefault.jpg` (480x360),
        // and without promoting those the preferred candidate *is* that small still. The largest surface
        // (fullscreen artwork, up to 380pt — 760px on a Retina display) then drew it upscaled even though
        // `maxresdefault.jpg` / `hq720.jpg` (1280x720) exists for the same video. The promoted stills are
        // also true 16:9 where the 4:3 defaults are letterboxed, so this is a visible win, not just a
        // sharper one.
        if host?.contains("ytimg.com") == true {
            let namedUpgrades: [(variant: String, upgrades: [String])] = [
                ("/default.jpg", ["/maxresdefault.jpg", "/hq720.jpg", "/sddefault.jpg", "/hqdefault.jpg"]),
                ("/mqdefault.jpg", ["/maxresdefault.jpg", "/hq720.jpg", "/sddefault.jpg", "/hqdefault.jpg"]),
                // The original still follows this chain (step 5), so `sddefault` only has to look upward.
                ("/sddefault.jpg", ["/maxresdefault.jpg", "/hq720.jpg"]),
                ("/hqdefault.jpg", ["/maxresdefault.jpg", "/hq720.jpg", "/sddefault.jpg"]),
            ]

            for (variant, upgrades) in namedUpgrades where originalString.contains(variant) {
                for upgrade in upgrades {
                    appendCandidate(originalString.replacingOccurrences(of: variant, with: upgrade))
                }
            }
        }

        // 4) Keep previous behavior as a deterministic fallback candidate.
        appendCandidate(originalString.replacingOccurrences(of: "w60-h60", with: "w226-h226"))
        appendCandidate(originalString.replacingOccurrences(of: "w120-h120", with: "w226-h226"))

        // 5) End with the exact URL. Every promoted variant can be unavailable, but this URL is the
        // one the API/WebView actually served, so it is the last resort before the artwork is blank.
        appendCandidate(originalString)

        // 6) Degrade to variants that exist more often. Placed after the original so the preferred size
        // stays first: a URL that was already promoted to the largest variant must still be able to
        // fall back to a smaller one (`hqdefault.jpg` always exists).
        if host?.contains("ytimg.com") == true {
            if originalString.contains("/maxresdefault.jpg") {
                appendCandidate(originalString.replacingOccurrences(of: "/maxresdefault.jpg", with: "/sddefault.jpg"))
                appendCandidate(originalString.replacingOccurrences(of: "/maxresdefault.jpg", with: "/hqdefault.jpg"))
            } else if originalString.contains("/hq720.jpg") {
                appendCandidate(originalString.replacingOccurrences(of: "/hq720.jpg", with: "/sddefault.jpg"))
                appendCandidate(originalString.replacingOccurrences(of: "/hq720.jpg", with: "/hqdefault.jpg"))
            } else if originalString.contains("/sddefault.jpg") {
                appendCandidate(originalString.replacingOccurrences(of: "/sddefault.jpg", with: "/hqdefault.jpg"))
            }
        }

        // Same idea for size tokens: the largest variants are the ones most often missing.
        let sizeDownsizes = [
            "w544-h544": ["w320-h320", "w226-h226"],
            "w320-h320": ["w226-h226"],
        ]

        for (token, replacements) in sizeDownsizes {
            guard originalString.contains(token) else { continue }
            for replacement in replacements {
                appendCandidate(originalString.replacingOccurrences(of: token, with: replacement))
            }
        }

        return candidates
    }
}

// MARK: - String Extensions

extension String {
    /// Returns a truncated version of the string.
    func truncated(to length: Int, trailing: String = "…") -> String {
        if count > length {
            return String(prefix(length)) + trailing
        }
        return self
    }
}

// MARK: - Color Extensions

extension Color {
    /// Creates a Color from a hex string (e.g., "#FF5733" or "FF5733").
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let length = hexSanitized.count
        switch length {
        case 6: // RGB
            let red = Double((rgb >> 16) & 0xFF) / 255.0
            let green = Double((rgb >> 8) & 0xFF) / 255.0
            let blue = Double(rgb & 0xFF) / 255.0
            self.init(red: red, green: green, blue: blue)
        case 8: // ARGB
            let red = Double((rgb >> 16) & 0xFF) / 255.0
            let green = Double((rgb >> 8) & 0xFF) / 255.0
            let blue = Double(rgb & 0xFF) / 255.0
            let alpha = Double((rgb >> 24) & 0xFF) / 255.0
            self.init(red: red, green: green, blue: blue, opacity: alpha)
        default:
            return nil
        }
    }
}
