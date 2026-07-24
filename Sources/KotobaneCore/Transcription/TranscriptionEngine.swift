import Foundation

public protocol TranscriptionEngine: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

public struct TranscriptionRequest: Equatable, Sendable {
    public let id: UUID
    public let audioURL: URL
    public let language: String
    public let model: ModelChoice

    public init(
        id: UUID = UUID(),
        audioURL: URL,
        language: String,
        model: ModelChoice
    ) {
        self.id = id
        self.audioURL = audioURL
        self.language = language
        self.model = model
    }
}

public struct TranscriptionResult: Equatable, Sendable {
    public let text: String
    public let detectedLanguage: String
    public let durationSeconds: Double

    public init(text: String, detectedLanguage: String, durationSeconds: Double) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.durationSeconds = durationSeconds
    }
}

public enum TranscriptionFailure: Error, Equatable, Sendable {
    case invalidAudioPath(URL)
    case helperLaunch(String)
    case helperCrashed(exitCode: Int32, stderr: String)
    case unexpectedEOF(stderr: String)
    case timedOut
    case protocolViolation(message: String, stderr: String)
    case helperRejected(code: String, message: String)

    var permitsRestart: Bool {
        switch self {
        case .helperCrashed, .unexpectedEOF, .timedOut:
            true
        case .invalidAudioPath, .helperLaunch, .protocolViolation, .helperRejected:
            false
        }
    }
}
