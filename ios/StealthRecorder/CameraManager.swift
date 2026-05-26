import AVFoundation
import CoreLocation
import Foundation
import Photos
import SwiftData
import UIKit

/// Manages the entire recording lifecycle with chunk-based capture for resilience.
///
/// Records in 3-second chunks using `AVCaptureMovieFileOutput.maxRecordedDuration`.
/// Each chunk is saved to a temporary directory immediately upon completion.
/// When recording stops (user action, backgrounding, or termination), chunks are
/// merged into a final file and saved to the configured destination.
/// Orphaned chunks from a previous kill are recovered on next launch.
@Observable
final class CameraManager: NSObject, AVCaptureFileOutputRecordingDelegate, CLLocationManagerDelegate {

    // MARK: - Public observable state

    private(set) var isRecording: Bool = false
    private(set) var recordingStartedAt: Date?
    private(set) var wasRecordingBeforeBackground: Bool = false
    private var modelContext: ModelContext?

    // MARK: - Private capture state

    private let sessionQueue: DispatchQueue = DispatchQueue(
        label: "app.rork.stealth-recorder.session", qos: .userInitiated
    )

    private var activeSession: AVCaptureSession?
    private var activeOutputs: [AVCaptureMovieFileOutput] = []

    /// Chunk URLs per output, keyed by output identity.
    private var chunkLists: [ObjectIdentifier: [URL]] = [:]

    /// Holds the single output for audio-only / single-camera sessions.
    private var primaryOutput: AVCaptureMovieFileOutput? { activeOutputs.first }

    private var saveDestination: SaveDestination = .documents
    private var showInFiles: Bool = true
    private var currentAction: RecordingAction?
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Lock-guarded flag checked by the delegate to decide whether to start a new chunk.
    private let recordingLock = NSLock()
    private nonisolated(unsafe) var _shouldContinueRecording: Bool = false

    private var shouldContinueRecording: Bool {
        get { recordingLock.withLock { _shouldContinueRecording } }
        set { recordingLock.withLock { _shouldContinueRecording = newValue } }
    }

    /// Count of outputs that have finished their current chunk (for coordinated stop).
    private nonisolated(unsafe) var _finishedOutputCount: Int = 0
    private var finishedOutputCount: Int {
        get { recordingLock.withLock { _finishedOutputCount } }
        set { recordingLock.withLock { _finishedOutputCount = newValue } }
    }

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

    /// Directory respecting the showInFiles setting.
    /// When true: Documents (visible in Files app). When false: Application Support (private).
    private var storageDirectory: URL {
        if showInFiles {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        } else {
            let privateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Recordings", isDirectory: true)
            try? FileManager.default.createDirectory(at: privateDir, withIntermediateDirectories: true)
            return privateDir
        }
    }

    private var chunksDirectory: URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stealth-recorder-chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - Public API

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func startFromCurrentSystemVolume() {
        Task {
            do {
                try await requestCapturePermissions()
                let settings = RecorderSettings.load()
                saveDestination = settings.saveDestination
                showInFiles = settings.showInFiles
                let volume = AVAudioSession.sharedInstance().outputVolume
                let action = try recordingAction(for: volume, settings: settings)
                try await configureAndStart(action: action, settings: settings)
            } catch {
                debugPrint("CameraManager configuration failed: \(error.localizedDescription)")
            }
        }
    }

    func stopRecordingAndFinalize() async {
        wasRecordingBeforeBackground = isRecording
        shouldContinueRecording = false
        finishedOutputCount = 0

        // Stop all outputs
        for output in activeOutputs {
            output.stopRecording()
        }

        // Wait a short moment for delegate callbacks
        try? await Task.sleep(for: .seconds(2))

        await mergeAndSaveAll()
        await teardownSession()
    }

    // MARK: - Orphan recovery

    func recoverOrphanedChunks() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: chunksDirectory, includingPropertiesForKeys: nil
        ) else { return }

        let movFiles = contents.filter { $0.pathExtension == "mov" }
        guard !movFiles.isEmpty else { return }

        // Group by session prefix (everything before the chunk index)
        let groups = Dictionary(grouping: movFiles) { url -> String in
            let name = url.deletingPathExtension().lastPathComponent
            // Remove the trailing "-chunkNNN"
            if let range = name.range(of: "-chunk", options: .backwards) {
                return String(name[..<range.lowerBound])
            }
            return name
        }

        Task {
            for (_, chunkURLs) in groups {
                let sorted = chunkURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard let merged = await mergeChunks(sorted) else { continue }
                await finalizeRecording(fileURL: merged, startedAt: Date())
                for url in sorted { try? fm.removeItem(at: url) }
            }
        }
    }

    // MARK: - Permissions

    private func requestCapturePermissions() async throws {
        async let videoAccess = AVCaptureDevice.requestAccess(for: .video)
        async let audioAccess = AVCaptureDevice.requestAccess(for: .audio)

        guard await videoAccess, await audioAccess else {
            throw CameraConfigurationError.permissionDenied
        }
    }

    // MARK: - Volume → action

    private func recordingAction(for volume: Float, settings: RecorderSettings) throws -> RecordingAction {
        let step: Int
        switch volume {
        case 0.0:                                step = 0
        case 0.01...0.07:                        step = 1
        case 0.08...0.13:                        step = 2
        case 0.14...0.19:                        step = 3
        default: throw CameraConfigurationError.unsupportedVolumeStep(volume)
        }

        guard let action = settings.stepActions[step] else {
            throw CameraConfigurationError.unsupportedVolumeStep(volume)
        }
        return action
    }

    // MARK: - Session configuration

    private func configureAndStart(action: RecordingAction, settings: RecorderSettings) async throws {
        currentAction = action

        // Configure audio session for background recording
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
        try audioSession.setActive(true)

        // Start location
        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()

        // Build session synchronously on session queue
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                do {
                    let configured = try self.makeSession(for: action, settings: settings)
                    configured.session.startRunning()
                    self.activeSession = configured.session
                    self.activeOutputs = configured.outputs

                    // Initialize chunk tracking
                    for output in configured.outputs {
                        self.chunkLists[ObjectIdentifier(output)] = []
                    }

                    self.shouldContinueRecording = true
                    self.finishedOutputCount = 0

                    // Start background task
                    self.bgTaskID = UIApplication.shared.beginBackgroundTask(
                        withName: "StealthRecorder.Chunks"
                    ) { [weak self] in
                        self?.endBackgroundTask()
                    }

                    // Start first chunk on all outputs
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
        let sessionPrefix = currentAction?.rawValue ?? "rec"
        let filename = "\(sessionPrefix)-chunk\(String(format: "%03d", chunkIndex)).mov"
        let url = chunksDirectory.appendingPathComponent(filename)

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

        Task { @MainActor in
            guard let self = self as? CameraManager else { return }
            self.handleChunkFinished(outputID: outputID, url: outputFileURL, error: error)
        }
    }

    private func handleChunkFinished(outputID: ObjectIdentifier, url: URL, error: Error?) {
        if let error {
            debugPrint("Chunk recording error: \(error.localizedDescription)")
        } else {
            chunkLists[outputID, default: []].append(url)
        }

        if shouldContinueRecording {
            // Start next chunk
            guard let output = activeOutputs.first(where: { ObjectIdentifier($0) == outputID }) else { return }
            do {
                try startChunk(on: output)
            } catch {
                debugPrint("Failed to start next chunk: \(error)")
            }
        } else {
            finishedOutputCount += 1
            if finishedOutputCount >= activeOutputs.count {
                // All outputs done – merge and save
                Task {
                    await mergeAndSaveAll()
                    await teardownSession()
                }
            }
        }
    }

    // MARK: - Merge

    private func mergeAndSaveAll() async {
        endBackgroundTask()

        guard let action = currentAction else { return }

        for output in activeOutputs {
            let outputID = ObjectIdentifier(output)
            guard let chunks = chunkLists[outputID], !chunks.isEmpty else { continue }

            // Label each output: for multi-cam, distinguish front/back
            let label: String = {
                if activeOutputs.count > 1 {
                    if let videoConnection = output.connections.first(where: {
                        $0.inputPorts.contains(where: { $0.mediaType == .video })
                    }) {
                        return videoConnection.isVideoMirrored ? "front" : "back"
                    }
                }
                return action.rawValue
            }()

            guard let mergedURL = await mergeChunks(chunks) else { continue }

            let destinationURL = storageDirectory.appendingPathComponent(
                "\(label)-\(UUID().uuidString).mov"
            )

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: mergedURL, to: destinationURL)
            } catch {
                debugPrint("Failed to move merged file: \(error)")
                continue
            }

            // Clean up chunks
            for chunk in chunks {
                try? FileManager.default.removeItem(at: chunk)
            }

            await finalizeRecording(
                fileURL: destinationURL,
                startedAt: recordingStartedAt ?? Date()
            )
        }

        chunkLists.removeAll()
        await MainActor.run {
            isRecording = false
            recordingStartedAt = nil
        }
    }

    private func mergeChunks(_ chunkURLs: [URL]) async -> URL? {
        guard !chunkURLs.isEmpty else { return nil }
        if chunkURLs.count == 1 { return chunkURLs[0] }

        let composition = AVMutableComposition()

        // Add all tracks from first chunk as templates
        guard let firstAsset = try? AVURLAsset(url: chunkURLs[0]) else { return chunkURLs[0] }

        var compositionTracks: [AVMediaType: AVMutableCompositionTrack] = [:]
        for track in firstAsset.tracks {
            guard let compTrack = composition.addMutableTrack(
                withMediaType: track.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            compositionTracks[track.mediaType] = compTrack
        }

        // Insert each chunk
        var cursor = CMTime.zero
        for chunkURL in chunkURLs {
            guard let asset = try? AVURLAsset(url: chunkURL) else { continue }
            let duration = asset.duration
            for track in asset.tracks {
                guard let compTrack = compositionTracks[track.mediaType] else { continue }
                do {
                    try compTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: duration),
                        of: track,
                        at: cursor
                    )
                } catch {
                    debugPrint("Merge insert error: \(error)")
                }
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        // Export
        let outputURL = chunksDirectory.appendingPathComponent("merged-\(UUID().uuidString).mov")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else { return chunkURLs[0] }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false

        await exporter.export()

        if exporter.status == .completed {
            return outputURL
        }
        debugPrint("Merge export failed: \(exporter.error?.localizedDescription ?? "unknown")")
        return chunkURLs[0] // Fallback: return first chunk
    }

    // MARK: - Finalize & save

    private func finalizeRecording(fileURL: URL, startedAt: Date) async {
        let duration = await durationOfAsset(at: fileURL)

        // Save metadata via SwiftData
        await saveRecordingEntry(
            fileURL: fileURL,
            startedAt: startedAt,
            duration: duration,
            location: recordingLocation,
            action: currentAction
        )

        // If destination is photo library, save there too.
        // Audio-only files get converted to video (black frame) for Photos compatibility.
        // Multi-cam already saves each output as a separate file.
        if saveDestination == .photoLibrary {
            if currentAction == .audio {
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
            return CMTimeGetSeconds(duration)
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
        guard let context = modelContext else { return }
        let entry = RecordingEntry(
            fileName: fileURL.lastPathComponent,
            filePath: fileURL.path,
            createdAt: startedAt,
            duration: duration,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            actionType: action?.rawValue ?? "unknown"
        )
        await MainActor.run {
            context.insert(entry)
            try? context.save()
        }
    }

    private func saveToPhotoLibrary(_ fileURL: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    cont.resume()
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: fileURL, options: nil)
                } completionHandler: { success, error in
                    if !success, let error {
                        debugPrint("Photo library save failed: \(error.localizedDescription)")
                    }
                    cont.resume()
                }
            }
        }
    }

    // MARK: - Audio-to-video conversion (Photos compatibility)

    /// Converts an audio-only .mov to a video with a black frame so Photos can play it.
    private func convertAudioToVideo(_ audioURL: URL) async -> URL? {
        let asset = AVURLAsset(url: audioURL)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            return nil
        }

        let composition = AVMutableComposition()

        // Copy audio track
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

        // Create a black video track
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }

        // Generate a black frame video asset matching the audio duration
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
        videoTrack.preferredTransform = blackTrack.preferredTransform

        // Export composition
        let outputURL = tempDir.appendingPathComponent("audio-as-video-\(UUID().uuidString).mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetMediumQuality
        ) else { return nil }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false

        await exporter.export()

        if exporter.status == .completed {
            return outputURL
        }
        debugPrint("Audio-to-video conversion failed: \(exporter.error?.localizedDescription ?? "unknown")")
        return nil
    }

    /// Writes a black frame as an mp4 video of the given duration.
    private func writeImageAsVideo(duration: CMTime, outputURL: URL) async -> AVURLAsset? {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return nil }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640,
            AVVideoHeightKey: 480
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 640,
                kCVPixelBufferHeightKey as String: 480
            ]
        )

        guard writer.canAdd(videoInput) else { return nil }
        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Write a black pixel buffer at time zero
        let semaphore = DispatchSemaphore(value: 0)
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "video-writer")) {
            if videoInput.isReadyForMoreMediaData {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(
                    kCFAllocatorDefault, 640, 480,
                    kCVPixelFormatType_32ARGB,
                    [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                    &pb
                )
                if let pb {
                    CVPixelBufferLockBaseAddress(pb, [])
                    if let baseAddress = CVPixelBufferGetBaseAddress(pb) {
                        memset(baseAddress, 0, 640 * 480 * 4)
                    }
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    adaptor.append(pb, withPresentationTime: .zero)
                }
                videoInput.markAsFinished()
                semaphore.signal()
            }
        }
        semaphore.wait()

        await writer.finishWriting()

        if writer.status == .completed {
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
        try applyPreset(settings.videoQuality.sessionPreset, to: session)

        let micInput = try makeMicrophoneInput()
        guard session.canAddInput(micInput) else { throw CameraConfigurationError.cannotAddInput("microphone") }
        session.addInput(micInput)

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else { throw CameraConfigurationError.cannotAddOutput("audio movie file output") }
        session.addOutput(output)

        return ConfiguredCaptureSession(session: session, outputs: [output])
    }

    private nonisolated func makeSingleCameraSession(position: AVCaptureDevice.Position, settings: RecorderSettings) throws -> ConfiguredCaptureSession {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try applyPreset(settings.videoQuality.sessionPreset, to: session)

        let camInput = try makeCameraInput(position: position)
        guard session.canAddInput(camInput) else { throw CameraConfigurationError.cannotAddInput(position == .front ? "front camera" : "back camera") }
        session.addInput(camInput)

        let micInput = try makeMicrophoneInput()
        guard session.canAddInput(micInput) else { throw CameraConfigurationError.cannotAddInput("microphone") }
        session.addInput(micInput)

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else { throw CameraConfigurationError.cannotAddOutput("movie file output") }
        session.addOutput(output)

        return ConfiguredCaptureSession(session: session, outputs: [output])
    }

    private nonisolated func makeMultiCamSession(settings: RecorderSettings) throws -> ConfiguredCaptureSession {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { throw CameraConfigurationError.multiCamUnavailable }

        let session = AVCaptureMultiCamSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try applyPreset(settings.videoQuality.sessionPreset, to: session)

        let frontInput = try makeCameraInput(position: .front)
        let backInput = try makeCameraInput(position: .back)
        let micInput = try makeMicrophoneInput()

        guard session.canAddInput(frontInput) else { throw CameraConfigurationError.cannotAddInput("front camera") }
        session.addInput(frontInput)
        guard session.canAddInput(backInput) else { throw CameraConfigurationError.cannotAddInput("back camera") }
        session.addInput(backInput)
        guard session.canAddInput(micInput) else { throw CameraConfigurationError.cannotAddInput("microphone") }
        session.addInput(micInput)

        let frontOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(frontOutput) else { throw CameraConfigurationError.cannotAddOutput("front movie file output") }
        session.addOutput(frontOutput)

        let backOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(backOutput) else { throw CameraConfigurationError.cannotAddOutput("back movie file output") }
        session.addOutput(backOutput)

        return ConfiguredCaptureSession(session: session, outputs: [frontOutput, backOutput])
    }

    private nonisolated func applyPreset(_ preset: AVCaptureSession.Preset, to session: AVCaptureSession) throws {
        guard session.canSetSessionPreset(preset) else {
            throw CameraConfigurationError.cannotApplyPreset(preset.rawValue)
        }
        session.sessionPreset = preset
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
        case unsupportedVolumeStep(Float)
        case microphoneUnavailable
        case cameraUnavailable(AVCaptureDevice.Position)
        case cannotCreateDeviceInput(String)
        case cannotAddInput(String)
        case cannotAddOutput(String)
        case cannotApplyPreset(String)
        case multiCamUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Camera, microphone, or photo library permission was denied."
            case .unsupportedVolumeStep(let volume):
                "No recording action is configured for output volume \(volume)."
            case .microphoneUnavailable: "No microphone capture device is available."
            case .cameraUnavailable(let position):
                "No \(position == .front ? "front" : "back") camera is available."
            case .cannotCreateDeviceInput(let reason):
                "Could not create capture input: \(reason)"
            case .cannotAddInput(let name): "Could not add capture input: \(name)"
            case .cannotAddOutput(let name): "Could not add capture output: \(name)"
            case .cannotApplyPreset(let preset): "Could not apply capture preset: \(preset)"
            case .multiCamUnavailable: "Multi-camera capture is not supported on this device."
            }
        }
    }
}

// MARK: - Configured session helper

private nonisolated struct ConfiguredCaptureSession: Sendable {
    let session: AVCaptureSession
    let outputs: [AVCaptureMovieFileOutput]
}
