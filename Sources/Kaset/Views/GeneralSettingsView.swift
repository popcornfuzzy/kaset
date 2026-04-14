import SwiftUI

/// Settings view for general app preferences.
@available(macOS 26.0, *)
struct GeneralSettingsView: View {
    @Environment(AuthService.self) private var authService
    @State private var settings = SettingsManager.shared
    @State private var cacheSize: String = .init(localized: "Calculating...")
    @State private var isClearing = false

    var body: some View {
        Form {


            // MARK: - General Section

            Section {
                // Account status
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Account")
                            .font(.headline)
                        Text(self.accountStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if self.authService.state.isLoggedIn {
                        Button("Sign Out") {
                            Task {
                                await self.authService.signOut()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                // Haptic Feedback
                Toggle("Haptic Feedback", isOn: self.$settings.hapticFeedbackEnabled)
                    .help("Provide tactile feedback for actions on Force Touch trackpads")

                // Synced Lyrics
                Toggle("Enable Synced Lyrics", isOn: self.$settings.syncedLyricsEnabled)
                    .help("Fetch and display real-time synced lyrics when available")

                // Safe Ad Blocking
                Toggle("Enable Ad Blocking", isOn: self.$settings.safeAdBlockingEnabled)
                    .help("Uses conservative player-level ad suppression hooks. Disable if playback becomes unstable.")

                // Remember Playback Settings
                Toggle("Remember Shuffle & Repeat", isOn: self.$settings.rememberPlaybackSettings)
                    .help("Save shuffle and repeat settings across app restarts")

                // Default Launch Page
                Picker("Default Page on Launch", selection: self.$settings.defaultLaunchPage) {
                    ForEach(SettingsManager.LaunchPage.allCases) { page in
                        Text(page.displayName).tag(page)
                    }
                }

                // Image Cache
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image Cache")
                        Text(self.cacheSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(self.isClearing ? String(localized: "Clearing...") : String(localized: "Clear Cache")) {
                        Task {
                            await self.clearCache()
                        }
                    }
                    .disabled(self.isClearing)
                }
                .padding(.vertical, 4)
            } header: {
                Text("General")
            }

            // MARK: - Now Playing Section

            Section {
                Toggle("Show Now Playing Notifications", isOn: self.$settings.showNowPlayingNotifications)

                Picker("Now Playing Controls", selection: self.$settings.mediaControlStyle) {
                    ForEach(SettingsManager.MediaControlStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .help("Choose which buttons appear in the Now Playing widget in Control Center")
            } header: {
                Text("Now Playing")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("General")
        .task {
            await self.updateCacheSize()
        }
        .onChange(of: self.settings.safeAdBlockingEnabled) { _, enabled in
            SingletonPlayerWebView.shared.setSafeAdBlockingEnabled(enabled)
        }
    }

    // MARK: - Computed Properties

    private var accountStatusText: String {
        self.authService.state.isLoggedIn ? String(localized: "Signed in to YouTube Music") : String(localized: "Not signed in")
    }

    // MARK: - Actions

    private func updateCacheSize() async {
        let size = await ImageCache.shared.diskCacheSize()
        self.cacheSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func clearCache() async {
        self.isClearing = true
        await ImageCache.shared.clearAllCaches()
        await self.updateCacheSize()
        self.isClearing = false
    }
}
