import Foundation
import SwiftData

@Model
final class RecordingEntry {
    var id: UUID
    var fileName: String
    var filePath: String
    var createdAt: Date
    var duration: TimeInterval
    var latitude: Double?
    var longitude: Double?
    var actionType: String

    init(
        fileName: String,
        filePath: String,
        createdAt: Date,
        duration: TimeInterval,
        latitude: Double? = nil,
        longitude: Double? = nil,
        actionType: String
    ) {
        self.id = UUID()
        self.fileName = fileName
        self.filePath = filePath
        self.createdAt = createdAt
        self.duration = duration
        self.latitude = latitude
        self.longitude = longitude
        self.actionType = actionType
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// Resolves the actual file URL on disk, handling app container UUID migrations safely.
    var resolvedURL: URL {
        let directURL = URL(fileURLWithPath: filePath)
        if FileManager.default.fileExists(atPath: directURL.path) {
            return directURL
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: docs.path) {
            return docs
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: appSupport.path) {
            return appSupport
        }
        return directURL
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: resolvedURL.path)
    }

    var fileSizeDescription: String {
        let url = resolvedURL
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64, size > 0 else {
            return ""
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var formattedDuration: String {
        let totalSeconds = max(0, Int(duration))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedDate: String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: createdAt)
    }

    var formattedTime: String {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        return df.string(from: createdAt)
    }

    var actionDisplayName: String {
        switch actionType {
        case "audio":     return "Audio"
        case "frontVideo": return "Vidéo Avant"
        case "backVideo":  return "Vidéo Arrière"
        case "multiCam":   return "Multi-Caméra"
        default:           return actionType
        }
    }
}
