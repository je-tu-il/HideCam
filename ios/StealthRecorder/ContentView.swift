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

    // Volume observation
    @State private var volumeObserver: NSKeyValueObservation?

    init() {
        let vol = AVAudioSession.sharedInstance().outputVolume
        _showSettings = State(initialValue: vol >= 0.95)
    }

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
            setupVolumeObserver()
        }
        .onDisappear {
            volumeObserver?.invalidate()
            volumeObserver = nil
        }
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
        .onAppear {
            cameraManager.configure(modelContext: modelContext)
            cameraManager.recoverOrphanedChunks()
            cameraManager.startFromCurrentSystemVolume()
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        // Single tap: toggle recording
        .onTapGesture(count: 1) {
            Task {
                await cameraManager.toggleRecording()
            }
        }
        // Double tap: open settings
        .onTapGesture(count: 2) {
            Task {
                if cameraManager.isRecording {
                    await cameraManager.stopRecordingAndFinalize()
                    HapticHelper.recordStopped()
                }
                showSettings = true
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
        try? AVAudioSession.sharedInstance().setActive(true)
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { session, change in
            guard let newVol = change.newValue else { return }
            Task { @MainActor in
                if newVol >= 0.95 && !showSettings && !showGallery {
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
