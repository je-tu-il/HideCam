//
//  CameraManager.swift
//  StealthRecorder
//
//  Created by Rork on May 23, 2026.
//

import AVFoundation
import Foundation

@Observable
final class CameraManager: NSObject {
    private let sessionQueue: DispatchQueue = DispatchQueue(label: "app.rork.stealth-recorder.session", qos: .userInitiated)
    private var activeSession: AVCaptureSession?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var movieFileOutput: AVCaptureMovieFileOutput?
    private var frontMovieFileOutput: AVCaptureMovieFileOutput?
    private var backMovieFileOutput: AVCaptureMovieFileOutput?

    private enum RecordingMode: Sendable {
        case audioOnly
        case frontCamera
        case backCamera
        case multiCam
    }

    enum CameraConfigurationError: LocalizedError, Sendable {
        case permissionDenied
        case unsupportedVolumeStep(Float)
        case microphoneUnavailable
        case cameraUnavailable(AVCaptureDevice.Position)
        case cannotCreateDeviceInput(String)
        case cannotAddInput(String)
        case cannotAddOutput(String)
        case multiCamUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Camera or microphone permission was denied."
            case .unsupportedVolumeStep(let volume):
                "No recording mode is configured for output volume \(volume)."
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
            case .multiCamUnavailable:
                "Multi-camera capture is not supported on this device."
            }
        }
    }

    func startFromCurrentSystemVolume() {
        Task {
            do {
                try await requestCapturePermissions()
                let volume: Float = AVAudioSession.sharedInstance().outputVolume
                let mode: RecordingMode = try recordingMode(for: volume)
                configureAndStart(mode: mode)
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

    private func recordingMode(for volume: Float) throws -> RecordingMode {
        switch volume {
        case 0.0:
            return .audioOnly
        case 0.01...0.07:
            return .frontCamera
        case 0.08...0.13:
            return .backCamera
        case 0.14...0.19:
            return .multiCam
        default:
            throw CameraConfigurationError.unsupportedVolumeStep(volume)
        }
    }

    private func configureAndStart(mode: RecordingMode) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                let session: AVCaptureSession = try self.makeSession(for: mode)
                session.startRunning()
            } catch {
                debugPrint("CameraManager session start failed: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated func makeSession(for mode: RecordingMode) throws -> AVCaptureSession {
        switch mode {
        case .audioOnly:
            return try makeAudioOnlySession()
        case .frontCamera:
            return try makeSingleCameraSession(position: .front)
        case .backCamera:
            return try makeSingleCameraSession(position: .back)
        case .multiCam:
            return try makeMultiCamSession()
        }
    }

    private nonisolated func makeAudioOnlySession() throws -> AVCaptureSession {
        let session: AVCaptureSession = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let microphoneInput: AVCaptureDeviceInput = try makeMicrophoneInput()
        guard session.canAddInput(microphoneInput) else {
            throw CameraConfigurationError.cannotAddInput("microphone")
        }
        session.addInput(microphoneInput)

        let output: AVCaptureAudioDataOutput = AVCaptureAudioDataOutput()
        guard session.canAddOutput(output) else {
            throw CameraConfigurationError.cannotAddOutput("audio data output")
        }
        session.addOutput(output)

        Task { @MainActor in
            self.audioDataOutput = output
            self.activeSession = session
        }
        return session
    }

    private nonisolated func makeSingleCameraSession(position: AVCaptureDevice.Position) throws -> AVCaptureSession {
        let session: AVCaptureSession = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let cameraInput: AVCaptureDeviceInput = try makeCameraInput(position: position)
        guard session.canAddInput(cameraInput) else {
            throw CameraConfigurationError.cannotAddInput(position == .front ? "front camera" : "back camera")
        }
        session.addInput(cameraInput)

        let microphoneInput: AVCaptureDeviceInput = try makeMicrophoneInput()
        guard session.canAddInput(microphoneInput) else {
            throw CameraConfigurationError.cannotAddInput("microphone")
        }
        session.addInput(microphoneInput)

        let output: AVCaptureMovieFileOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            throw CameraConfigurationError.cannotAddOutput("movie file output")
        }
        session.addOutput(output)

        Task { @MainActor in
            self.movieFileOutput = output
            self.activeSession = session
        }
        return session
    }

    private nonisolated func makeMultiCamSession() throws -> AVCaptureMultiCamSession {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CameraConfigurationError.multiCamUnavailable
        }

        let session: AVCaptureMultiCamSession = AVCaptureMultiCamSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let frontInput: AVCaptureDeviceInput = try makeCameraInput(position: .front)
        let backInput: AVCaptureDeviceInput = try makeCameraInput(position: .back)
        let microphoneInput: AVCaptureDeviceInput = try makeMicrophoneInput()

        guard session.canAddInput(frontInput) else {
            throw CameraConfigurationError.cannotAddInput("front camera")
        }
        session.addInput(frontInput)

        guard session.canAddInput(backInput) else {
            throw CameraConfigurationError.cannotAddInput("back camera")
        }
        session.addInput(backInput)

        guard session.canAddInput(microphoneInput) else {
            throw CameraConfigurationError.cannotAddInput("microphone")
        }
        session.addInput(microphoneInput)

        let frontOutput: AVCaptureMovieFileOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(frontOutput) else {
            throw CameraConfigurationError.cannotAddOutput("front movie file output")
        }
        session.addOutput(frontOutput)

        let backOutput: AVCaptureMovieFileOutput = AVCaptureMovieFileOutput()
        guard session.canAddOutput(backOutput) else {
            throw CameraConfigurationError.cannotAddOutput("back movie file output")
        }
        session.addOutput(backOutput)

        Task { @MainActor in
            self.frontMovieFileOutput = frontOutput
            self.backMovieFileOutput = backOutput
            self.activeSession = session
        }
        return session
    }

    private nonisolated func makeMicrophoneInput() throws -> AVCaptureDeviceInput {
        guard let microphone: AVCaptureDevice = AVCaptureDevice.default(for: .audio) else {
            throw CameraConfigurationError.microphoneUnavailable
        }

        do {
            return try AVCaptureDeviceInput(device: microphone)
        } catch {
            throw CameraConfigurationError.cannotCreateDeviceInput(error.localizedDescription)
        }
    }

    private nonisolated func makeCameraInput(position: AVCaptureDevice.Position) throws -> AVCaptureDeviceInput {
        let discoverySession: AVCaptureDevice.DiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )

        guard let camera: AVCaptureDevice = discoverySession.devices.first else {
            throw CameraConfigurationError.cameraUnavailable(position)
        }

        do {
            return try AVCaptureDeviceInput(device: camera)
        } catch {
            throw CameraConfigurationError.cannotCreateDeviceInput(error.localizedDescription)
        }
    }
}
