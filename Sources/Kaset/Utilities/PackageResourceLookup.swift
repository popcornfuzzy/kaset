import AppKit
import SwiftUI

enum PackageResourceLookup {
    private static let resourceBundleName = "Kaset_Kaset.bundle"
    private static let accentColorName = NSColor.Name("AccentColor")

    static let localizationBundle = Self.candidateBundles.first

    static let brandAccent: Color = {
        if let color = NSColor(named: accentColorName, bundle: Bundle.main) {
            return Color(nsColor: color)
        }

        for bundle in candidateBundles {
            if let color = NSColor(named: accentColorName, bundle: bundle) {
                return Color(nsColor: color)
            }
        }

        return Color(red: 1.0, green: 0.0, blue: 0.337)
    }()

    /// Resolves the bundle whose compiled asset catalog contains `name`, so
    /// brand images load whether they ship in `Bundle.main` or the SwiftPM
    /// resource bundle. Returns `Bundle.main` when the asset isn't found.
    static func bundle(forImageNamed name: String) -> Bundle {
        let resource = NSImage.Name(name)
        if Bundle.main.image(forResource: resource) != nil {
            return Bundle.main
        }

        for bundle in candidateBundles where bundle.image(forResource: resource) != nil {
            return bundle
        }

        return Bundle.main
    }

    private static let bundleSearchRoots: [Bundle] = {
        var bundles: [Bundle] = [Bundle.main]
        bundles.append(contentsOf: Bundle.allBundles)
        bundles.append(contentsOf: Bundle.allFrameworks)

        var uniqueBundles: [Bundle] = []
        var seenPaths = Set<String>()

        for bundle in bundles {
            guard seenPaths.insert(bundle.bundleURL.path).inserted else { continue }
            uniqueBundles.append(bundle)
        }

        return uniqueBundles
    }()

    private static let candidateBundles: [Bundle] = {
        var bundles: [Bundle] = []
        var seenPaths = Set<String>()
        var candidateURLs: [URL] = Self.bundleSearchRoots.flatMap { bundle in
            Self.candidateURLs(for: bundle)
        }
        candidateURLs.append(contentsOf: Self.bundleCandidatesInBuildDirectory())

        for url in candidateURLs {
            guard seenPaths.insert(url.path).inserted else { continue }
            guard let bundle = Bundle(url: url) else { continue }
            bundles.append(bundle)
        }

        return bundles
    }()

    private static func candidateURLs(for bundle: Bundle) -> [URL] {
        [
            bundle.resourceURL?.appendingPathComponent(self.resourceBundleName),
            bundle.bundleURL.appendingPathComponent(self.resourceBundleName),
            bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(self.resourceBundleName),
            bundle.executableURL?.deletingLastPathComponent().appendingPathComponent(self.resourceBundleName),
        ]
        .compactMap(\.self)
    }

    private static func bundleCandidatesInBuildDirectory() -> [URL] {
        let fileManager = FileManager.default
        let buildDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var bundleURLs: [URL] = []

        for case let url as URL in enumerator where url.lastPathComponent == Self.resourceBundleName {
            bundleURLs.append(url)
        }

        return bundleURLs
    }
}
