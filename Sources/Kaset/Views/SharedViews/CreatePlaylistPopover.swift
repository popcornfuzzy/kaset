import SwiftUI

/// Popover content for creating a new playlist.
@available(macOS 26.0, *)
struct CreatePlaylistPopover: View {
    let client: any YTMusicClientProtocol
    let libraryViewModel: LibraryViewModel?
    var initialTitle = ""
    var onCreated: ((Playlist) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var privacy: PlaylistPrivacy = .private
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Create Playlist")
                    .font(.headline)

                TextField("Playlist title", text: self.$title)
                    .textFieldStyle(.roundedBorder)

                Picker("Privacy", selection: self.$privacy) {
                    ForEach(PlaylistPrivacy.allCases, id: \.self) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                if let errorMessage = self.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }

                HStack {
                    Spacer()

                    Button("Cancel") {
                        self.dismiss()
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await self.createPlaylist() }
                    } label: {
                        if self.isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Create")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.isCreating || self.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
            .frame(width: 300)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        }
        .task {
            if self.title.isEmpty {
                self.title = self.initialTitle
            }
        }
    }

    private func createPlaylist() async {
        let trimmedTitle = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        self.isCreating = true
        defer { self.isCreating = false }

        do {
            let playlist = try await self.client.createPlaylist(title: trimmedTitle, privacy: self.privacy)
            self.libraryViewModel?.addToLibrary(playlist: playlist)
            self.onCreated?(playlist)
            self.dismiss()
        } catch {
            self.errorMessage = error.localizedDescription
            DiagnosticsLogger.api.error("Failed to create playlist from popover: \(error.localizedDescription)")
        }
    }
}
