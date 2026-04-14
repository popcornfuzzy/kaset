import SwiftUI

/// Settings view for app metadata, update controls, and What's New testing actions.
@available(macOS 26.0, *)
struct AboutSettingsView: View {
    @State private var isResettingWhatsNew = false
    @State private var isCurrentVersionWhatsNewMarkedRead = false

    /// The updater service for managing app updates.
    var updaterService: UpdaterService

    var body: some View {
        @Bindable var updater = self.updaterService

        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticChecksEnabled)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Software Update")
                        if let lastCheck = self.updaterService.lastUpdateCheckDate {
                            Text("Last checked: \(lastCheck, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Never checked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Check Now") {
                        self.updaterService.checkForUpdates()
                    }
                    .disabled(!self.updaterService.canCheckForUpdates)
                }
                .padding(.vertical, 4)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What's New")
                        Text(
                            self.isCurrentVersionWhatsNewMarkedRead
                                ? "Marked as read for version \(self.currentWhatsNewVersion.description)"
                                : "Not marked as read for version \(self.currentWhatsNewVersion.description)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(
                        self.isResettingWhatsNew
                            ? String(localized: "Resetting...")
                            : String(localized: "Reset Current Version")
                    ) {
                        self.resetWhatsNewForCurrentVersion()
                    }
                    .disabled(!self.isCurrentVersionWhatsNewMarkedRead || self.isResettingWhatsNew)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Updates")
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(self.appVersion)
                        .foregroundStyle(.secondary)
                }

                Link(destination: URL(string: "https://github.com/popcornfuzzy/kaset")!) {
                    HStack {
                        Text("This Fork")
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .foregroundStyle(.secondary)
                    }
                }

                Link(destination: URL(string: "https://github.com/sozercan/kaset")!) {
                    HStack {
                        Text("Original Project")
                        Spacer()
                        Image(systemName: "arrow.up.forward.square")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("About")
        .task {
            self.refreshWhatsNewReadState()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private var currentWhatsNewVersion: WhatsNew.Version {
        .current()
    }

    private func resetWhatsNewForCurrentVersion() {
        self.isResettingWhatsNew = true
        let store = WhatsNewVersionStore()
        store.clearPresented(self.currentWhatsNewVersion)
        self.refreshWhatsNewReadState()
        self.isResettingWhatsNew = false
    }

    private func refreshWhatsNewReadState() {
        self.isCurrentVersionWhatsNewMarkedRead = WhatsNewVersionStore().hasPresented(self.currentWhatsNewVersion)
    }
}
