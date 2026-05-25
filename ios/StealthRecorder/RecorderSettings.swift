import AVFoundation
import Foundation

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
    static let step0Action: String = "recorder.step0Action"
    static let step1Action: String = "recorder.step1Action"
    static let step2Action: String = "recorder.step2Action"
    static let step3Action: String = "recorder.step3Action"
    static let showGallery: String = "recorder.showGallery"
}

nonisolated struct RecorderSettings: Sendable {
    let videoQuality: VideoQuality
    let saveDestination: SaveDestination
    let stepActions: [Int: RecordingAction]
    let showGallery: Bool

    static func load(from defaults: UserDefaults = .standard) -> RecorderSettings {
        let videoQuality: VideoQuality = VideoQuality(rawValue: defaults.string(forKey: RecorderSettingsKeys.videoQuality) ?? "") ?? .high
        let saveDestination: SaveDestination = SaveDestination(rawValue: defaults.string(forKey: RecorderSettingsKeys.saveDestination) ?? "") ?? .documents
        let showGallery: Bool = defaults.bool(forKey: RecorderSettingsKeys.showGallery)

        let actions: [Int: RecordingAction] = [
            0: action(for: RecorderSettingsKeys.step0Action, defaultAction: .audio, defaults: defaults),
            1: action(for: RecorderSettingsKeys.step1Action, defaultAction: .frontVideo, defaults: defaults),
            2: action(for: RecorderSettingsKeys.step2Action, defaultAction: .backVideo, defaults: defaults),
            3: action(for: RecorderSettingsKeys.step3Action, defaultAction: .multiCam, defaults: defaults)
        ]

        return RecorderSettings(videoQuality: videoQuality, saveDestination: saveDestination, stepActions: actions, showGallery: showGallery)
    }

    private static func action(for key: String, defaultAction: RecordingAction, defaults: UserDefaults) -> RecordingAction {
        RecordingAction(rawValue: defaults.string(forKey: key) ?? "") ?? defaultAction
    }
}
