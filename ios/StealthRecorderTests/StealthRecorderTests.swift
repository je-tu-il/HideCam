//
//  StealthRecorderTests.swift
//  StealthRecorderTests
//
//  Created by Rork on May 23, 2026.
//

import Foundation
import Testing
@testable import StealthRecorder

struct StealthRecorderTests {

    @Test func testVolumeActionMapping() async throws {
        let manager = await CameraManager()
        let settings = RecorderSettings.load()

        // Tier 0: Muted (0.0) -> Audio
        let action0 = await manager.recordingAction(for: 0.0, settings: settings)
        #expect(action0 == .audio)

        // Tier 1: Low volume (0.05) -> Front Video
        let action1 = await manager.recordingAction(for: 0.05, settings: settings)
        #expect(action1 == .frontVideo)

        // Tier 2: Low-medium volume (0.10) -> Back Video
        let action2 = await manager.recordingAction(for: 0.10, settings: settings)
        #expect(action2 == .backVideo)

        // Tier 3: Medium/high volume (0.50) -> Multi-cam or Back Video fallback
        let action3 = await manager.recordingAction(for: 0.50, settings: settings)
        #expect(action3 == .multiCam || action3 == .backVideo)

        // Tier 3: High volume (0.90)
        let actionHigh = await manager.recordingAction(for: 0.90, settings: settings)
        #expect(actionHigh == .multiCam || actionHigh == .backVideo)
    }

    @Test func testRecorderSettingsDefaults() throws {
        let settings = RecorderSettings.load()
        #expect(settings.videoQuality == .high)
        #expect(settings.saveDestination == .documents)
        #expect(settings.showInFiles == true)
        #expect(settings.hapticFeedback == true)
        #expect(settings.stepActions[0] == .audio)
        #expect(settings.stepActions[1] == .frontVideo)
        #expect(settings.stepActions[2] == .backVideo)
    }

    @Test func testRecordingEntryFormatting() throws {
        let entry = RecordingEntry(
            fileName: "test-001.mov",
            filePath: "/dummy/path/test-001.mov",
            createdAt: Date(),
            duration: 125, // 2m 05s
            latitude: 48.8566,
            longitude: 2.3522,
            actionType: "frontVideo"
        )

        #expect(entry.formattedDuration == "2:05")
        #expect(entry.actionDisplayName == "Vidéo Avant")
        #expect(entry.hasLocation == true)
    }

    @Test func testRecordingEntryHourFormatting() throws {
        let entry = RecordingEntry(
            fileName: "test-long.mov",
            filePath: "/dummy/path/test-long.mov",
            createdAt: Date(),
            duration: 3665, // 1h 01m 05s
            latitude: nil,
            longitude: nil,
            actionType: "audio"
        )

        #expect(entry.formattedDuration == "1:01:05")
        #expect(entry.actionDisplayName == "Audio")
        #expect(entry.hasLocation == false)
    }
}
