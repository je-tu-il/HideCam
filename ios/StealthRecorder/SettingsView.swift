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
    @AppStorage(RecorderSettingsKeys.enable2048Decoy) private var enable2048Decoy: Bool = true
    @AppStorage(RecorderSettingsKeys.decoyAction) private var decoyAction: String = RecordingAction.backVideo.rawValue

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

                // Section 2: Camouflage Jeu 2048
                Section("Camouflage Jeu 2048") {
                    Toggle("Activer le leurre Jeu 2048", isOn: $enable2048Decoy)

                    if enable2048Decoy {
                        Picker("Caméra pendant le jeu", selection: $decoyAction) {
                            ForEach(RecordingAction.allCases) { action in
                                Text(action.title).tag(action.rawValue)
                            }
                        }

                        NavigationLink {
                            Game2048View()
                                .navigationTitle("Jeu 2048")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label("Tester le jeu 2048", systemImage: "gamecontroller.fill")
                        }
                    }
                } footer: {
                    Text("Lorsque le volume dépasse le palier 3 (crans 4 à 15), l'écran affiche une vraie partie de 2048 tout en filmant silencieusement en arrière-plan.")
                }

                // Section 3: Paliers de volume
                Section {
                    stepPicker(title: "Palier 0 (vol. 0% - 0 cran)", selection: $step0Action)
                    stepPicker(title: "Palier 1 (1 cran, ~6%)", selection: $step1Action)
                    stepPicker(title: "Palier 2 (2 crans, ~12%)", selection: $step2Action)
                    stepPicker(title: "Palier 3 (3 crans, 1 cran unique)", selection: $step3Action)

                    HStack {
                        Text("Volume actuel")
                        Spacer()
                        Text("\(Int(currentVolume * 100))% — \(currentTierText)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Paliers de volume matériel (Écran noir)")
                } footer: {
                    Text("Le palier 3 occupe exactement 1 barre de volume. Au-dessus, le jeu 2048 prend le relais.")
                }

                // Section 4: Destination & Qualité
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

                // Section 5: Fonctionnement discret
                Section("Fonctionnement discret") {
                    Label("Écran noir inerte : aucune réaction tactile sur paliers 0 à 3", systemImage: "hand.raised.slash.fill")
                    Label("Jeu 2048 jouable : s'affiche dès le 4ème cran de volume", systemImage: "gamecontroller.fill")
                    Label("Changement de volume : bascule instantanément l'action", systemImage: "speaker.wave.2.fill")
                    Label("Mise en veille : sauvegarde automatique immédiate", systemImage: "moon.fill")
                    Label("Retour sur l'app : relance automatique de l'enregistrement", systemImage: "arrow.clockwise.circle.fill")
                    Label("Son à fond (100%) : accès unique à cette configuration", systemImage: "speaker.wave.3.fill")
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
        case ..<0.04:
            return "Palier 0 (Écran noir)"
        case 0.04..<0.10:
            return "Palier 1 (Écran noir)"
        case 0.10..<0.16:
            return "Palier 2 (Écran noir)"
        case 0.16..<0.22:
            return "Palier 3 (1 cran, Écran noir)"
        case 0.22..<0.98:
            return enable2048Decoy ? "Jeu 2048 (Leurre actif)" : "Écran noir"
        default:
            return "100% (Réglages)"
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
