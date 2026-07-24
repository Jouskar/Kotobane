import Foundation

public struct Capture: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var transcript: String
    public var intent: CaptureIntent
    public var status: CaptureStatus
    public var diagnostic: String?
    public var durationSeconds: Double
    public var audioFilename: String?

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        modifiedAt: Date,
        transcript: String,
        intent: CaptureIntent,
        status: CaptureStatus,
        diagnostic: String? = nil,
        durationSeconds: Double,
        audioFilename: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.transcript = transcript
        self.intent = intent
        self.status = status
        self.diagnostic = diagnostic
        self.durationSeconds = durationSeconds
        self.audioFilename = audioFilename
    }
}

public enum CaptureStatus: String, Codable, Equatable, Sendable {
    case recorded
    case transcribing
    case completed
    case failed
}
