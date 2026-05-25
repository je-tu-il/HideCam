import SwiftUI

struct SettingsView: View {
    @AppStorage(RecorderSettingsKeys.videoQuality) private var videoQuality: String = VideoQuality.high.rawValue
    @AppStorage(RecorderSettingsKeys.saveDestination) private var saveDestination: String = SaveDestination.documents.rawValue
    @AppStorage(RecorderSettingsKeys.step0Action) private var step0Action: String = RecordingAction.audio.rawValue
    @AppStorage(RecorderSettingsKeys.step1Action) private var step1Action: String = RecordingAction.frontVideo.rawValue
    @AppStorage(RecorderSettingsKeys.step2Action) private var step2Action: String = RecordingAction.backVideo.rawValue
    @AppStorage(RecorderSettingsKeys.step3Action) private var step3Action: String = RecordingAction.multiCam.rawValue
    @AppStorage(RecorderSettingsKeys.showGallery) private var showGallery: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Qualité") {
                    Picker("Qualité vidéo", selection: $videoQuality) {
                        ForEach(VideoQuality.allCases) { quality in
                            Text(quality.title).tag(quality.rawValue)
                        }
                    }
                }

                Section("Actions par palier") {
                    stepPicker(title: "Palier 0 (vol. 0.0)", selection: $step0Action)
                    stepPicker(title: "Palier 1 (vol. 0.01–0.07)", selection: $step1Action)
                    stepPicker(title: "Palier 2 (vol. 0.08–0.13)", selection: $step2Action)
                    stepPicker(title: "Palier 3 (vol. 0.14–0.19)", selection: $step3Action)
                }

                Section("Destination") {
                    Picker("Sauvegarde", selection: $saveDestination) {
                        ForEach(SaveDestination.allCases) { destination in
                            Text(destination.title).tag(destination.rawValue)
                        }
                    }
                }

                Section("Galerie") {
                    Toggle("Accès galerie (appui long)", isOn: $showGallery)
                }

                Section("Enregistrement") {
                    Text("Les enregistrements sont découpés en segments de 3 secondes et fusionnés automatiquement. L'enregistrement continue en arrière-plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Configuration")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private func stepPicker(title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(RecordingAction.allCases) { action in
                Text(action.title).tag(action.rawValue)
            }
        }
    }
}

#Preview {
    SettingsView()
}
