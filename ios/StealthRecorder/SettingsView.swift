import SwiftData
import SwiftUI

struct SettingsView: View {
    @Binding var showSettings: Bool
    @Binding var showGallery: Bool

    @AppStorage(RecorderSettingsKeys.videoQuality) private var videoQuality = VideoQuality.high
    @AppStorage(RecorderSettingsKeys.saveDestination) private var destination = SaveDestination.documents
    @AppStorage(RecorderSettingsKeys.showInFiles) private var showInFiles = true

    @AppStorage("recorder.volumeLaunch") private var volumeLaunch = false
    @AppStorage("recorder.recordingDisplay") private var recordingDisplay = RecordingDisplay.controls
    @AppStorage("recorder.includeLocation") private var includeLocation = false
    @AppStorage(RecorderSettingsKeys.step0Action) private var step0 = RecordingAction.audio
    @AppStorage(RecorderSettingsKeys.step1Action) private var step1 = RecordingAction.frontVideo
    @AppStorage(RecorderSettingsKeys.step2Action) private var step2 = RecordingAction.backVideo
    @AppStorage(RecorderSettingsKeys.step3Action) private var step3 = RecordingAction.multiCam

    var body: some View {
        NavigationStack {
            Form {
                Section("Démarrage") {
                    Toggle("Utiliser le volume au lancement", isOn: $volumeLaunch)
                    if volumeLaunch {
                        volumePicker(0, action: $step0)
                        volumePicker(1, action: $step1)
                        volumePicker(2, action: $step2)
                        volumePicker(3, action: $step3)
                        Text("Au volume maximal, l’app s’ouvre sur l’accueil.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Inclure la localisation", isOn: $includeLocation)
                }
                Section("Enregistrement") {
                    Picker("Affichage pendant la capture", selection: $recordingDisplay) {
                        ForEach(RecordingDisplay.allCases) { display in
                            Text(display.title).tag(display)
                        }
                    }
                }
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

    private func volumePicker(_ step: Int, action: Binding<RecordingAction>) -> some View {
        Picker("Volume \(step)", selection: action) {
            ForEach(RecordingAction.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
    }
}
