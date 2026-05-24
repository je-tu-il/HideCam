import AVFoundation
import Foundation
import Photos

@Observable
final class CameraManager: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let sessionQueue: DispatchQueue = DispatchQueue(label: "app.rork.stealth-recorder.session", qos: .userInitiated)
    private var activeSession: AVCaptureSession?
    private var activeFileOutputs: [AVCaptureFileOutput] = []
    private var saveDestination: SaveDestination = .documents

    enum CameraConfigurationError: LocalizedError, Sendable {
        case permissionDenied
        case unsupportedVolumeStep(Float)
        case microphoneUnavailable
        case cameraUnavailable(AVCaptureDevice.Position)
        case cannotCreateDeviceInput(String)
        case cannotAddInput(String)
        case cannotAddOutput(String)
        case cannotApplyPreset(String)
        case cannotCreateRecordingURL
        case multiCamUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Camera, microphone, or photo library permission was denied."
            case .unsupportedVolumeStep(let volume):
                "No recording action is configured for output volume \(volume)."
            case .microphoneUnavailable:
                "No microphone capture device is available."
            case .cameraUnavailable(let position):
                "No \(position == .front ? "front" : "back") camera is available."
            case .cannotCreateDeviceInput(let reason):
                "Could not create capture input: \(reason)"
            case .cannotAddInput(let name):
                "Could not add capture input: \(name)"
            case .cannotAddOutput(let name):
                "Could not add capture output: \(name)"
            case .cannotApplyPreset(let preset):
                "Could not apply capture preset: \(preset)"
            case .cannotCreateRecordingURL:
                "Could not create an output file URL."
            case .multiCamUnavailable:
                "Multi-camera capture is not supported on this device."
            }
        }
    }

    func startFromCurrentSystemVolume() {
        Task {
            do {
                try await requestCapturePermissions()
                let settings: RecorderSettings = RecorderSettings.load()
                saveDestination = settings.saveDestination
                let volume: Float = AVAudioSession.sharedInstance().outputVolume
                let action: RecordingAction = try recordingAction(for: volume, settings: settings)
                configureAndStart(action: action, settings: settings)
            } catch {
                debugPrint("CameraManager configuration failed: \(error.localizedDescription)")
            }
        }
    }

    private func requestCapturePermissions() async throws {
        async let videoAccess: Bool = AVCaptureDevice.requestAccess(for: .video)
        async let audioAccess: Bool = AVCaptureDevice.requestAccess(for: .audio)

        guard await videoAccess, await audioAccess else {
            throw CameraConfigurationError.permissionDenied
        }
    }

    private func recordingAction(for volume: Float, settings: RecorderSettings) throws -> RecordingAction {
        let step: Int
        switch volume {
        case 0.0:
            step = 0
        case 0.01...0.07:
            step = 1
        case 0.08...0.13:
            step = 2
        case 0.14...0.19:
            step = 3
        default:
            throw CameraConfigurationError.unsupportedVolumeStep(volume)
        }

        guard let action: RecordingAction = settings.stepActions[step] else {
            throw CameraConfigurationError.unsupportedVolumeStep(volume)
        }
        return action
    }

    private func configureAndStart(action: RecordingAction, settings: RecorderSettings) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                let configuredSession: ConfiguredCaptureSession = try self.makeSession(for: action, settings: settings)
                configuredSession.session.startRunning()
                for output in configuredSession.outputs {
                    let url: URL = try Self.makeRecordingURL(action: action)
                    output.startRecording(to: url, recordingDelegate: self)
                }
                Task { @MainActor in
                    self.activeSession = configuredSession.session
                    self.activeFileOutputs = configuredSession.outputs
                }
            } catch {
                debugPrint("CameraManager session start failed: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated func makeSession(for action: RecordingAction, settings: RecorderSettings) throws -> ConfiguredCaptureSession {
        switch action {
        case .audio:
            return try makeAudioOnlySession(settings: settings)
        case .frontVideo:
            return try makeSingleCameraSession(position: .front, settings: settings)
        case .backVideo:
            return try makeSingleCameraSession(position: .back, settings: settings)
        case .multiCam:
            return try makeMultiCamSession(settings: settings)
        }
    }

    private nonisolated func makeAudioOnlySession(settings: RecorderSettings) throws -> ConfiguredCaptureSession {
        let session: AVCaptureSession = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try applyPreset(settings.videoQuality.sessionPreset, to: session)

        let microphoneInput: AVCaptureDeviceInput = try makeMicrophoneInput()
        guard session.canAddInput(microphoneInput) else { throw CameraConfigurationError.cannotAddInput("microphone") }
        session.addInput(microphoneInput)

        let output: AVCaptureMovieFileOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else { throw CameraConfigurationError.cannotAddOutput("audio movie file output") }
        session.addOutput(output)

        return ConfiguredCaptureSession(session: session, outputs: [output])
    }

    private nonisolated func makeSingleCameraSession(position: AVCaptureDevice.Position, settings: RecorderSettings) throws -> ConfiguredCaptureSession {
        let session: AVCaptureSession = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try applyPreset(settings.videoQuality.sessionPreset, to: session)

        let cameraInput: AVCaptureDeviceInput = try makeCameraInput(position: position)
        guard session.canAddInput(cameraInput) else { throw CameraConfigurationError.cannotAddInput(position == .front ? "front camera" : "back camera") }
        session.addInput(cameraInput)

        let microphoneInput: AVCaptureDeviceInput = try makeMicrophoneInput()
        guard session.canAddInput(microphoneInput) else { throw CameraConfigurationError.cannotAddInput("microphone") }
        session.addInput(microphoneInput)

        let output: AVCaptureMovieFileOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else { throw CameraConfigurationError.cannotAddOutput("movie file output") }
        session.addOutput(output)

        return ConfiguredCaptureSession(session: session, outputs: [output])
    }

    private nonisolated func makeMultiCamSession(settings: RecorderSettings) throws -> ConfiguredCaptureSession {
        guard AVCaptureMultiCamSession.isMultiCamSupported else { throw CameraConfigurationError.multiCamUnavailable }

        let session: AVCaptureMultiCamSession = AVCaptureMultiCamSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try applyPreset(settings.videoQuality.sessionPreset, to: session)

        let frontInput: AVCaptureDeviceInput = try makeCameraInput(position: .front)
        let backInput: AVCaptureDeviceInput = try makeCameraInput(position: .back)
        let microphoneInput: AVCaptureDeviceInput = try makeMicrophoneInput()

        guard session.canAddInput(frontInput) else { throw CameraConfigurationError.cannotAddInput("front camera") }
        session.addInput(frontInput)
        guard session.canAddInput(backInput) else { throw CameraConfigurationError.cannotAddInput("back camera") }
        session.addInput(backInput)
        guard session.canAddInput(microphoneInput) else { throw CameraConfigurationError.cannotAddInput("microphone") }
        session.addInput(microphoneInput)

        let frontOutput: AVCaptureMovieFileOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(frontOutput) else { throw CameraConfigurationError.cannotAddOutput("front movie file output") }
        session.addOutput(frontOutput)

        let backOutput: AVCaptureMovieFileOutput = AVCaptureMovieFileOutput()
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
        guard let microphone: AVCaptureDevice = AVCaptureDevice.default(for: .audio) else { throw CameraConfigurationError.microphoneUnavailable }
        do { return try AVCaptureDeviceInput(device: microphone) } catch { throw CameraConfigurationError.cannotCreateDeviceInput(error.localizedDescription) }
    }

    private nonisolated func makeCameraInput(position: AVCaptureDevice.Position) throws -> AVCaptureDeviceInput {
        let discoverySession: AVCaptureDevice.DiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: position)
        guard let camera: AVCaptureDevice = discoverySession.devices.first else { throw CameraConfigurationError.cameraUnavailable(position) }
        do { return try AVCaptureDeviceInput(device: camera) } catch { throw CameraConfigurationError.cannotCreateDeviceInput(error.localizedDescription) }
    }

    private nonisolated static func makeRecordingURL(action: RecordingAction) throws -> URL {
        guard let documentsURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CameraConfigurationError.cannotCreateRecordingURL
        }
        let filename: String = "\(action.rawValue)-\(UUID().uuidString).mov"
        return documentsURL.appendingPathComponent(filename)
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error {
            debugPrint("CameraManager recording failed: \(error.localizedDescription)")
            return
        }

        Task { @MainActor in
            guard self.saveDestination == .photoLibrary else { return }
            self.saveRecordingToPhotoLibrary(outputFileURL)
        }
    }

    private func saveRecordingToPhotoLibrary(_ fileURL: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                let request: PHAssetCreationRequest = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: fileURL, options: nil)
            } completionHandler: { success, error in
                if !success, let error {
                    debugPrint("Photo library save failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

private nonisolated struct ConfiguredCaptureSession: Sendable {
    let session: AVCaptureSession
    let outputs: [AVCaptureMovieFileOutput]
}
