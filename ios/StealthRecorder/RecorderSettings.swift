import AVFoundation
import Foundation
import UIKit

nonisolated enum RecordingAction: String, CaseIterable, Identifiable, Sendable {
    case audio
    case frontVideo
    case backVideo
    case multiCam

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio:
            "Audio"
        case .frontVideo:
            "Vidéo Avant"
        case .backVideo:
            "Vidéo Arrière"
        case .multiCam:
            "Multi-Caméra"
        }
    }
}

enum RecordingDisplay: String, CaseIterable, Identifiable {
    case controls, dark, game

    var id: Self { self }

    var title: String {
        switch self {
        case .controls: "Commandes"
        case .dark: "Écran sombre"
        case .game: "2048"
        }
    }
}

nonisolated enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            "Basse"
        case .medium:
            "Moyenne"
        case .high:
            "Haute"
        }
    }

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .low:
            .low
        case .medium:
            .medium
        case .high:
            .high
        }
    }
}

nonisolated enum SaveDestination: String, CaseIterable, Identifiable, Sendable {
    case documents
    case photoLibrary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documents:
            "Dossier Documents"
        case .photoLibrary:
            "Galerie Photo"
        }
    }
}

nonisolated enum RecorderSettingsKeys {
    static let videoQuality: String = "recorder.videoQuality"
    static let saveDestination: String = "recorder.saveDestination"
    static let showInFiles: String = "recorder.showInFiles"
    static let step0Action: String = "recorder.step0Action"
    static let step1Action: String = "recorder.step1Action"
    static let step2Action: String = "recorder.step2Action"
    static let step3Action: String = "recorder.step3Action"
    static let showGallery: String = "recorder.showGallery"
    static let enable2048Decoy: String = "recorder.enable2048Decoy"
    static let alwaysShowGameDecoy: String = "recorder.alwaysShowGameDecoy"
    static let decoyAction: String = "recorder.decoyAction"
}

nonisolated struct RecorderSettings: Sendable {
    let videoQuality: VideoQuality
    let saveDestination: SaveDestination
    let showInFiles: Bool
    let stepActions: [Int: RecordingAction]
    let showGallery: Bool
    let enable2048Decoy: Bool
    let alwaysShowGameDecoy: Bool
    let decoyAction: RecordingAction

    static func load(from defaults: UserDefaults = .standard) -> RecorderSettings {
        let videoQuality: VideoQuality = VideoQuality(rawValue: defaults.string(forKey: RecorderSettingsKeys.videoQuality) ?? "") ?? .high
        let saveDestination: SaveDestination = SaveDestination(rawValue: defaults.string(forKey: RecorderSettingsKeys.saveDestination) ?? "") ?? .documents
        let showInFiles: Bool = defaults.object(forKey: RecorderSettingsKeys.showInFiles) == nil ? true : defaults.bool(forKey: RecorderSettingsKeys.showInFiles)
        let showGallery: Bool = defaults.bool(forKey: RecorderSettingsKeys.showGallery)
        let enable2048Decoy: Bool = defaults.object(forKey: RecorderSettingsKeys.enable2048Decoy) == nil ? true : defaults.bool(forKey: RecorderSettingsKeys.enable2048Decoy)
        let alwaysShowGameDecoy: Bool = defaults.bool(forKey: RecorderSettingsKeys.alwaysShowGameDecoy)
        let decoyAction: RecordingAction = action(for: RecorderSettingsKeys.decoyAction, defaultAction: .backVideo, defaults: defaults)

        let actions: [Int: RecordingAction] = [
            0: action(for: RecorderSettingsKeys.step0Action, defaultAction: .audio, defaults: defaults),
            1: action(for: RecorderSettingsKeys.step1Action, defaultAction: .frontVideo, defaults: defaults),
            2: action(for: RecorderSettingsKeys.step2Action, defaultAction: .backVideo, defaults: defaults),
            3: action(for: RecorderSettingsKeys.step3Action, defaultAction: .multiCam, defaults: defaults)
        ]

        return RecorderSettings(
            videoQuality: videoQuality,
            saveDestination: saveDestination,
            showInFiles: showInFiles,
            stepActions: actions,
            showGallery: showGallery,
            enable2048Decoy: enable2048Decoy,
            alwaysShowGameDecoy: alwaysShowGameDecoy,
            decoyAction: decoyAction
        )
    }

    private static func action(for key: String, defaultAction: RecordingAction, defaults: UserDefaults) -> RecordingAction {
        RecordingAction(rawValue: defaults.string(forKey: key) ?? "") ?? defaultAction
    }
}

// MARK: - Haptics disabled (Zero vibration for absolute discretion)

@MainActor
enum HapticHelper {
    static func recordStarted() {
        // Aucune vibration (silence et discrétion totale)
    }

    static func recordStopped() {
        // Aucune vibration (silence et discrétion totale)
    }

    static func error() {
        // Aucune vibration (silence et discrétion totale)
    }
}
