import Foundation

public struct CaptureStore {
    public let root: URL
    private let fileManager: FileManager
    private let writer: AtomicFileWriter

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        self.writer = AtomicFileWriter(fileManager: fileManager)
    }

    public func prepareDirectories() throws {
        try fileManager.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
    }

    public func metadataURL(for id: UUID) -> URL {
        capturesDirectory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }

    public func loadAll() throws -> [Capture] {
        guard fileManager.fileExists(atPath: capturesDirectory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: capturesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        let decoder = Self.decoder
        return try urls.map { try decoder.decode(Capture.self, from: Data(contentsOf: $0)) }
    }

    public func save(_ capture: Capture) throws {
        if let audioFilename = capture.audioFilename {
            _ = try audioURL(for: audioFilename)
        }
        try prepareDirectories()
        try writer.write(try Self.encoder.encode(capture), to: metadataURL(for: capture.id))
    }

    public func delete(id: UUID) throws {
        let metadata = metadataURL(for: id)
        guard fileManager.fileExists(atPath: metadata.path) else { return }

        let capture = try Self.decoder.decode(Capture.self, from: Data(contentsOf: metadata))
        if let audioFilename = capture.audioFilename {
            let audio = try audioURL(for: audioFilename)
            if fileManager.fileExists(atPath: audio.path) {
                try fileManager.removeItem(at: audio)
            }
        }
        try fileManager.removeItem(at: metadata)
    }

    public func deleteAll() throws {
        for capture in try loadAll() {
            try delete(id: capture.id)
        }
    }

    private var capturesDirectory: URL {
        root.appending(path: "captures", directoryHint: .isDirectory).standardizedFileURL
    }

    private func audioURL(for filename: String) throws -> URL {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\\"),
              !URL(fileURLWithPath: filename).hasDirectoryPath
        else {
            throw CaptureStoreError.invalidAudioFilename(filename)
        }

        let url = capturesDirectory.appending(path: filename, directoryHint: .notDirectory).standardizedFileURL
        guard url.deletingLastPathComponent() == capturesDirectory else {
            throw CaptureStoreError.invalidAudioFilename(filename)
        }
        return url
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum CaptureStoreError: Error, Equatable {
    case invalidAudioFilename(String)
}
