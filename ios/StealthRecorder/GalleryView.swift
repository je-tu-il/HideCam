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

// MARK: - Thumbnail Generator & View

private struct VideoThumbnailView: View {
    let url: URL
    let actionType: String

    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray5))
                    .frame(width: 52, height: 52)

                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            if actionType != "audio" {
                loadThumbnail()
            }
        }
    }

    private var iconName: String {
        switch actionType {
        case "audio": return "mic.fill"
        case "frontVideo", "backVideo": return "camera.fill"
        case "multiCam": return "camera.on.rectangle.fill"
        default: return "recordingtape"
        }
    }

    private func loadThumbnail() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 140, height: 140)
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                let uiImage = UIImage(cgImage: cgImage)
                await MainActor.run {
                    self.thumbnail = uiImage
                }
            }
        }
    }
}

// MARK: - Native Video Player via AVPlayerViewController

private struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.view.backgroundColor = .black
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

// MARK: - GalleryView

struct GalleryView: View {
    @Binding var showGallery: Bool
    @Binding var showSettings: Bool

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingEntry.createdAt, order: .reverse) private var recordings: [RecordingEntry]

    @State private var selectedRecording: RecordingEntry?
    @State private var player: AVPlayer?
    @State private var showPlayer = false
    @State private var isPlayingAudio = false
    @State private var isAudioPlaying = false

    @State private var showDeleteConfirm = false
    @State private var recordingToDelete: RecordingEntry?
    @State private var showShareSheet = false
    @State private var shareURL: URL?

    init(showGallery: Binding<Bool> = .constant(true), showSettings: Binding<Bool> = .constant(false)) {
        self._showGallery = showGallery
        self._showSettings = showSettings
    }

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
                    Button("Fermer") {
                        showGallery = false
                        showSettings = true
                    }
                    .fontWeight(.semibold)
                }
            }
            .fullScreenCover(isPresented: $showPlayer) {
                if isPlayingAudio {
                    audioPlayerSheet
                } else {
                    videoPlayerSheet
                }
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
                Text("Cette action est irréversible. Le fichier sera supprimé définitivement du stockage.")
            }
            .onAppear {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try? AVAudioSession.sharedInstance().setActive(true)
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
            Text("Vos enregistrements discrets apparaîtront ici avec date, durée, taille et localisation.")
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
                            playRecording(entry)
                        } label: {
                            Label("Lire", systemImage: "play.fill")
                        }
                        Button {
                            shareFile(entry)
                        } label: {
                            Label("Partager / Ouvrir avec", systemImage: "square.and.arrow.up")
                        }
                        if entry.hasLocation {
                            Button {
                                openInMaps(entry)
                            } label: {
                                Label("Voir sur Plans", systemImage: "map.fill")
                            }
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
            VideoThumbnailView(url: entry.resolvedURL, actionType: entry.actionType)

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

                    Label(entry.actionDisplayName, systemImage: iconName(for: entry.actionType))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !entry.fileSizeDescription.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(entry.fileSizeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if entry.hasLocation {
                    Button {
                        openInMaps(entry)
                    } label: {
                        Label(
                            String(format: "%.4f, %.4f", entry.latitude!, entry.longitude!),
                            systemImage: "location.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Button {
                playRecording(entry)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            playRecording(entry)
        }
    }

    // MARK: - Video player sheet

    private var videoPlayerSheet: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                NativeVideoPlayer(player: player)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        Button {
                            player.pause()
                            self.player = nil
                            showPlayer = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.6), radius: 4)
                        }
                        .padding(.top, 44)
                        .padding(.trailing, 20)
                    }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Audio player sheet

    private var audioPlayerSheet: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                HStack {
                    Spacer()
                    Button {
                        player?.pause()
                        player = nil
                        showPlayer = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: 120, height: 120)

                    Image(systemName: "waveform")
                        .font(.system(size: 54))
                        .foregroundStyle(.blue)
                }

                VStack(spacing: 6) {
                    Text(selectedRecording?.actionDisplayName ?? "Enregistrement Audio")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    Text("\(selectedRecording?.formattedDate ?? "") à \(selectedRecording?.formattedTime ?? "")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let entry = selectedRecording, !entry.fileSizeDescription.isEmpty {
                        Text("\(entry.formattedDuration) · \(entry.fileSizeDescription)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button {
                    guard let p = player else { return }
                    if isAudioPlaying {
                        p.pause()
                        isAudioPlaying = false
                    } else {
                        p.play()
                        isAudioPlaying = true
                    }
                } label: {
                    Image(systemName: isAudioPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.blue)
                }

                Spacer()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Actions

    private func playRecording(_ entry: RecordingEntry) {
        let url = entry.resolvedURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        selectedRecording = entry
        isPlayingAudio = (entry.actionType == "audio")

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let player = AVPlayer(url: url)
        self.player = player
        self.isAudioPlaying = true
        showPlayer = true
        player.play()
    }

    private func shareFile(_ entry: RecordingEntry) {
        let url = entry.resolvedURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        shareURL = url
        showShareSheet = true
    }

    private func deleteRecording(_ entry: RecordingEntry) {
        let url = entry.resolvedURL
        try? FileManager.default.removeItem(at: url)
        modelContext.delete(entry)
        try? modelContext.save()
    }

    private func openInMaps(_ entry: RecordingEntry) {
        guard let lat = entry.latitude, let lon = entry.longitude else { return }
        if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=Enregistrement") {
            UIApplication.shared.open(url)
        }
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
