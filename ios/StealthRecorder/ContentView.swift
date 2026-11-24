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
                    Form {
                        Section {
                            Picker("Mode", selection: $action) {
                                ForEach(RecordingAction.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            Toggle("Joindre la localisation", isOn: $includeLocation)
                        }
                        .disabled(working || camera.isRecording)

                        Section {
                            if let started = camera.recordingStartedAt, camera.isRecording {
                                Label {
                                    Text(started, style: .timer).monospacedDigit()
                                } icon: {
                                    Image(systemName: "record.circle.fill")
                                }
                                .foregroundStyle(.red)
                                .accessibilityLabel("Enregistrement en cours")
                            }
                            Button(camera.isRecording ? "Arrêter et sauvegarder" : "Démarrer l’enregistrement",
                                   systemImage: camera.isRecording ? "stop.circle" : "record.circle",
                                   action: toggle)
                                .disabled(working)
                            if working { ProgressView() }
                        } header: {
                            Text(camera.isRecording ? "Enregistrement en cours" : "Enregistrement")
                        }

                        Section {
                            Button("Enregistrements", systemImage: "film") { showGallery = true }
                            Button("Réglages", systemImage: "gearshape") { showSettings = true }
                        }
                        .disabled(working || camera.isRecording)
                    }
                    .navigationTitle("Enregistreur")
                }
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
