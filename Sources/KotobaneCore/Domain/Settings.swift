import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var version: Int
    public var languageHint: String
    public var model: ModelChoice
    public var audioRetention: AudioRetentionPolicy
    public var shortcut: Shortcut
    public var pasteAfterOpening: Bool
    public var accurateFinalTranscript: Bool

    public static let currentVersion = 3

    public static let defaults = AppSettings(
        version: currentVersion,
        languageHint: "Turkish",
        model: .small,
        audioRetention: .deleteAfterTranscription,
        shortcut: Shortcut(keyCode: 49, modifiers: [.control, .option]),
        pasteAfterOpening: false,
        accurateFinalTranscript: true
    )

    public init(
        version: Int,
        languageHint: String,
        model: ModelChoice,
        audioRetention: AudioRetentionPolicy,
        shortcut: Shortcut,
        pasteAfterOpening: Bool,
        accurateFinalTranscript: Bool
    ) {
        self.version = version
        self.languageHint = languageHint
        self.model = model
        self.audioRetention = audioRetention
        self.shortcut = shortcut
        self.pasteAfterOpening = pasteAfterOpening
        self.accurateFinalTranscript = accurateFinalTranscript
    }
}

public enum AudioRetentionPolicy: String, Codable, Equatable, Sendable {
    case deleteAfterTranscription
    case retain
}

public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: Modifier

    public init(keyCode: UInt32, modifiers: Modifier) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public struct Modifier: OptionSet, Equatable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let control = Modifier(rawValue: 1 << 0)
        public static let option = Modifier(rawValue: 1 << 1)
        public static let shift = Modifier(rawValue: 1 << 2)
        public static let command = Modifier(rawValue: 1 << 3)
    }
}

extension Shortcut.Modifier: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
