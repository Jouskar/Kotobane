import Foundation
import Testing
@testable import KotobaneCore

@Test func defaultsFavorPrivateTurkishWorkflow() {
    let settings = AppSettings.defaults
    #expect(settings.version == AppSettings.currentVersion)
    #expect(settings.languageHint == "Turkish")
    #expect(settings.model == .small)
    #expect(settings.audioRetention == .deleteAfterTranscription)
    #expect(settings.shortcut == .init(keyCode: 49, modifiers: [.control, .option]))
    #expect(!settings.pasteAfterOpening)
}

@Test func missingSettingsReturnDefaults() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try SettingsStore(url: root.appending(path: "settings.json")).load() == .defaults)
}

@Test func corruptSettingsAreReported() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "settings.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: url)

    #expect(throws: (any Error).self) { try SettingsStore(url: url).load() }
}

@Test func versionOneSettingsMigrateNewPastePreferenceToDisabled() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appending(path: "settings.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(#"{"version":1,"languageHint":"Turkish","model":"small","audioRetention":"deleteAfterTranscription","shortcut":{"keyCode":49,"modifiers":3}}"#.utf8).write(to: settingsURL)

    let migrated = try SettingsStore(url: settingsURL).load()

    #expect(!migrated.pasteAfterOpening)
    #expect(migrated.version == AppSettings.currentVersion)
}
