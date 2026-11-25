import AVFoundation
import SwiftData
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("recorder.captureMode") private var action = RecordingAction.backVideo
    @AppStorage("recorder.includeLocation") private var includeLocation = false
    @State private var camera = CameraManager()
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if showSettings {
                SettingsView(showSettings: $showSettings, showGallery: $showGallery)
            } else if showGallery {
                GalleryView(showGallery: $showGallery, showSettings: $showSettings)
            } else {
                NavigationStack {
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(red: 0.04, green: 0.05, blue: 0.08),
                                Color(red: 0.08, green: 0.11, blue: 0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .ignoresSafeArea()

                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 18) {
                                statusHeroCard
                                captureModeGrid
                                optionsCard
                                primaryCaptureButton
                                quickNavigationRow
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                        }
                    }
                    .navigationTitle("HideCam")
                    .toolbarColorScheme(.dark, for: .navigationBar)
                }
                .preferredColorScheme(.dark)
            }
        }
        .onAppear {
            camera.configure(modelContext: modelContext)
            camera.recoverOrphanedChunks()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background && camera.isRecording && !working { saveInBackground() }
        }
        .alert("Enregistrement indisponible", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var statusHeroCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill((camera.isRecording ? Color.red : Color.cyan).opacity(0.16))
                    .frame(width: 54, height: 54)
                Image(systemName: camera.isRecording ? "record.circle.fill" : "camera.aperture")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(camera.isRecording ? .red : .cyan)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(camera.isRecording ? "Enregistrement actif" : "Prêt pour la capture")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                if let started = camera.recordingStartedAt, camera.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text(started, style: .timer)
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    .accessibilityLabel("Enregistrement en cours")
                } else {
                    Text("Mode : \(action.title) · Stockage local chiffré iOS")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.66))
                }
            }

            Spacer()
        }
        .padding(16)
        .background(.white.opacity(0.06))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke((camera.isRecording ? Color.red : Color.white).opacity(0.16), lineWidth: 1)
        }
        .clipShape(.rect(cornerRadius: 22))
    }

    private var captureModeGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Source de capture")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.65))
                .textCase(.uppercase)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(RecordingAction.allCases) { mode in
                    let isSelected = action == mode
                    Button {
                        action = mode
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: iconForMode(mode))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(isSelected ? .black : .cyan)
                            Text(mode.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(isSelected ? .black : .white)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(isSelected ? Color.cyan : Color.white.opacity(0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(isSelected ? Color.cyan : Color.white.opacity(0.1), lineWidth: 1)
                        }
                        .clipShape(.rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(working || camera.isRecording)
            .opacity((working || camera.isRecording) ? 0.6 : 1.0)
        }
    }

    private var optionsCard: some View {
        Toggle(isOn: $includeLocation) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Joindre la localisation")
                        .font(.subheadline.weight(.semibold))
                    Text("Ajoute les coordonnées GPS aux métadonnées")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            } icon: {
                Image(systemName: "location.fill")
                    .foregroundStyle(.cyan)
            }
        }
        .tint(.cyan)
        .padding(16)
        .background(.white.opacity(0.06))
        .clipShape(.rect(cornerRadius: 18))
        .disabled(working || camera.isRecording)
    }

    private var primaryCaptureButton: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                if working {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: camera.isRecording ? "stop.fill" : "record.circle")
                        .font(.title3.weight(.bold))
                }
                Text(camera.isRecording ? "Arrêter et sauvegarder" : "Démarrer l’enregistrement")
                    .font(.headline.weight(.bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                LinearGradient(
                    colors: camera.isRecording
                        ? [Color.red, Color.orange]
                        : [Color(red: 0.06, green: 0.56, blue: 0.92), Color(red: 0.08, green: 0.72, blue: 0.65)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(.rect(cornerRadius: 20))
            .shadow(color: (camera.isRecording ? Color.red : Color.cyan).opacity(0.28), radius: 14, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    private var quickNavigationRow: some View {
        HStack(spacing: 12) {
            Button {
                showGallery = true
            } label: {
                HStack {
                    Image(systemName: "film.stack")
                        .foregroundStyle(.cyan)
                    Text("Enregistrements")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(.white.opacity(0.06))
                .clipShape(.rect(cornerRadius: 18))
            }
            .buttonStyle(.plain)

            Button {
                showSettings = true
            } label: {
                HStack {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.cyan)
                    Text("Réglages")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(.white.opacity(0.06))
                .clipShape(.rect(cornerRadius: 18))
            }
            .buttonStyle(.plain)
        }
        .disabled(working || camera.isRecording)
    }

    private func iconForMode(_ mode: RecordingAction) -> String {
        switch mode {
        case .audio: return "mic.fill"
        case .frontVideo: return "person.crop.rectangle"
        case .backVideo: return "camera.fill"
        case .multiCam: return "camera.on.rectangle.fill"
        }
    }

    private func toggle() {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                if camera.isRecording { await camera.stopRecordingAndFinalize() }
                else {
                    try await camera.startRecording(action: action, includeLocation: includeLocation)
                    if scenePhase == .background { await camera.stopRecordingAndFinalize() }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveInBackground() {
        working = true
        let application = UIApplication.shared
        let task = application.beginBackgroundTask(withName: "Finalize recording")
        Task { @MainActor in
            await camera.stopRecordingAndFinalize()
            working = false
            if task != .invalid { application.endBackgroundTask(task) }
        }
    }
}
