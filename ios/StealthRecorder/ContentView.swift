import AVFoundation
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var cameraManager = CameraManager()

    @State private var showSettings = false
    @State private var showGallery = false
    @State private var hasBooted = false

    // Volume observation
    @State private var volumeObserver: NSKeyValueObservation?
    @State private var lastObservedVolume: Float = 0.0
    @State private var runtimeGameOverride: Bool? = nil

    private var isDecoyGameActive: Bool {
        let settings = RecorderSettings.load()
        guard settings.enable2048Decoy else { return false }
        if let override = runtimeGameOverride {
            return override && lastObservedVolume < 0.99
        }
        if settings.alwaysShowGameDecoy {
            return lastObservedVolume < 0.99
        }
        return lastObservedVolume >= 0.22 && lastObservedVolume < 0.98
    }

    var body: some View {
        Group {
            if showSettings {
                SettingsView(showSettings: $showSettings, showGallery: $showGallery)
            } else if showGallery {
                GalleryView(showGallery: $showGallery, showSettings: $showSettings)
            } else if isDecoyGameActive {
                Game2048View(onToggleBlackScreen: {
                    runtimeGameOverride = false
                })
                .edgesIgnoringSafeArea(.all)
            } else {
                stealthView
            }
        }
        .onAppear {
            bootApplication()
        }
        .onDisappear {
            volumeObserver?.invalidate()
            volumeObserver = nil
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    // MARK: - Boot Logic

    /// Détermine si l'application doit démarrer sur le menu de configuration (son à fond uniquement)
    /// ou directement en mode enregistrement discret (écran noir ou leurre 2048 selon le volume).
    private func bootApplication() {
        guard !hasBooted else { return }
        hasBooted = true

        // Garantit la présence du dossier Documents pour indexation dans l'app Fichiers d'iOS
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        cameraManager.configure(modelContext: modelContext)
        cameraManager.recoverOrphanedChunks()

        // Active d'abord la session audio pour lire le volume matériel réel
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let initialVolume = audioSession.outputVolume
        lastObservedVolume = initialVolume

        // Ne démarre sur les réglages QUE SI le son est à fond (100% / >= 0.99)
        if initialVolume >= 0.99 {
            showSettings = true
        } else {
            showSettings = false
            cameraManager.startFromCurrentSystemVolume()
        }

        setupVolumeObserver()
    }

    // MARK: - Stealth Black Screen View (Aucune interaction tactile)

    private var stealthView: some View {
        Color.black
            .edgesIgnoringSafeArea(.all)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onTapGesture(count: 2) {
                if RecorderSettings.load().enable2048Decoy {
                    runtimeGameOverride = true
                }
            }
    }

    // MARK: - Volume Observer (Seul moyen de contrôle en mode furtif)

    private func setupVolumeObserver() {
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { session, change in
            guard let newVol = change.newValue else { return }
            Task { @MainActor in
                let previous = lastObservedVolume
                lastObservedVolume = newVol

                // 1. Son mis à fond (100% / >= 0.99) : ouvrir les réglages
                if newVol >= 0.99 && previous < 0.99 && !showSettings && !showGallery {
                    if cameraManager.isRecording {
                        await cameraManager.stopRecordingAndFinalize()
                    }
                    runtimeGameOverride = nil
                    showSettings = true
                    return
                }

                // 2. Changement de volume sous les 99% : déclenche ou bascule l'enregistrement selon le palier
                if !showSettings && !showGallery && newVol < 0.99 {
                    let settings = RecorderSettings.load()
                    let targetAction = cameraManager.recordingAction(for: newVol, settings: settings)

                    if cameraManager.isRecording {
                        if cameraManager.currentAction != targetAction {
                            // Bascule de palier : finalise l'ancien et lance le nouveau
                            await cameraManager.stopRecordingAndFinalize()
                            cameraManager.startFromCurrentSystemVolume()
                        }
                    } else {
                        // Démarre l'enregistrement
                        cameraManager.startFromCurrentSystemVolume()
                    }
                }
            }
        }
    }

    // MARK: - Scene Phase (Mise en veille / Arrière-plan / Retour au premier plan)

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Dès que le téléphone est mis en veille (bouton power / verrouillage),
            // on finalise et sauvegarde immédiatement l'enregistrement en cours via tâche d'arrière-plan
            if cameraManager.isRecording {
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "StealthRecorder.SaveOnSleep") {
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }

                Task {
                    await cameraManager.stopRecordingAndFinalize()
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }
            }
        case .active:
            cameraManager.recoverOrphanedChunks()
            // Quand on retourne sur l'app sans l'avoir redémarrée, relancer un enregistrement
            if !showSettings && !showGallery && !cameraManager.isRecording {
                cameraManager.startFromCurrentSystemVolume()
            }
        default:
            break
        }
    }
}

#Preview {
    ContentView()
}
