import Foundation

public struct SettingsStore {
    public let url: URL
    private let fileManager: FileManager
    private let writer: AtomicFileWriter

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        self.writer = AtomicFileWriter(fileManager: fileManager)
    }

    public func load() throws -> AppSettings {
        guard fileManager.fileExists(atPath: url.path) else { return .defaults }
        return try Self.decoder.decode(StoredSettings.self, from: Data(contentsOf: url)).appSettings
    }

    public func save(_ settings: AppSettings) throws {
        try writer.write(try Self.encoder.encode(settings), to: url)
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

    private enum CodingKeys: String, CodingKey {
        case version, languageHint, model, audioRetention, shortcut, pasteAfterOpening
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
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
        pasteAfterOpening = try container.decodeIfPresent(Bool.self, forKey: .pasteAfterOpening) ?? false
    }

    var appSettings: AppSettings {
        AppSettings(
            version: AppSettings.currentVersion,
            languageHint: languageHint,
            model: model,
            audioRetention: audioRetention,
            shortcut: shortcut,
            pasteAfterOpening: pasteAfterOpening
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
