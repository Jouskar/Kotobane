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

@Test func versionTwoSettingsRequirePastePreference() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appending(path: "settings.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(#"{"version":2,"languageHint":"Turkish","model":"small","audioRetention":"deleteAfterTranscription","shortcut":{"keyCode":49,"modifiers":3}}"#.utf8).write(to: settingsURL)

    #expect(throws: (any Error).self) { try SettingsStore(url: settingsURL).load() }
}

@Test(arguments: [0, 3]) func unsupportedSettingsVersionsAreRejected(_ version: Int) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appending(path: "settings.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(#"{"version":\#(version),"languageHint":"Turkish","model":"small","audioRetention":"deleteAfterTranscription","shortcut":{"keyCode":49,"modifiers":3},"pasteAfterOpening":false}"#.utf8).write(to: settingsURL)

    #expect(throws: SettingsStoreError.unsupportedVersion(version)) {
        try SettingsStore(url: settingsURL).load()
    }
}

@Test func danglingSettingsSymlinkIsRejectedInsteadOfReturningDefaults() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let settingsURL = root.appending(path: "settings.json")
    try FileManager.default.createSymbolicLink(
        at: settingsURL,
        withDestinationURL: root.appending(path: "missing-settings.json")
    )

    #expect(throws: SettingsStoreError.symbolicLink(settingsURL)) {
        try SettingsStore(url: settingsURL).load()
    }
    #expect(throws: SettingsStoreError.symbolicLink(settingsURL)) {
        try SettingsStore(url: settingsURL).save(.defaults)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "missing-settings.json").path))
}

@Test func liveSettingsSymlinkIsRejectedWithoutChangingItsTarget() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outsideURL = root.appending(path: "outside.json")
    let original = Data(#"{"outside":true}"#.utf8)
    try original.write(to: outsideURL)
    let settingsURL = root.appending(path: "settings.json")
    try FileManager.default.createSymbolicLink(at: settingsURL, withDestinationURL: outsideURL)
    let store = SettingsStore(url: settingsURL)

    #expect(throws: SettingsStoreError.symbolicLink(settingsURL)) { try store.load() }
    #expect(throws: SettingsStoreError.symbolicLink(settingsURL)) { try store.save(.defaults) }
    #expect(try Data(contentsOf: outsideURL) == original)
}

@Test func settingsSaveRoundTripsAndAtomicallyReplacesExistingFile() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appending(path: "settings.json")
    let store = SettingsStore(url: settingsURL)
    try store.save(.defaults)
    var changed = AppSettings.defaults
    changed.languageHint = "Japanese"
    changed.pasteAfterOpening = true

    try store.save(changed)

    #expect(try store.load() == changed)
}

@Test func settingsJSONUsesSortedTopLevelKeys() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsURL = root.appending(path: "settings.json")
    try SettingsStore(url: settingsURL).save(.defaults)

    let json = try String(contentsOf: settingsURL, encoding: .utf8)
    expectKeys(
        ["audioRetention", "languageHint", "model", "pasteAfterOpening", "shortcut", "version"],
        appearInOrderIn: json
    )
}

private func expectKeys(_ keys: [String], appearInOrderIn json: String) {
    var lowerBound = json.startIndex
    for key in keys {
        guard let range = json.range(of: "\"\(key)\"", range: lowerBound..<json.endIndex) else {
            Issue.record("Missing JSON key \(key)")
            return
        }
        lowerBound = range.upperBound
    }
}
