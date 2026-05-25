import AVFoundation
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var cameraManager = CameraManager()
    @AppStorage(RecorderSettingsKeys.showGallery) private var showGalleryEnabled: Bool = false
    @State private var showGallery = false
    @State private var pulsingOpacity: Double = 1.0

    private let shouldShowSettingsAtLaunch: Bool

    init() {
        shouldShowSettingsAtLaunch = AVAudioSession.sharedInstance().outputVolume == 1.0
    }

    var body: some View {
        Group {
            if shouldShowSettingsAtLaunch || showGallery {
                if showGallery {
                    GalleryView()
                } else {
                    SettingsView()
                }
            } else {
                ZStack {
                    Color.black
                        .edgesIgnoringSafeArea(.all)

                    // Recording indicator dot
                    if cameraManager.isRecording {
                        recordingDot
                    }

                    // Gallery access hint (subtle)
                    if showGalleryEnabled {
                        galleryHint
                    }
                }
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    cameraManager.configure(modelContext: modelContext)
                    cameraManager.recoverOrphanedChunks()
                    cameraManager.startFromCurrentSystemVolume()
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                        pulsingOpacity = 0.3
                    }
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

    // MARK: - Recording dot

    private var recordingDot: some View {
        VStack {
            HStack {
                Spacer()
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .opacity(pulsingOpacity)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsingOpacity)
                    .padding(.top, 16)
                    .padding(.trailing, 16)
            }
            Spacer()
        }
    }

    // MARK: - Gallery hint

    private var galleryHint: some View {
        VStack {
            Spacer()
            Text("Appui long pour la galerie")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.25))
                .padding(.bottom, 40)
        }
    }

    // MARK: - Scene phase

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Stop chunk rotation; final chunk will finish naturally via maxRecordedDuration
            Task {
                await cameraManager.stopRecordingAndFinalize()
            }
        case .active:
            // Recover any orphaned chunks from a previous kill
            cameraManager.recoverOrphanedChunks()
        default:
            break
        }
    }
}

#Preview {
    ContentView()
}
