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
