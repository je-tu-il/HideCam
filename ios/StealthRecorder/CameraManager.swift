import AVFoundation
import CoreLocation
import Foundation
import Photos
import SwiftData
import UIKit

/// Manages the recording lifecycle with chunk-based capture for resilience.
/// Records in chunks using `AVCaptureMovieFileOutput.maxRecordedDuration`.
/// When recording stops, chunks are merged into a final file and saved to the configured destination.
@Observable
final class CameraManager: NSObject, AVCaptureFileOutputRecordingDelegate, CLLocationManagerDelegate {

    // MARK: - Public observable state (MainActor)

    private(set) var isRecording: Bool = false
    private(set) var recordingStartedAt: Date?
    private(set) var currentAction: RecordingAction?
    private(set) var wasRecordingBeforeBackground: Bool = false
    private var modelContext: ModelContext?

    // MARK: - Private capture state

    private let sessionQueue: DispatchQueue = DispatchQueue(
        label: "app.rork.stealth-recorder.session", qos: .userInitiated
    )

    private var activeSession: AVCaptureSession?
    private var activeOutputs: [AVCaptureMovieFileOutput] = []
    private var currentOutputLabels: [ObjectIdentifier: String] = [:]
    private var currentSessionID: UUID = UUID()

    /// Chunk URLs per output, keyed by output identity.
    /// Protected by sessionQueue.
    private var chunkLists: [ObjectIdentifier: [URL]] = [:]

    private var saveDestination: SaveDestination = .documents
    private var showInFiles: Bool = true
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Lock-guarded flag checked by delegate to decide whether to start a new chunk.
    private let recordingLock = NSLock()
    private nonisolated(unsafe) var _shouldContinueRecording: Bool = false

    private var shouldContinueRecording: Bool {
        get { recordingLock.withLock { _shouldContinueRecording } }
        set { recordingLock.withLock { _shouldContinueRecording = newValue } }
    }

    /// Count of outputs that have finished their current chunk.
    private var finishedOutputCount: Int = 0

    /// Ensures mergeAndSaveAll is only called once per stop cycle.
    private var hasMerged: Bool = false

    /// Continuation to signal when all outputs have finished stopping.
    private var stopContinuation: CheckedContinuation<Void, Never>?

    private let chunkDuration: CMTime = CMTime(seconds: 3, preferredTimescale: 600)

    // MARK: - Location

    private let locationManager: CLLocationManager = {
        let mgr = CLLocationManager()
        mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
        mgr.distanceFilter = 100
        return mgr
    }()
    private var recordingLocation: CLLocation?

    // MARK: - Storage directories

    var storageDirectory: URL {
        let fm = FileManager.default
        let baseDir: URL
        if showInFiles {
            baseDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        } else {
            baseDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        }
        if !fm.fileExists(atPath: baseDir.path) {
            try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }
        return baseDir
    }

    var chunksDirectory: URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stealth-recorder-chunks", isDirectory: true)
        if !FileManager.default.fileExists(atPath: tmp.path) {
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        }
        return tmp
    }

    // MARK: - Public API

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func startRecording(action: RecordingAction, includeLocation: Bool) async throws {
        guard !isRecording else { return }
        try await requestCapturePermissions(for: action)
        guard UIApplication.shared.applicationState != .background else { throw CancellationError() }
        try await configureAndStart(action: action, settings: RecorderSettings.load(), includeLocation: includeLocation)
    }

    /// Stops chunk rotation, waits for delegates to finalize, merges, and saves.
    func stopRecordingAndFinalize() async {
        wasRecordingBeforeBackground = isRecording
        guard isRecording else { return }

        shouldContinueRecording = false

        // Wait on sessionQueue for active outputs to finish their current recording
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                self.finishedOutputCount = 0
                self.stopContinuation = cont

                for output in self.activeOutputs {
                    output.stopRecording()
                }

                // Safety timeout: resume after 2 seconds even if an output callback is dropped
                self.sessionQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    if let c = self.stopContinuation {
                        self.stopContinuation = nil
                        c.resume()
                    }
                }
            }
        }

        await mergeAndSaveAll()
        await teardownSession()
    }

    // MARK: - Orphan recovery

    func recoverOrphanedChunks() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: chunksDirectory, includingPropertiesForKeys: nil
        ) else { return }

        let movFiles = contents.filter { $0.pathExtension == "mov" && $0.lastPathComponent.contains("-chunk") }
        guard !movFiles.isEmpty else { return }

        let groups = Dictionary(grouping: movFiles) { url -> String in
            let name = url.deletingPathExtension().lastPathComponent
            if let range = name.range(of: "-chunk", options: .backwards) {
                return String(name[..<range.lowerBound])
            }
            return name
        }

        Task {
            for (groupKey, chunkURLs) in groups {
                let sorted = chunkURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard let merged = await mergeChunks(sorted) else { continue }

                let destinationURL = storageDirectory.appendingPathComponent(
                    "recovered-\(groupKey)-\(UUID().uuidString.prefix(6)).mov"
                )

                do {
                    if fm.fileExists(atPath: destinationURL.path) {
                        try fm.removeItem(at: destinationURL)
                    }
                    if merged == sorted[0] {
                        try fm.copyItem(at: merged, to: destinationURL)
                    } else {
                        try fm.moveItem(at: merged, to: destinationURL)
                    }

                    for url in sorted { try? fm.removeItem(at: url) }
                    if merged != sorted[0] { try? fm.removeItem(at: merged) }

                    let action: RecordingAction = groupKey.contains("audio") ? .audio :
                        (groupKey.contains("front") ? .frontVideo : .backVideo)

                    await finalizeRecording(fileURL: destinationURL, startedAt: Date(), action: action)
                    debugPrint("Recovered orphaned recording: \(destinationURL.lastPathComponent)")
                } catch {
                    debugPrint("Failed to recover orphaned chunks: \(error)")
                }
            }
        }
    }

    // MARK: - Permissions

    private func requestCapturePermissions(for action: RecordingAction) async throws {
        let audioAccess = await AVCaptureDevice.requestAccess(for: .audio)
        guard audioAccess else {
            throw CameraConfigurationError.permissionDenied
        }

        if action != .audio {
            let videoAccess = await AVCaptureDevice.requestAccess(for: .video)
            guard videoAccess else {
                throw CameraConfigurationError.permissionDenied
            }
        }
    }

    // MARK: - Volume → action mapping

    private func configureAndStart(action: RecordingAction, settings: RecorderSettings, includeLocation: Bool) async throws {
        currentAction = action
        saveDestination = settings.saveDestination
        showInFiles = settings.showInFiles

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true)

        recordingLocation = nil
        if includeLocation {
            locationManager.delegate = self
            locationManager.requestWhenInUseAuthorization()
            locationManager.requestLocation()
        }

        let sessionID = UUID()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                do {
                    let configured = try self.makeSession(for: action, settings: settings)
                    self.activeSession = configured.session
                    self.activeOutputs = configured.outputs
                    self.currentOutputLabels = configured.outputLabels
                    self.currentSessionID = sessionID

                    for output in configured.outputs {
                        self.chunkLists[ObjectIdentifier(output)] = []
                    }

                    self.shouldContinueRecording = true
                    self.finishedOutputCount = 0
                    self.hasMerged = false

                    configured.session.startRunning()

                    for output in configured.outputs {
                        do {
                            try self.startChunk(on: output)
                        } catch {
                            debugPrint("Failed to start chunk: \(error)")
                        }
                    }

                    Task { @MainActor in
                        self.isRecording = true
                        self.recordingStartedAt = Date()
                        self.wasRecordingBeforeBackground = false
                    }

                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Chunk lifecycle

    private func startChunk(on output: AVCaptureMovieFileOutput) throws {
        let outputID = ObjectIdentifier(output)
        let chunkIndex = chunkLists[outputID]?.count ?? 0
        let label = currentOutputLabels[outputID] ?? (currentAction?.rawValue ?? "rec")
        let sessionPrefix = currentSessionID.uuidString.prefix(8)
        let filename = "\(sessionPrefix)-\(label)-chunk\(String(format: "%04d", chunkIndex)).mov"
        let url = chunksDirectory.appendingPathComponent(filename)

        try? FileManager.default.removeItem(at: url)

        output.maxRecordedDuration = chunkDuration
        output.startRecording(to: url, recordingDelegate: self)
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let outputID = ObjectIdentifier(output)
        sessionQueue.async { [weak self] in
            self?.handleChunkFinished(outputID: outputID, url: outputFileURL, error: error)
        }
    }

    private func handleChunkFinished(outputID: ObjectIdentifier, url: URL, error: Error?) {
        var isSuccess = (error == nil)
        if let error = error as NSError? {
            // AVError.maximumDurationReached is expected and normal when chunks rotate!
            if let successfullyFinished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool {
                isSuccess = successfullyFinished
            } else if error.code == AVError.maximumDurationReached.rawValue {
                isSuccess = true
            }
        }

        // Validate that the file actually exists and contains data
        if isSuccess && FileManager.default.fileExists(atPath: url.path) {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if fileSize > 0 {
                chunkLists[outputID, default: []].append(url)
            } else {
                debugPrint("Chunk completed with 0 bytes: \(url.lastPathComponent)")
            }
        } else if let error {
            debugPrint("Chunk recording failed: \(error.localizedDescription)")
        }

        if shouldContinueRecording {
            guard let output = activeOutputs.first(where: { ObjectIdentifier($0) == outputID }) else { return }
            do {
                try startChunk(on: output)
            } catch {
                debugPrint("Failed to start next chunk: \(error)")
            }
        } else {
            finishedOutputCount += 1
            if finishedOutputCount >= activeOutputs.count {
                if let cont = stopContinuation {
                    stopContinuation = nil
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Merge & Finalize

    private func mergeAndSaveAll() async {
        guard !hasMerged else { return }
        hasMerged = true

        endBackgroundTask()

        guard let action = currentAction else { return }

        // Snapshot chunk lists from sessionQueue
        let snapshot: [(AVCaptureMovieFileOutput, String, [URL])] = await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(returning: []); return }
                let snap = self.activeOutputs.compactMap { output -> (AVCaptureMovieFileOutput, String, [URL])? in
                    let oid = ObjectIdentifier(output)
                    guard let chunks = self.chunkLists[oid], !chunks.isEmpty else { return nil }
                    let label = self.currentOutputLabels[oid] ?? action.rawValue
                    return (output, label, chunks)
                }
                cont.resume(returning: snap)
            }
        }

        let startedAt = recordingStartedAt ?? Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = dateFormatter.string(from: startedAt)

        for (_, label, chunks) in snapshot {
            guard let mergedURL = await mergeChunks(chunks) else { continue }

            let destinationURL = storageDirectory.appendingPathComponent(
                "\(label)-\(timestamp)-\(UUID().uuidString.prefix(6)).mov"
            )

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                if mergedURL == chunks[0] {
                    try FileManager.default.copyItem(at: mergedURL, to: destinationURL)
                } else {
                    try FileManager.default.moveItem(at: mergedURL, to: destinationURL)
                }
            } catch {
                debugPrint("Failed to move merged file: \(error)")
                continue
            }

            // Clean up temporary chunks
            for chunk in chunks {
                try? FileManager.default.removeItem(at: chunk)
            }
            if mergedURL != chunks[0] {
                try? FileManager.default.removeItem(at: mergedURL)
            }

            await finalizeRecording(
                fileURL: destinationURL,
                startedAt: startedAt,
                action: action
            )
        }

        // Clear chunk lists on sessionQueue
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.chunkLists.removeAll()
                self?.currentOutputLabels.removeAll()
                cont.resume()
            }
        }

        await MainActor.run {
            isRecording = false
            recordingStartedAt = nil
        }
    }

    private func mergeChunks(_ chunkURLs: [URL]) async -> URL? {
        guard !chunkURLs.isEmpty else { return nil }
        if chunkURLs.count == 1 { return chunkURLs[0] }

        let composition = AVMutableComposition()
        let firstAsset = AVURLAsset(url: chunkURLs[0])

        let firstVideoTracks = (try? await firstAsset.loadTracks(withMediaType: .video)) ?? []
        let firstAudioTracks = (try? await firstAsset.loadTracks(withMediaType: .audio)) ?? []

        var compVideoTrack: AVMutableCompositionTrack?
        var compAudioTrack: AVMutableCompositionTrack?

        if let firstVideo = firstVideoTracks.first {
            compVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            if let transform = try? await firstVideo.load(.preferredTransform) {
                compVideoTrack?.preferredTransform = transform
            }
        }

        if !firstAudioTracks.isEmpty {
            compAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }

        if compVideoTrack == nil && compAudioTrack == nil {
            return chunkURLs[0]
        }

        var cursor = CMTime.zero
        for chunkURL in chunkURLs {
            let asset = AVURLAsset(url: chunkURL)
            guard let duration = try? await asset.load(.duration), duration > .zero else {
                continue
            }
            let timeRange = CMTimeRange(start: .zero, duration: duration)

            if let compVideoTrack {
                if let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first {
                    do {
                        try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: cursor)
                    } catch {
                        debugPrint("Video track merge error for \(chunkURL.lastPathComponent): \(error)")
                    }
                }
            }

            if let compAudioTrack {
                if let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first {
                    do {
                        try compAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: cursor)
                    } catch {
                        debugPrint("Audio track merge error for \(chunkURL.lastPathComponent): \(error)")
                    }
                }
            }

            cursor = CMTimeAdd(cursor, duration)
        }

        guard cursor > .zero else { return chunkURLs[0] }

        let outputURL = chunksDirectory.appendingPathComponent("merged-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: outputURL)

        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality, AVAssetExportPresetMediumQuality]
        for preset in presets {
            guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
                continue
            }
            exporter.outputURL = outputURL
            exporter.outputFileType = .mov
            exporter.shouldOptimizeForNetworkUse = false

            await exporter.export()

            if exporter.status == .completed && FileManager.default.fileExists(atPath: outputURL.path) {
                return outputURL
            }
            try? FileManager.default.removeItem(at: outputURL)
        }

        debugPrint("Export session failed for all presets, falling back to first chunk")
        return chunkURLs[0]
    }

    private func finalizeRecording(fileURL: URL, startedAt: Date, action: RecordingAction) async {
        let duration = await durationOfAsset(at: fileURL)

        await saveRecordingEntry(
            fileURL: fileURL,
            startedAt: startedAt,
            duration: duration,
            location: recordingLocation,
            action: action
        )

        if saveDestination == .photoLibrary {
            if action == .audio {
                if let videoURL = await convertAudioToVideo(fileURL) {
                    await saveToPhotoLibrary(videoURL)
                    try? FileManager.default.removeItem(at: videoURL)
                }
            } else {
                await saveToPhotoLibrary(fileURL)
            }
        }
    }

    private func durationOfAsset(at url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? max(0, seconds) : 0
        } catch {
            return 0
        }
    }

    private func saveRecordingEntry(
        fileURL: URL,
        startedAt: Date,
        duration: TimeInterval,
        location: CLLocation?,
        action: RecordingAction?
    ) async {
        await MainActor.run {
            guard let context = modelContext else {
                debugPrint("CameraManager: modelContext is nil, entry not inserted!")
                return
            }
            let entry = RecordingEntry(
                fileName: fileURL.lastPathComponent,
                filePath: fileURL.path,
                createdAt: startedAt,
                duration: duration,
                latitude: location?.coordinate.latitude,
                longitude: location?.coordinate.longitude,
                actionType: action?.rawValue ?? "unknown"
            )
            context.insert(entry)
            do {
                try context.save()
                debugPrint("Saved RecordingEntry: \(entry.fileName), duration: \(entry.formattedDuration)")
            } catch {
                debugPrint("SwiftData save failed: \(error)")
            }
        }
    }

    private func saveToPhotoLibrary(_ fileURL: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    debugPrint("Photo library authorization not granted (status: \(status.rawValue))")
                    cont.resume()
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: fileURL, options: nil)
                } completionHandler: { success, error in
                    if success {
                        debugPrint("Successfully saved to Photo Library: \(fileURL.lastPathComponent)")
                    } else if let error {
                        debugPrint("Photo library save failed: \(error.localizedDescription)")
                    }
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Audio-to-video conversion (Photos compatibility)

    private func convertAudioToVideo(_ audioURL: URL) async -> URL? {
        let asset = AVURLAsset(url: audioURL)
        guard let duration = try? await asset.load(.duration), duration > .zero else {
            return nil
        }

        let composition = AVMutableComposition()

        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: audioTrack,
                at: .zero
            )
        }

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }

        let tempDir = FileManager.default.temporaryDirectory
        let blackVideoURL = tempDir.appendingPathComponent("blackframe-\(UUID().uuidString).mp4")

        guard let blackAsset = await writeImageAsVideo(duration: duration, outputURL: blackVideoURL),
              let blackTrack = try? await blackAsset.loadTracks(withMediaType: .video).first else {
            return nil
        }

        try? videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: blackTrack,
            at: .zero
        )

        let outputURL = tempDir.appendingPathComponent("audio-as-video-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetMediumQuality
        ) else { return nil }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false

        await exporter.export()
        try? FileManager.default.removeItem(at: blackVideoURL)

        if exporter.status == .completed && FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }
        debugPrint("Audio-to-video export failed: \(exporter.error?.localizedDescription ?? "unknown")")
        return nil
    }

    private func writeImageAsVideo(duration: CMTime, outputURL: URL) async -> AVURLAsset? {
        try? FileManager.default.removeItem(at: outputURL)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return nil }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 480,
            AVVideoHeightKey: 480
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 480,
                kCVPixelBufferHeightKey as String: 480
            ]
        )

        guard writer.canAdd(videoInput) else { return nil }
        writer.add(videoInput)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        var pb: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 480, 480,
            kCVPixelFormatType_32ARGB,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pb
        )

        if let pb {
            CVPixelBufferLockBaseAddress(pb, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(pb) {
                memset(baseAddress, 0, 480 * 480 * 4)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])

            let frameRate = 2
            let totalSeconds = max(1, Int(ceil(CMTimeGetSeconds(duration))))
            let totalFrames = totalSeconds * frameRate

            for frame in 0...totalFrames {
                let frameTime = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))
                if frameTime > duration {
                    adaptor.append(pb, withPresentationTime: duration)
                    break
                }
                while !videoInput.isReadyForMoreMediaData {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                adaptor.append(pb, withPresentationTime: frameTime)
            }
        }

        videoInput.markAsFinished()
        await writer.finishWriting()

        if writer.status == .completed && FileManager.default.fileExists(atPath: outputURL.path) {
            return AVURLAsset(url: outputURL)
        }
        return nil
    }

    // MARK: - Teardown

    private func teardownSession() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.activeSession?.stopRunning()
                self?.activeSession = nil
                self?.activeOutputs.removeAll()
                self?.currentOutputLabels.removeAll()
                cont.resume()
            }
        }
        locationManager.stopUpdatingLocation()
    }

    private func endBackgroundTask() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location is optional. Capture and finalization continue when no fix is available.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            recordingLocation = locations.last
        }
    }

    // MARK: - Session factories

    private nonisolated func makeSession(for action: RecordingAction, settings: RecorderSettings) throws -> ConfiguredCaptureSession {
        switch action {
        case .audio:     return try makeAudioOnlySession(settings: settings)
        case .frontVideo: return try makeSingleCameraSession(position: .front, settings: settings)
        case .backVideo:  return try makeSingleCameraSession(position: .back, settings: settings)
        case .multiCam:   return try makeMultiCamSession(settings: settings)
        }
    }

    private nonisolated func makeAudioOnlySession(settings: RecorderSettings) throws -> ConfiguredCaptureSession {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        applyPreset(settings.videoQuality.sessionPreset, to: session)

        let micInput = try makeMicrophoneInput()
        guard session.canAddInput(micInput) else { throw CameraConfigurationError.cannotAddInput("microphone") }
        session.addInput(micInput)

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else { throw CameraConfigurationError.cannotAddOutput("audio movie file output") }
        session.addOutput(output)

        return ConfiguredCaptureSession(
            session: session,
            outputs: [output],
            outputLabels: [ObjectIdentifier(output): "audio"]
        )
    }

    private nonisolated func makeSingleCameraSession(position: AVCaptureDevice.Position, settings: RecorderSettings) throws -> ConfiguredCaptureSession {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        applyPreset(settings.videoQuality.sessionPreset, to: session)

        let camInput = try makeCameraInput(position: position)
        guard session.canAddInput(camInput) else {
            throw CameraConfigurationError.cannotAddInput(position == .front ? "front camera" : "back camera")
        }
        session.addInput(camInput)

        if let micInput = try? makeMicrophoneInput(), session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            throw CameraConfigurationError.cannotAddOutput("movie file output")
        }
        session.addOutput(output)

        if let videoConnection = output.connection(with: .video) {
            if videoConnection.isVideoOrientationSupported {
                videoConnection.videoOrientation = .portrait
            }
            if position == .front && videoConnection.isVideoMirroringSupported {
                videoConnection.isVideoMirrored = true
            }
        }

        let label = (position == .front) ? "front" : "back"
        return ConfiguredCaptureSession(
            session: session,
            outputs: [output],
            outputLabels: [ObjectIdentifier(output): label]
        )
    }

    private nonisolated func makeMultiCamSession(settings: RecorderSettings) throws -> ConfiguredCaptureSession {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            return try makeSingleCameraSession(position: .back, settings: settings)
        }

        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        applyPreset(settings.videoQuality.sessionPreset, to: session)

        let frontInput = try makeCameraInput(position: .front)
        let backInput = try makeCameraInput(position: .back)

        guard session.canAddInput(frontInput) else { throw CameraConfigurationError.cannotAddInput("front camera") }
        session.addInput(frontInput)
        guard session.canAddInput(backInput) else { throw CameraConfigurationError.cannotAddInput("back camera") }
        session.addInput(backInput)

        if let micInput = try? makeMicrophoneInput(), session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        let frontOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(frontOutput) else { throw CameraConfigurationError.cannotAddOutput("front movie file output") }
        session.addOutput(frontOutput)

        if let frontConn = frontOutput.connection(with: .video) {
            if frontConn.isVideoOrientationSupported { frontConn.videoOrientation = .portrait }
            if frontConn.isVideoMirroringSupported { frontConn.isVideoMirrored = true }
        }

        let backOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(backOutput) else { throw CameraConfigurationError.cannotAddOutput("back movie file output") }
        session.addOutput(backOutput)

        if let backConn = backOutput.connection(with: .video) {
            if backConn.isVideoOrientationSupported { backConn.videoOrientation = .portrait }
        }

        return ConfiguredCaptureSession(
            session: session,
            outputs: [frontOutput, backOutput],
            outputLabels: [
                ObjectIdentifier(frontOutput): "front",
                ObjectIdentifier(backOutput): "back"
            ]
        )
    }

    private nonisolated func applyPreset(_ preset: AVCaptureSession.Preset, to session: AVCaptureSession) {
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        }
    }

    private nonisolated func makeMicrophoneInput() throws -> AVCaptureDeviceInput {
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            throw CameraConfigurationError.microphoneUnavailable
        }
        do { return try AVCaptureDeviceInput(device: mic) }
        catch { throw CameraConfigurationError.cannotCreateDeviceInput(error.localizedDescription) }
    }

    private nonisolated func makeCameraInput(position: AVCaptureDevice.Position) throws -> AVCaptureDeviceInput {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        guard let cam = discovery.devices.first else {
            throw CameraConfigurationError.cameraUnavailable(position)
        }
        do { return try AVCaptureDeviceInput(device: cam) }
        catch { throw CameraConfigurationError.cannotCreateDeviceInput(error.localizedDescription) }
    }
}

// MARK: - Error

extension CameraManager {
    enum CameraConfigurationError: LocalizedError, Sendable {
        case permissionDenied
        case microphoneUnavailable
        case cameraUnavailable(AVCaptureDevice.Position)
        case cannotCreateDeviceInput(String)
        case cannotAddInput(String)
        case cannotAddOutput(String)
        case multiCamUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "L'accès à la caméra ou au micro a été refusé."
            case .microphoneUnavailable:
                "Aucun microphone n'est disponible sur cet appareil."
            case .cameraUnavailable(let position):
                "La caméra \(position == .front ? "avant" : "arrière") n'est pas disponible."
            case .cannotCreateDeviceInput(let reason):
                "Impossible de créer l'entrée de capture : \(reason)"
            case .cannotAddInput(let name):
                "Impossible d'ajouter l'entrée : \(name)"
            case .cannotAddOutput(let name):
                "Impossible d'ajouter la sortie : \(name)"
            case .multiCamUnavailable:
                "L'enregistrement multi-caméra n'est pas supporté sur cet appareil."
            }
        }
    }
}

// MARK: - Configured session helper

private nonisolated struct ConfiguredCaptureSession: Sendable {
    let session: AVCaptureSession
    let outputs: [AVCaptureMovieFileOutput]
    let outputLabels: [ObjectIdentifier: String]
}
