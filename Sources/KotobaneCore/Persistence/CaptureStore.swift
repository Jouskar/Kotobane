import Foundation

public struct CaptureStore {
    public let root: URL
    private let fileManager: FileManager
    private let writer: AtomicFileWriter
    private let pathGuard: StoragePathGuard

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        self.writer = AtomicFileWriter(fileManager: fileManager)
        self.pathGuard = StoragePathGuard(root: root, fileManager: fileManager)
    }

    public func prepareDirectories() throws {
        try pathGuard.validate(root)
        try pathGuard.validate(capturesDirectory)
        try fileManager.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
        try pathGuard.validate(capturesDirectory)
    }

    public func metadataURL(for id: UUID) -> URL {
        capturesDirectory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }

    public func loadAll() throws -> [Capture] {
        try pathGuard.validate(root)
        guard try pathGuard.validate(capturesDirectory) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: capturesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        let decoder = Self.decoder
        return try urls.map {
            try pathGuard.validate($0)
            return try decoder.decode(Capture.self, from: Data(contentsOf: $0))
        }
    }

    public func save(_ capture: Capture) throws {
        try pathGuard.validate(root)
        try pathGuard.validate(capturesDirectory)
        try pathGuard.validate(metadataURL(for: capture.id))
        if let audioFilename = capture.audioFilename {
            try pathGuard.validate(try audioURL(for: audioFilename))
        }
        try prepareDirectories()
        try pathGuard.validate(metadataURL(for: capture.id))
        try writer.write(try Self.encoder.encode(capture), to: metadataURL(for: capture.id))
    }

    public func delete(id: UUID) throws {
        try pathGuard.validate(root)
        try pathGuard.validate(capturesDirectory)
        let metadata = metadataURL(for: id)
        guard try pathGuard.validate(metadata) else { return }

        let capture = try Self.decoder.decode(Capture.self, from: Data(contentsOf: metadata))
        if let audioFilename = capture.audioFilename {
            let audio = try audioURL(for: audioFilename)
            if try pathGuard.validate(audio) {
                try fileManager.removeItem(at: audio)
            }
        }
        try pathGuard.validate(metadata)
        try fileManager.removeItem(at: metadata)
    }

    public func deleteAll() throws {
        try pathGuard.validate(root)
        try pathGuard.validate(capturesDirectory)
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
