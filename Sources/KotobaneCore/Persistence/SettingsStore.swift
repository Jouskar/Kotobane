import Foundation

public struct SettingsStore {
    public let url: URL
    private let writer: AtomicFileWriter
    private let pathGuard: StoragePathGuard

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url.standardizedFileURL
        self.writer = AtomicFileWriter(fileManager: fileManager)
        self.pathGuard = StoragePathGuard(
            root: url.standardizedFileURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
    }

    public func load() throws -> AppSettings {
        guard try validateURL() else { return .defaults }
        return try Self.decoder.decode(StoredSettings.self, from: Data(contentsOf: url)).appSettings
    }

    public func save(_ settings: AppSettings) throws {
        try validateURL()
        try writer.write(try Self.encoder.encode(settings), to: url)
    }

    @discardableResult
    private func validateURL() throws -> Bool {
        do {
            return try pathGuard.validate(url)
        } catch StoragePathError.symbolicLink(let linkedURL) {
            throw SettingsStoreError.symbolicLink(linkedURL)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

private struct StoredSettings: Decodable {
    let version: Int
    let languageHint: String
    let model: ModelChoice
    let audioRetention: AudioRetentionPolicy
    let shortcut: Shortcut
    let pasteAfterOpening: Bool
    let accurateFinalTranscript: Bool

    private enum CodingKeys: String, CodingKey {
        case version, languageHint, model, audioRetention, shortcut, pasteAfterOpening, accurateFinalTranscript
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard (1...AppSettings.currentVersion).contains(version) else {
            throw SettingsStoreError.unsupportedVersion(version)
        }
        languageHint = try container.decode(String.self, forKey: .languageHint)
        let rawModel = try container.decode(String.self, forKey: .model)
        guard let decodedModel = ModelChoice(rawValue: rawModel) ?? Self.legacyModel(named: rawModel) else {
            throw DecodingError.dataCorruptedError(
                forKey: .model,
                in: container,
                debugDescription: "Unknown model choice: \(rawModel)"
            )
        }
        model = decodedModel
        audioRetention = try container.decode(AudioRetentionPolicy.self, forKey: .audioRetention)
        shortcut = try container.decode(Shortcut.self, forKey: .shortcut)
        if version == 1 {
            pasteAfterOpening = try container.decodeIfPresent(Bool.self, forKey: .pasteAfterOpening) ?? false
        } else {
            pasteAfterOpening = try container.decode(Bool.self, forKey: .pasteAfterOpening)
        }
        if version < 3 {
            accurateFinalTranscript = true
        } else {
            accurateFinalTranscript = try container.decode(Bool.self, forKey: .accurateFinalTranscript)
        }
    }

    var appSettings: AppSettings {
        AppSettings(
            version: AppSettings.currentVersion,
            languageHint: languageHint,
            model: model,
            audioRetention: audioRetention,
            shortcut: shortcut,
            pasteAfterOpening: pasteAfterOpening,
            accurateFinalTranscript: accurateFinalTranscript
        )
    }

    private static func legacyModel(named rawModel: String) -> ModelChoice? {
        switch rawModel {
        case "small": .small
        case "accuracy": .accuracy
        default: nil
        }
    }
}

public enum SettingsStoreError: Error, Equatable {
    case symbolicLink(URL)
    case unsupportedVersion(Int)
}
