import SwiftData
import SwiftUI

struct SettingsView: View {
    @Binding var showSettings: Bool
    @Binding var showGallery: Bool

    @AppStorage(RecorderSettingsKeys.videoQuality) private var videoQuality = VideoQuality.high
    @AppStorage(RecorderSettingsKeys.saveDestination) private var destination = SaveDestination.documents
    @AppStorage(RecorderSettingsKeys.showInFiles) private var showInFiles = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Qualité et stockage") {
                    Picker("Qualité vidéo", selection: $videoQuality) {
                        ForEach(VideoQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    Picker("Destination vidéo", selection: $destination) {
                        ForEach(SaveDestination.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    Toggle("Visible dans Fichiers", isOn: $showInFiles)
                }
                Section {
                    Button("Enregistrements", systemImage: "film") {
                        showSettings = false
                        showGallery = true
                    }
                }
            }
            .navigationTitle("Réglages")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terminé") { showSettings = false }
                }
            }
        }
    }
}
