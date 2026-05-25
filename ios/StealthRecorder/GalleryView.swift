import AVKit
import SwiftData
import SwiftUI

struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingEntry.createdAt, order: .reverse) private var recordings: [RecordingEntry]

    @State private var selectedRecording: RecordingEntry?
    @State private var player: AVPlayer?
    @State private var showPlayer = false
    @State private var showDeleteConfirm = false
    @State private var recordingToDelete: RecordingEntry?

    var body: some View {
        NavigationStack {
            Group {
                if recordings.isEmpty {
                    emptyState
                } else {
                    recordingList
                }
            }
            .navigationTitle("Enregistrements")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showPlayer) {
                playerView
            }
            .alert("Supprimer l'enregistrement ?", isPresented: $showDeleteConfirm) {
                Button("Annuler", role: .cancel) {}
                Button("Supprimer", role: .destructive) {
                    if let entry = recordingToDelete { deleteRecording(entry) }
                }
            } message: {
                Text("Cette action est irréversible. Le fichier sera supprimé définitivement.")
            }
            .onAppear {
                try? AVAudioSession.sharedInstance().setActive(false)
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "recordingtape")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Aucun enregistrement")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text("Les enregistrements apparaîtront ici avec leur date, heure et position.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Recording list

    private var recordingList: some View {
        List {
            ForEach(recordings) { entry in
                Button {
                    playRecording(entry)
                } label: {
                    recordingRow(entry)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        recordingToDelete = entry
                        showDeleteConfirm = true
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Row

    private func recordingRow(_ entry: RecordingEntry) -> some View {
        HStack(spacing: 14) {
            // Thumbnail placeholder with action icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray5))
                    .frame(width: 52, height: 52)

                Image(systemName: iconName(for: entry.actionType))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.formattedDate)
                        .font(.headline)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(entry.formattedTime)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Label(entry.formattedDuration, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.tertiary)

                    Label(entry.actionDisplayName, systemImage: "camera.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if entry.hasLocation {
                    Label(
                        String(format: "%.4f, %.4f", entry.latitude!, entry.longitude!),
                        systemImage: "location.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Image(systemName: "play.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Player

    private var playerView: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .edgesIgnoringSafeArea(.all)
                    .overlay(alignment: .topLeading) {
                        Button {
                            player.pause()
                            self.player = nil
                            showPlayer = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                        .padding(24)
                    }
            }
        }
    }

    // MARK: - Actions

    private func playRecording(_ entry: RecordingEntry) {
        let url = URL(fileURLWithPath: entry.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let player = AVPlayer(url: url)
        self.player = player
        showPlayer = true
        player.play()
    }

    private func deleteRecording(_ entry: RecordingEntry) {
        let url = URL(fileURLWithPath: entry.filePath)
        try? FileManager.default.removeItem(at: url)
        modelContext.delete(entry)
        try? modelContext.save()
    }

    private func iconName(for actionType: String) -> String {
        switch actionType {
        case "audio":     return "mic.fill"
        case "frontVideo": return "camera.fill"
        case "backVideo":  return "camera.fill"
        case "multiCam":   return "camera.fill"
        default:           return "recordingtape"
        }
    }
}

#Preview {
    GalleryView()
}
