import AVFoundation
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var cameraManager = CameraManager()
    @AppStorage(RecorderSettingsKeys.stealthIndicator) private var stealthIndicator: Bool = false

    @State private var showSettings = false
    @State private var showGallery = false
    @State private var hasBooted = false

    // Volume observation
    @State private var volumeObserver: NSKeyValueObservation?
    @State private var lastObservedVolume: Float = 0.0

    var body: some View {
        Group {
            if showSettings {
                SettingsView(showSettings: $showSettings, showGallery: $showGallery)
            } else if showGallery {
                GalleryView()
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
    }

    // MARK: - Boot Logic

    /// S'assure que l'app ne démarre sur les réglages QUE SI le son est mis à fond (100%).
    /// Sinon, démarre directement en mode furtif (écran noir) et lance l'enregistrement.
    private func bootApplication() {
        guard !hasBooted else { return }
        hasBooted = true

        cameraManager.configure(modelContext: modelContext)
        cameraManager.recoverOrphanedChunks()

        // Active d'abord la session audio pour obtenir le volume matériel réel
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

        // Configuration de l'observateur de volume en temps réel
        setupVolumeObserver()
    }

    // MARK: - Stealth Black Screen View

    private var stealthView: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .edgesIgnoringSafeArea(.all)

            // Optional discreet status indicator in corner
            if stealthIndicator {
                Circle()
                    .fill(cameraManager.isRecording ? Color.red.opacity(0.4) : Color.white.opacity(0.08))
                    .frame(width: 4, height: 4)
                    .padding(12)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .contentShape(Rectangle())
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        // Single tap: toggle recording (démarrer / arrêter et sauvegarder)
        .onTapGesture {
            Task {
                await cameraManager.toggleRecording()
            }
        }
        // Long press: open gallery
        .onLongPressGesture(minimumDuration: 1.2) {
            Task {
                if cameraManager.isRecording {
                    await cameraManager.stopRecordingAndFinalize()
                    HapticHelper.recordStopped()
                }
                showGallery = true
            }
        }
    }

    // MARK: - Volume Observer

    private func setupVolumeObserver() {
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { session, change in
            guard let newVol = change.newValue else { return }
            Task { @MainActor in
                let previous = lastObservedVolume
                lastObservedVolume = newVol

                // Si l'utilisateur met le son à fond (100%) pendant l'utilisation, ouvrir les réglages
                if newVol >= 0.99 && previous < 0.99 && !showSettings && !showGallery {
                    if cameraManager.isRecording {
                        await cameraManager.stopRecordingAndFinalize()
                        HapticHelper.recordStopped()
                    }
                    showSettings = true
                }
            }
        }
    }

    // MARK: - Scene Phase

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if cameraManager.isRecording {
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "StealthRecorder.SaveBackground") {
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
        default:
            break
        }
    }
}

#Preview {
    ContentView()
}
