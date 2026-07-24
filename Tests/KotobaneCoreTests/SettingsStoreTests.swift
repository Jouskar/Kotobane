import XCTest
@testable import KotobaneCore

final class SettingsStoreTests: XCTestCase {
    func testDefaultsFavorPrivateTurkishWorkflow() {
        let settings = AppSettings.defaults
        XCTAssertEqual(settings.version, AppSettings.currentVersion)
        XCTAssertEqual(settings.languageHint, "Turkish")
        XCTAssertEqual(settings.model, .small)
        XCTAssertEqual(settings.audioRetention, .deleteAfterTranscription)
        XCTAssertEqual(settings.shortcut, .init(keyCode: 49, modifiers: [.control, .option]))
        XCTAssertFalse(settings.pasteAfterOpening)
    }
}
