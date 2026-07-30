import AVFoundation
import Foundation

public struct AudioRecording: Equatable, Sendable {
    public let fileURL: URL
    public let frameCount: AVAudioFramePosition
    public let durationSeconds: TimeInterval

    public init(
        fileURL: URL,
        frameCount: AVAudioFramePosition,
        durationSeconds: TimeInterval
    ) {
        self.fileURL = fileURL
        self.frameCount = frameCount
        self.durationSeconds = durationSeconds
    }
}

public struct RecordingSnapshot: Equatable, Sendable {
    public let elapsedSeconds: TimeInterval
    public let rmsLevel: Float
    public let partialTranscript: String

    public init(
        elapsedSeconds: TimeInterval,
        rmsLevel: Float,
        partialTranscript: String = ""
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.rmsLevel = rmsLevel
        self.partialTranscript = partialTranscript
    }
}

public struct RetainedAudio: Equatable, Sendable {
    public let filename: String
    public let fileURL: URL

    public init(filename: String, fileURL: URL) {
        self.filename = filename
        self.fileURL = fileURL
    }
}

public enum MicrophoneAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

@MainActor
public protocol MicrophoneAuthorizing: AnyObject {
    func currentAuthorization() -> MicrophoneAuthorization
    func requestAuthorization() async -> MicrophoneAuthorization
}

public enum AudioRecorderError: Error, Equatable, Sendable {
    case alreadyRecording
    case notRecording
    case noInputDevice
    case invalidInputFormat
    case unableToStart(String)
    case writeFailed(String)
}

public struct AudioRecordingStopFailure: Error, Equatable, Sendable {
    public let error: AudioRecorderError
    public let partialRecording: AudioRecording?

    public init(
        error: AudioRecorderError,
        partialRecording: AudioRecording?
    ) {
        self.error = error
        self.partialRecording = partialRecording
    }
}

@MainActor
public protocol AudioRecordingManaging: AnyObject {
    func start(
        at url: URL,
        onUpdate: @escaping @Sendable (RecordingSnapshot) -> Void,
        onPartialRecording: @escaping @Sendable (AudioRecording) -> Void
    ) throws
    func stop() throws -> AudioRecording
}

@MainActor
public protocol CapturePersisting {
    func save(_ capture: Capture) throws
}

@MainActor
public protocol CaptureAudioFileManaging: AnyObject {
    func makeTemporaryURL(for id: UUID) throws -> URL
    func removeTemporaryAudio(at url: URL) throws
    func retainTemporaryAudio(at url: URL, captureID: UUID) throws -> RetainedAudio
}

extension CaptureStore: CapturePersisting {}

@MainActor
public final class CaptureAudioFiles: CaptureAudioFileManaging {
    private let capturesDirectory: URL
    private let temporaryDirectory: URL
    private let fileManager: FileManager
    private let pathGuard: StoragePathGuard

    public init(root: URL, fileManager: FileManager = .default) {
        capturesDirectory = root
            .appending(path: "captures", directoryHint: .isDirectory)
            .standardizedFileURL
        temporaryDirectory = capturesDirectory
            .appending(path: ".temporary", directoryHint: .isDirectory)
            .standardizedFileURL
        self.fileManager = fileManager
        self.pathGuard = StoragePathGuard(
            root: root.standardizedFileURL,
            fileManager: fileManager
        )
    }

    public func makeTemporaryURL(for id: UUID) throws -> URL {
        try pathGuard.validate(capturesDirectory)
        try pathGuard.validate(temporaryDirectory)
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        try pathGuard.validate(temporaryDirectory)
        let url = temporaryDirectory
            .appending(path: "\(id.uuidString).wav", directoryHint: .notDirectory)
            .standardizedFileURL
        try pathGuard.validate(url)
        return url
    }

    public func removeTemporaryAudio(at url: URL) throws {
        let ownedURL = try validatedTemporaryURL(url)
        try pathGuard.validate(temporaryDirectory)
        guard try pathGuard.validate(ownedURL) else { return }
        try fileManager.removeItem(at: ownedURL)
    }

    public func retainTemporaryAudio(at url: URL, captureID: UUID) throws -> RetainedAudio {
        let source = try validatedTemporaryURL(url)
        try pathGuard.validate(capturesDirectory)
        try pathGuard.validate(temporaryDirectory)
        guard try pathGuard.validate(source) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.createDirectory(
            at: capturesDirectory,
            withIntermediateDirectories: true
        )
        let filename = "\(captureID.uuidString).wav"
        let destination = capturesDirectory
            .appending(path: filename, directoryHint: .notDirectory)
            .standardizedFileURL
        guard destination.deletingLastPathComponent() == capturesDirectory else {
            throw CaptureAudioFileError.outsideTemporaryDirectory(destination)
        }
        try pathGuard.validate(destination)
        if fileManager.fileExists(atPath: destination.path) {
            throw CaptureAudioFileError.retainedAudioAlreadyExists(destination)
        }
        try fileManager.moveItem(at: source, to: destination)
        try pathGuard.validate(destination)
        return RetainedAudio(filename: filename, fileURL: destination)
    }

    private func validatedTemporaryURL(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == temporaryDirectory,
              standardized.pathExtension.lowercased() == "wav"
        else {
            throw CaptureAudioFileError.outsideTemporaryDirectory(url)
        }
        return standardized
    }
}

public enum CaptureAudioFileError: Error, Equatable, Sendable {
    case outsideTemporaryDirectory(URL)
    case retainedAudioAlreadyExists(URL)
}
