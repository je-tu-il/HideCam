import AVFoundation
import AVKit
import SwiftData
import SwiftUI
import UIKit

// MARK: - Share sheet via UIActivityViewController

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - GalleryView

struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingEntry.createdAt, order: .reverse) private var recordings: [RecordingEntry]

    @State private var selectedRecording: RecordingEntry?
    @State private var player: AVPlayer?
    @State private var showPlayer = false
    @State private var showDeleteConfirm = false
    @State private var recordingToDelete: RecordingEntry?
    @State private var showShareSheet = false
    @State private var shareURL: URL?

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
                videoPlayerView
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = shareURL {
                    ActivityViewController(activityItems: [url])
                        .presentationDetents([.medium, .large])
                }
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
                recordingRow(entry)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            recordingToDelete = entry
                            showDeleteConfirm = true
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            shareFile(entry)
                        } label: {
                            Label("Partager", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            shareFile(entry)
                        } label: {
                            Label("Partager / Ouvrir avec", systemImage: "square.and.arrow.up")
                        }
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

            Button {
                playRecording(entry)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            playRecording(entry)
        }
    }

    // MARK: - Video / Audio player (unified via AVPlayer)

    private var videoPlayerView: some View {
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

        selectedRecording = entry

        // Use AVPlayer for everything — handles audio-only .mov files
        let player = AVPlayer(url: url)
        self.player = player
        showPlayer = true
        player.play()
    }

    private func shareFile(_ entry: RecordingEntry) {
        let url = URL(fileURLWithPath: entry.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        shareURL = url
        showShareSheet = true
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
        case "multiCam":   return "camera.on.rectangle.fill"
        default:           return "recordingtape"
        }
    }
}

#Preview {
    GalleryView()
}
