import AVFoundation
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var cameraManager = CameraManager()
    @AppStorage(RecorderSettingsKeys.showGallery) private var showGalleryEnabled: Bool = false
    @State private var showGallery = false

    /// When true, shows the full-screen blocking overlay ("Mise à jour indispensable").
    @State private var isBlocked = false

    private let shouldShowSettingsAtLaunch: Bool

    init() {
        shouldShowSettingsAtLaunch = AVAudioSession.sharedInstance().outputVolume == 1.0
    }

    var body: some View {
        Group {
            if isBlocked {
                blockingOverlay
            } else if shouldShowSettingsAtLaunch || showGallery {
                if showGallery {
                    GalleryView()
                } else {
                    SettingsView()
                }
            } else {
                ZStack {
                    Color.black
                        .edgesIgnoringSafeArea(.all)
                }
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    cameraManager.configure(modelContext: modelContext)
                    cameraManager.recoverOrphanedChunks()
                    cameraManager.startFromCurrentSystemVolume()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhaseChange(newPhase)
                }
                .onLongPressGesture(minimumDuration: 2.0) {
                    if showGalleryEnabled {
                        showGallery = true
                    }
                }
            }
        }
    }

    // MARK: - Blocking overlay ("Mise à jour indispensable")

    private var blockingOverlay: some View {
        ZStack {
            Color.black
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 28) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Mise à jour indispensable")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                Text("Une mise à jour de sécurité est requise pour continuer à utiliser l'application.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button {
                    // Ne fait rien — l'utilisateur doit forcer la fermeture
                } label: {
                    Text("Faire la mise à jour")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.white.opacity(0.15))
                        .clipShape(.rect(cornerRadius: 12))
                }
                .padding(.horizontal, 48)
                .padding(.top, 8)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Scene phase

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Stop recording. When the user returns, show blocking overlay.
            if cameraManager.isRecording {
                isBlocked = true
                Task {
                    await cameraManager.stopRecordingAndFinalize()
                }
            }
        case .active:
            // Recover orphaned chunks from a previous kill
            cameraManager.recoverOrphanedChunks()
            // If we were recording before backgrounding, re-verify volume and restart
            if cameraManager.wasRecordingBeforeBackground {
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
