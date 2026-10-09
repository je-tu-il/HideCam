import AVFoundation
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Binding var showSettings: Bool
    @Binding var showGallery: Bool

    @Query private var recordings: [RecordingEntry]

    @AppStorage(RecorderSettingsKeys.videoQuality) private var videoQuality: String = VideoQuality.high.rawValue
    @AppStorage(RecorderSettingsKeys.saveDestination) private var saveDestination: String = SaveDestination.documents.rawValue
    @AppStorage(RecorderSettingsKeys.step0Action) private var step0Action: String = RecordingAction.audio.rawValue
    @AppStorage(RecorderSettingsKeys.step1Action) private var step1Action: String = RecordingAction.frontVideo.rawValue
    @AppStorage(RecorderSettingsKeys.step2Action) private var step2Action: String = RecordingAction.backVideo.rawValue
    @AppStorage(RecorderSettingsKeys.step3Action) private var step3Action: String = RecordingAction.multiCam.rawValue
    @AppStorage(RecorderSettingsKeys.showInFiles) private var showInFiles: Bool = true
    @AppStorage(RecorderSettingsKeys.hapticFeedback) private var hapticFeedback: Bool = true
    @AppStorage(RecorderSettingsKeys.stealthIndicator) private var stealthIndicator: Bool = false

    @State private var currentVolume: Float = AVAudioSession.sharedInstance().outputVolume

    init(showSettings: Binding<Bool> = .constant(true), showGallery: Binding<Bool> = .constant(false)) {
        self._showSettings = showSettings
        self._showGallery = showGallery
    }

    var body: some View {
        NavigationStack {
            Form {
                // Section 1: Raccourcis directs
                Section {
                    Button {
                        showSettings = false
                        showGallery = true
                    } label: {
                        HStack {
                            Label("Voir les enregistrements", systemImage: "photo.on.rectangle.angled")
                            Spacer()
                            Text("\(recordings.count)")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Button {
                        showSettings = false
                    } label: {
                        HStack {
                            Label("Démarrer le mode discret", systemImage: "eye.slash.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                } header: {
                    Text("Accès rapide")
                }

                // Section 2: Paliers de volume
                Section {
                    stepPicker(title: "Palier 0 (vol. 0% - Muet)", selection: $step0Action)
                    stepPicker(title: "Palier 1 (vol. 1% – 7%)", selection: $step1Action)
                    stepPicker(title: "Palier 2 (vol. 8% – 13%)", selection: $step2Action)
                    stepPicker(title: "Palier 3 (vol. 14% – 94%)", selection: $step3Action)

                    HStack {
                        Text("Volume actuel")
                        Spacer()
                        Text("\(Int(currentVolume * 100))% — \(currentTierText)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Actions par palier de volume")
                } footer: {
                    Text("Le volume du téléphone au moment du lancement détermine automatiquement le mode d'enregistrement.")
                }

                // Section 3: Destination & Qualité
                Section("Qualité et stockage") {
                    Picker("Qualité vidéo", selection: $videoQuality) {
                        ForEach(VideoQuality.allCases) { quality in
                            Text(quality.title).tag(quality.rawValue)
                        }
                    }

                    Picker("Sauvegarde", selection: $saveDestination) {
                        ForEach(SaveDestination.allCases) { destination in
                            Text(destination.title).tag(destination.rawValue)
                        }
                    }

                    Toggle("Visible dans l'app Fichiers", isOn: $showInFiles)
                }

                // Section 4: Discrétion & Ergonomie
                Section("Discrétion et retour") {
                    Toggle("Vibrations haptic discrètes", isOn: $hapticFeedback)
                    Toggle("Micro-indicateur d'état (point discret)", isOn: $stealthIndicator)
                } footer: {
                    Text("Une vibration discrète confirme le démarrage (1 coup) et l'enregistrement réussi (2 coups).")
                }

                // Section 5: Gestes en mode discret
                Section("Commandes en écran noir") {
                    Label("1 toucher : Démarrer / Arrêter et sauvegarder", systemImage: "hand.tap")
                    Label("Appui long (1,2 s) : Ouvrir la galerie", systemImage: "hand.tap.fill")
                    Label("Double toucher : Ouvrir les réglages", systemImage: "gearshape")
                    Label("Volume max (100%) : Ouvrir les réglages", systemImage: "speaker.wave.3.fill")
                }
            }
            .navigationTitle("Configuration")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Terminé") {
                        showSettings = false
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                currentVolume = AVAudioSession.sharedInstance().outputVolume
            }
        }
    }

    private var currentTierText: String {
        switch currentVolume {
        case ..<0.01:
            return "Palier 0"
        case 0.01..<0.075:
            return "Palier 1"
        case 0.075..<0.135:
            return "Palier 2"
        default:
            return "Palier 3"
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
