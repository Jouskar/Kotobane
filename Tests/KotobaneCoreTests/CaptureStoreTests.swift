import Foundation
import Testing
@testable import KotobaneCore

@Test func saveRoundTripsAndDeleteRemovesMetadataAndAudio() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CaptureStore(root: root)
    let audio = root.appending(path: "captures/sample.wav")
    try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: audio)
    let capture = Capture.fixture(audioFilename: "sample.wav")

    try store.save(capture)
    #expect(try store.loadAll() == [capture])

    try store.delete(id: capture.id)
    #expect(!FileManager.default.fileExists(atPath: audio.path))
    #expect(try store.loadAll().isEmpty)
}

@Test func corruptMetadataIsReportedWithoutDeletingAudio() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CaptureStore(root: root)
    try store.prepareDirectories()
    let audio = root.appending(path: "captures/retained.wav")
    try Data([1, 2, 3]).write(to: audio)
    try Data("{".utf8).write(to: store.metadataURL(for: UUID()))

    #expect(throws: (any Error).self) { try store.loadAll() }
    #expect(FileManager.default.fileExists(atPath: audio.path))
}

@Test(arguments: ["../escape.wav", "/tmp/escape.wav", "nested/escape.wav", ".."]) func saveRejectsUnsafeAudioFilename(_ filename: String) throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CaptureStore(root: root)

    #expect(throws: (any Error).self) { try store.save(Capture.fixture(audioFilename: filename)) }
}

@Test func deleteAllRemovesMetadataAndRetainedAudio() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CaptureStore(root: root)
    let audio = root.appending(path: "captures/retained.wav")
    try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1]).write(to: audio)
    try store.save(Capture.fixture(audioFilename: "retained.wav"))

    try store.deleteAll()

    #expect(try store.loadAll().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: audio.path))
}

@Test func captureSaveAtomicallyReplacesExistingMetadata() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CaptureStore(root: root)
    var capture = Capture.fixture()
    try store.save(capture)
    capture.title = "Updated"
    capture.transcript = "Güncellendi"
    capture.modifiedAt = Date(timeIntervalSince1970: 1_700_000_002)

    try store.save(capture)

    #expect(try store.loadAll() == [capture])
}

@Test func captureJSONUsesSortedKeysAndISO8601Dates() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CaptureStore(root: root)
    let capture = Capture.fixture()
    try store.save(capture)

    let json = try String(contentsOf: store.metadataURL(for: capture.id), encoding: .utf8)
    #expect(json.contains(#""createdAt" : "2023-11-14T22:13:20Z""#))
    #expect(json.contains(#""modifiedAt" : "2023-11-14T22:13:21Z""#))
    expectCaptureKeys(
        ["createdAt", "durationSeconds", "id", "intent", "modifiedAt", "status", "title", "transcript"],
        appearInOrderIn: json
    )
}

@Test func failedAudioDeleteLeavesMetadataAndAudioInPlace() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = root.appending(path: "captures/retained.wav")
    try FileManager.default.createDirectory(
        at: audio.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data([1, 2, 3]).write(to: audio)
    let fileManager = FailingRemovalFileManager(failingURL: audio)
    let store = CaptureStore(root: root, fileManager: fileManager)
    let capture = Capture.fixture(audioFilename: audio.lastPathComponent)
    try store.save(capture)

    #expect(throws: InjectedFileSystemError.failure) { try store.delete(id: capture.id) }
    #expect(FileManager.default.fileExists(atPath: audio.path))
    #expect(FileManager.default.fileExists(atPath: store.metadataURL(for: capture.id).path))
}

@Test(arguments: AtomicWriterFailure.allCases)
func atomicWriterRemovesTemporaryFileAfterInjectedFailure(_ failure: AtomicWriterFailure) throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appending(path: "capture.json")
    let original = Data("original".utf8)
    if failure == .replace {
        try original.write(to: destination)
    }
    let writer = AtomicFileWriter(fileSystem: FailingAtomicFileSystem(failure: failure))

    #expect(throws: InjectedFileSystemError.failure) {
        try writer.write(Data("replacement".utf8), to: destination)
    }

    let remaining = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    )
    #expect(!remaining.contains { $0.pathExtension == "tmp" })
    if failure == .replace {
        #expect(try Data(contentsOf: destination) == original)
    } else {
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@Test(arguments: CaptureStoreOperation.allCases)
func symlinkedRootIsRejectedWithoutChangingOutsideFiles(_ operation: CaptureStoreOperation) throws {
    let sandbox = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let outside = sandbox.appending(path: "outside", directoryHint: .isDirectory)
    let linkedRoot = sandbox.appending(path: "linked-root", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: outside.appending(path: "captures", directoryHint: .isDirectory),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
    let existing = Capture.fixture(audioFilename: "outside.wav")
    try writeFixture(existing, under: outside)
    let audio = outside.appending(path: "captures/outside.wav")
    try Data([1, 2, 3]).write(to: audio)
    let saved = Capture.fixture()

    #expect(throws: (any Error).self) {
        try operation.perform(
            on: CaptureStore(root: linkedRoot),
            captureToSave: saved,
            existingID: existing.id
        )
    }
    #expect(!FileManager.default.fileExists(
        atPath: outside.appending(path: "captures/\(saved.id.uuidString).json").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: outside.appending(path: "captures/\(existing.id.uuidString).json").path
    ))
    #expect(FileManager.default.fileExists(atPath: audio.path))
}

@Test(arguments: CaptureStoreOperation.allCases)
func symlinkedCapturesDirectoryIsRejectedWithoutChangingOutsideFiles(
    _ operation: CaptureStoreOperation
) throws {
    let sandbox = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let root = sandbox.appending(path: "root", directoryHint: .isDirectory)
    let outside = sandbox.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: root.appending(path: "captures", directoryHint: .isDirectory),
        withDestinationURL: outside
    )
    let existing = Capture.fixture(audioFilename: "outside.wav")
    try writeFixture(existing, to: outside)
    let audio = outside.appending(path: "outside.wav")
    try Data([1, 2, 3]).write(to: audio)
    let saved = Capture.fixture()

    #expect(throws: (any Error).self) {
        try operation.perform(
            on: CaptureStore(root: root),
            captureToSave: saved,
            existingID: existing.id
        )
    }
    #expect(!FileManager.default.fileExists(
        atPath: outside.appending(path: "\(saved.id.uuidString).json").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: outside.appending(path: "\(existing.id.uuidString).json").path
    ))
    #expect(FileManager.default.fileExists(atPath: audio.path))
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

enum CaptureStoreOperation: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case prepare
    case load
    case save
    case delete
    case deleteAll

    var testDescription: String { rawValue }

    func perform(on store: CaptureStore, captureToSave: Capture, existingID: UUID) throws {
        switch self {
        case .prepare:
            try store.prepareDirectories()
        case .load:
            _ = try store.loadAll()
        case .save:
            try store.save(captureToSave)
        case .delete:
            try store.delete(id: existingID)
        case .deleteAll:
            try store.deleteAll()
        }
    }
}

private func writeFixture(_ capture: Capture, under root: URL) throws {
    try writeFixture(capture, to: root.appending(path: "captures", directoryHint: .isDirectory))
}

private func writeFixture(_ capture: Capture, to directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(capture).write(
        to: directory.appending(path: "\(capture.id.uuidString).json")
    )
}

private func expectCaptureKeys(_ keys: [String], appearInOrderIn json: String) {
    var lowerBound = json.startIndex
    for key in keys {
        guard let range = json.range(of: "\"\(key)\"", range: lowerBound..<json.endIndex) else {
            Issue.record("Missing or unsorted JSON key \(key)")
            return
        }
        lowerBound = range.upperBound
    }
}

private enum InjectedFileSystemError: Error {
    case failure
}

enum AtomicWriterFailure: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case write
    case replace

    var testDescription: String { rawValue }
}

private struct FailingAtomicFileSystem: AtomicFileSystem {
    let failure: AtomicWriterFailure

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        if failure == .write {
            throw InjectedFileSystemError.failure
        }
    }

    func replaceItem(at destination: URL, with temporary: URL) throws {
        if failure == .replace {
            throw InjectedFileSystemError.failure
        }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

private final class FailingRemovalFileManager: FileManager, @unchecked Sendable {
    private let failingURL: URL

    init(failingURL: URL) {
        self.failingURL = failingURL.standardizedFileURL
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.standardizedFileURL == failingURL {
            throw InjectedFileSystemError.failure
        }
        try super.removeItem(at: URL)
    }
}

private extension Capture {
    static func fixture(audioFilename: String? = nil) -> Capture {
        Capture(
            id: UUID(),
            title: "Sample",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            transcript: "Merhaba",
            intent: .brainstorm,
            status: .completed,
            durationSeconds: 1.5,
            audioFilename: audioFilename
        )
    }
}
