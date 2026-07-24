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

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
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
