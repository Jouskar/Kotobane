import Foundation
import Observation

@MainActor
@Observable
public final class CaptureController {
    public enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case recording(RecordingSnapshot)
        case transcribing
        case reviewing(Capture)
        case failed(CaptureFailure)

        public var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        public var recordingSnapshot: RecordingSnapshot? {
            if case .recording(let snapshot) = self { return snapshot }
            return nil
        }

        public var capture: Capture? {
            if case .reviewing(let capture) = self { return capture }
            return nil
        }

        public var failure: CaptureFailure? {
            if case .failed(let failure) = self { return failure }
            return nil
        }
    }

    public private(set) var state: State = .idle

    private let authorizer: any MicrophoneAuthorizing
    private let recorder: any AudioRecordingManaging
    private let transcriptionEngine: any TranscriptionEngine
    private let store: any CapturePersisting
    private let audioFiles: any CaptureAudioFileManaging
    private let retention: AudioRetentionPolicy
    private let languageHint: String
    private let model: ModelChoice
    private let defaultIntent: CaptureIntent
    private let makeID: () -> UUID
    private let now: () -> Date

    private var operationID: UUID?
    private var captureID: UUID?
    private var temporaryURL: URL?
    private var retryContext: RetryContext?

    public init(
        authorizer: any MicrophoneAuthorizing,
        recorder: any AudioRecordingManaging,
        transcriptionEngine: any TranscriptionEngine,
        store: any CapturePersisting,
        audioFiles: any CaptureAudioFileManaging,
        retention: AudioRetentionPolicy,
        languageHint: String,
        model: ModelChoice,
        defaultIntent: CaptureIntent,
        makeID: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init
    ) {
        self.authorizer = authorizer
        self.recorder = recorder
        self.transcriptionEngine = transcriptionEngine
        self.store = store
        self.audioFiles = audioFiles
        self.retention = retention
        self.languageHint = languageHint
        self.model = model
        self.defaultIntent = defaultIntent
        self.makeID = makeID
        self.now = now
    }

    public func start() async {
        guard state == .idle else { return }
        let operationID = UUID()
        self.operationID = operationID
        retryContext = nil

        let authorization = authorizer.currentAuthorization()
        let resolvedAuthorization: MicrophoneAuthorization
        if authorization == .notDetermined {
            state = .requestingPermission
            resolvedAuthorization = await authorizer.requestAuthorization()
            guard self.operationID == operationID,
                  state == .requestingPermission
            else { return }
        } else {
            resolvedAuthorization = authorization
        }

        guard resolvedAuthorization == .authorized else {
            self.operationID = nil
            state = .failed(
                CaptureFailure(
                    kind: .microphonePermissionDenied,
                    recovery: .openMicrophoneSettings,
                    message: "Allow microphone access in System Settings to record."
                )
            )
            return
        }

        beginRecording(operationID: operationID)
    }

    public func stop() async {
        guard case .recording = state,
              let operationID,
              let temporaryURL,
              let captureID
        else { return }

        state = .transcribing
        let recording: AudioRecording
        do {
            recording = try recorder.stop()
        } catch {
            removeInvalidTemporaryAudio(at: temporaryURL)
            self.operationID = nil
            state = .failed(
                CaptureFailure(
                    kind: recorderFailureKind(error),
                    recovery: .retryRecording,
                    message: failureMessage(error)
                )
            )
            return
        }

        guard recording.frameCount > 0 else {
            removeInvalidTemporaryAudio(at: temporaryURL)
            self.operationID = nil
            state = .failed(
                CaptureFailure(
                    kind: .emptyRecording,
                    recovery: .retryRecording,
                    message: "No microphone audio was captured. Check the input device and try again."
                )
            )
            return
        }

        retryContext = .transcribe(recording, captureID)
        await transcribe(recording, captureID: captureID, operationID: operationID)
    }

    public func cancel() async {
        let priorState = state
        operationID = nil
        retryContext = nil

        if case .recording = priorState {
            _ = try? recorder.stop()
        }
        if let temporaryURL {
            try? audioFiles.removeTemporaryAudio(at: temporaryURL)
        }
        self.temporaryURL = nil
        captureID = nil
        state = .idle
    }

    public func retry() async {
        guard case .failed(let failure) = state else { return }
        if failure.recovery == .retryRecording
            || failure.recovery == .openMicrophoneSettings {
            state = .idle
            await start()
            return
        }
        guard let retryContext else { return }
        let operationID = UUID()
        self.operationID = operationID
        state = .transcribing

        switch retryContext {
        case .transcribe(let recording, let captureID):
            await transcribe(recording, captureID: captureID, operationID: operationID)
        case .persist(let recording, let capture):
            persist(
                recording: recording,
                capture: capture,
                operationID: operationID
            )
        case .delete(let recording, let capture):
            deleteDefaultAudio(
                recording: recording,
                capture: capture,
                operationID: operationID
            )
        case .retain(let recording, let capture, let retainedAudio):
            retainAudio(
                recording: recording,
                capture: capture,
                retainedAudio: retainedAudio,
                operationID: operationID
            )
        }
    }

    private func beginRecording(operationID: UUID) {
        let captureID = makeID()
        let url: URL
        do {
            url = try audioFiles.makeTemporaryURL(for: captureID)
        } catch {
            self.operationID = nil
            state = .failed(
                CaptureFailure(
                    kind: .recordingFailed,
                    recovery: .retryRecording,
                    message: failureMessage(error)
                )
            )
            return
        }

        do {
            try recorder.start(at: url) { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.operationID == operationID,
                          self.state.isRecording
                    else { return }
                    self.state = .recording(snapshot)
                }
            }
        } catch {
            try? audioFiles.removeTemporaryAudio(at: url)
            self.operationID = nil
            state = .failed(
                CaptureFailure(
                    kind: recorderFailureKind(error),
                    recovery: .retryRecording,
                    message: failureMessage(error)
                )
            )
            return
        }

        self.captureID = captureID
        temporaryURL = url
        state = .recording(.init(elapsedSeconds: 0, rmsLevel: 0))
    }

    private func transcribe(
        _ recording: AudioRecording,
        captureID: UUID,
        operationID: UUID
    ) async {
        do {
            let result = try await transcriptionEngine.transcribe(
                TranscriptionRequest(
                    id: captureID,
                    audioURL: recording.fileURL,
                    language: languageHint,
                    model: model
                )
            )
            guard self.operationID == operationID, state == .transcribing else {
                return
            }
            let timestamp = now()
            let capture = Capture(
                id: captureID,
                title: "",
                createdAt: timestamp,
                modifiedAt: timestamp,
                transcript: result.text,
                intent: defaultIntent,
                status: .completed,
                durationSeconds: recording.durationSeconds,
                audioFilename: nil
            )
            retryContext = .persist(recording, capture)
            persist(recording: recording, capture: capture, operationID: operationID)
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            failTranscription(
                recording,
                captureID: captureID,
                message: "Transcription was cancelled."
            )
        } catch {
            guard self.operationID == operationID else { return }
            failTranscription(
                recording,
                captureID: captureID,
                message: failureMessage(error)
            )
        }
    }

    private func persist(
        recording: AudioRecording,
        capture: Capture,
        operationID: UUID
    ) {
        guard self.operationID == operationID else { return }
        do {
            try store.save(capture)
        } catch {
            retryContext = .persist(recording, capture)
            state = .failed(
                CaptureFailure(
                    kind: .persistenceFailed,
                    recovery: .retryTranscription,
                    message: "The transcript could not be saved. The audio is preserved; retry saving.",
                    preservedAudioURL: recording.fileURL
                )
            )
            return
        }

        switch retention {
        case .deleteAfterTranscription:
            retryContext = .delete(recording, capture)
            deleteDefaultAudio(
                recording: recording,
                capture: capture,
                operationID: operationID
            )
        case .retain:
            retryContext = .retain(recording, capture, nil)
            retainAudio(
                recording: recording,
                capture: capture,
                retainedAudio: nil,
                operationID: operationID
            )
        }
    }

    private func deleteDefaultAudio(
        recording: AudioRecording,
        capture: Capture,
        operationID: UUID
    ) {
        guard self.operationID == operationID else { return }
        do {
            try audioFiles.removeTemporaryAudio(at: recording.fileURL)
            complete(capture)
        } catch {
            retryContext = .delete(recording, capture)
            state = .failed(
                CaptureFailure(
                    kind: .retentionFailed,
                    recovery: .retryRetention,
                    message: "The transcript is saved, but the temporary audio could not be removed. Retry cleanup.",
                    preservedAudioURL: recording.fileURL
                )
            )
        }
    }

    private func retainAudio(
        recording: AudioRecording,
        capture: Capture,
        retainedAudio: RetainedAudio?,
        operationID: UUID
    ) {
        guard self.operationID == operationID else { return }
        var retainedCapture = capture
        var retainedAudio = retainedAudio
        do {
            if retainedAudio == nil {
                retainedAudio = try audioFiles.retainTemporaryAudio(
                    at: recording.fileURL,
                    captureID: capture.id
                )
            }
            guard let retainedAudio else {
                preconditionFailure("Retained audio must exist after a successful move.")
            }
            retainedCapture.audioFilename = retainedAudio.filename
            retryContext = .retain(recording, retainedCapture, retainedAudio)
            try store.save(retainedCapture)
            complete(retainedCapture)
        } catch {
            retryContext = .retain(
                recording,
                retainedCapture,
                retainedAudio
            )
            state = .failed(
                CaptureFailure(
                    kind: .retentionFailed,
                    recovery: .retryRetention,
                    message: "The transcript and audio are preserved, but retained-audio metadata could not be finalized. Retry.",
                    preservedAudioURL: retainedAudio?.fileURL ?? recording.fileURL
                )
            )
        }
    }

    private func complete(_ capture: Capture) {
        operationID = nil
        retryContext = nil
        temporaryURL = nil
        captureID = nil
        state = .reviewing(capture)
    }

    private func failTranscription(
        _ recording: AudioRecording,
        captureID: UUID,
        message: String
    ) {
        operationID = nil
        retryContext = .transcribe(recording, captureID)
        state = .failed(
            CaptureFailure(
                kind: .transcriptionFailed,
                recovery: .retryTranscription,
                message: message,
                preservedAudioURL: recording.fileURL
            )
        )
    }

    private func removeInvalidTemporaryAudio(at url: URL) {
        try? audioFiles.removeTemporaryAudio(at: url)
        temporaryURL = nil
        captureID = nil
        retryContext = nil
    }

    private func recorderFailureKind(_ error: Error) -> CaptureFailure.Kind {
        guard let recorderError = error as? AudioRecorderError else {
            return .recordingFailed
        }
        switch recorderError {
        case .noInputDevice:
            return .noInputDevice
        case .alreadyRecording, .notRecording, .invalidInputFormat,
            .unableToStart, .writeFailed:
            return .recordingFailed
        }
    }

    private func failureMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

public struct CaptureFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case microphonePermissionDenied
        case noInputDevice
        case recordingFailed
        case emptyRecording
        case transcriptionFailed
        case persistenceFailed
        case retentionFailed
    }

    public enum Recovery: Equatable, Sendable {
        case openMicrophoneSettings
        case retryRecording
        case retryTranscription
        case retryRetention
    }

    public let kind: Kind
    public let recovery: Recovery
    public let message: String
    public let preservedAudioURL: URL?

    public init(
        kind: Kind,
        recovery: Recovery,
        message: String,
        preservedAudioURL: URL? = nil
    ) {
        self.kind = kind
        self.recovery = recovery
        self.message = message
        self.preservedAudioURL = preservedAudioURL
    }
}

private enum RetryContext {
    case transcribe(AudioRecording, UUID)
    case persist(AudioRecording, Capture)
    case delete(AudioRecording, Capture)
    case retain(AudioRecording, Capture, RetainedAudio?)
}
