import Foundation
import Testing
@testable import KotobaneCore

@MainActor
@Test func codexCopiesBeforeOpening() async throws {
    let events = HandoffEventRecorder()
    let coordinator = makeCoordinator(events: events)

    let result = try await coordinator.perform(
        brief: "brief",
        destination: .codex,
        pasteAfterOpening: false
    )

    #expect(events.values == ["copy:brief", "open:codex"])
    #expect(result == .activated(pasteAttempted: false))
}

@MainActor
@Test func clipboardOnlyCopiesWithoutOpeningOrAccessibility() async throws {
    let events = HandoffEventRecorder()
    let coordinator = makeCoordinator(events: events)

    let result = try await coordinator.perform(
        brief: "clipboard brief",
        destination: .clipboard,
        pasteAfterOpening: true
    )

    #expect(events.values == ["copy:clipboard brief"])
    #expect(result == .copied)
}

@MainActor
@Test func markdownExportUsesExporterWithoutClipboardOrAccessibility() async throws {
    let events = HandoffEventRecorder()
    let exportURL = URL(fileURLWithPath: "/tmp/Kotobane Brief.md")
    let coordinator = makeCoordinator(events: events, exportURL: exportURL)

    let result = try await coordinator.perform(
        brief: "# Exported brief",
        destination: .markdown,
        pasteAfterOpening: true
    )

    #expect(events.values == ["export:# Exported brief"])
    #expect(result == .exported(exportURL))
}

@MainActor
@Test func cancelledMarkdownExportIsReportedWithoutOtherHandoffActions() async throws {
    let events = HandoffEventRecorder()
    let coordinator = makeCoordinator(events: events, exportURL: nil)

    let result = try await coordinator.perform(
        brief: "brief",
        destination: .markdown,
        pasteAfterOpening: false
    )

    #expect(events.values == ["export:brief"])
    #expect(result == .exportCancelled)
}

@MainActor
@Test func unavailableDestinationStillCopiesFirstAndRequiresManualPaste() async throws {
    let events = HandoffEventRecorder()
    let coordinator = makeCoordinator(events: events, openSucceeds: false)

    let result = try await coordinator.perform(
        brief: "retained brief",
        destination: .codex,
        pasteAfterOpening: true
    )

    #expect(events.values == ["copy:retained brief", "open:codex"])
    #expect(result == .manualPasteRequired(reason: .destinationUnavailable))
}

@MainActor
@Test func accessibilityDenialKeepsSuccessfulCopyAndOpen() async throws {
    let events = HandoffEventRecorder()
    let coordinator = makeCoordinator(events: events, trusted: false)

    let result = try await coordinator.perform(
        brief: "brief",
        destination: .claude,
        pasteAfterOpening: true
    )

    #expect(events.values == [
        "copy:brief",
        "open:claude",
        "paste-trust-check:prompt",
    ])
    #expect(result == .manualPasteRequired(reason: .accessibilityDenied))
}

@MainActor
@Test func pasteFailureKeepsCopyAndReturnsManualPasteFallback() async throws {
    let events = HandoffEventRecorder()
    let coordinator = makeCoordinator(
        events: events,
        trusted: true,
        pasteSucceeds: false
    )

    let result = try await coordinator.perform(
        brief: "brief",
        destination: .codex,
        pasteAfterOpening: true
    )

    #expect(events.values == [
        "copy:brief",
        "open:codex",
        "paste-trust-check:prompt",
        "paste",
    ])
    #expect(result == .manualPasteRequired(reason: .pasteFailed))
}

@MainActor
@Test func successfulOptInPasteOccursOnlyAfterCopyAndOpen() async throws {
    let events = HandoffEventRecorder()
    let coordinator = makeCoordinator(events: events, trusted: true)

    let result = try await coordinator.perform(
        brief: "brief",
        destination: .claude,
        pasteAfterOpening: true
    )

    #expect(events.values == [
        "copy:brief",
        "open:claude",
        "paste-trust-check:prompt",
        "paste",
    ])
    #expect(result == .pasted)
}

@MainActor
@Test func copyFailurePreventsDestinationOpening() async {
    let events = HandoffEventRecorder()
    let coordinator = makeCoordinator(events: events, copyFails: true)

    await #expect(throws: HandoffFixtureError.copyFailed) {
        try await coordinator.perform(
            brief: "brief",
            destination: .codex,
            pasteAfterOpening: false
        )
    }
    #expect(events.values == ["copy:brief"])
}

@MainActor
@Test func systemOpenerFallsBackFromConfiguredBundleToConfiguredURL() async {
    let events = HandoffEventRecorder()
    let applicationURL = URL(fileURLWithPath: "/Applications/Codex.app")
    let opener = SystemDestinationOpener(
        applicationURLForBundleIdentifier: { bundleIdentifier in
            events.record("lookup:\(bundleIdentifier)")
            return applicationURL
        },
        launchApplication: { url in
            events.record("launch:\(url.path)")
            return false
        },
        openURL: { url in
            events.record("url:\(url.absoluteString)")
            return true
        }
    )

    let result = await opener.open(.codex)

    #expect(result)
    #expect(events.values == [
        "lookup:\(Destination.codex.bundleIdentifier!)",
        "launch:\(applicationURL.path)",
        "url:\(Destination.codex.url!.absoluteString)",
    ])
}

@MainActor
@Test func systemOpenerUsesConfiguredURLWhenBundleIsUnavailable() async {
    let events = HandoffEventRecorder()
    let opener = SystemDestinationOpener(
        applicationURLForBundleIdentifier: { bundleIdentifier in
            events.record("lookup:\(bundleIdentifier)")
            return nil
        },
        launchApplication: { _ in
            events.record("unexpected-launch")
            return true
        },
        openURL: { url in
            events.record("url:\(url.absoluteString)")
            return true
        }
    )

    let result = await opener.open(.claude)

    #expect(result)
    #expect(events.values == [
        "lookup:\(Destination.claude.bundleIdentifier!)",
        "url:\(Destination.claude.url!.absoluteString)",
    ])
}

@MainActor
@Test func systemMarkdownExporterAtomicallyWritesUTF8ToChosenURL() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appending(path: "Kotobane Brief.md")
    try Data("old".utf8).write(to: destination)
    let exporter = SystemMarkdownExporter(
        destinationChoosing: { destination },
        writer: AtomicFileWriter()
    )
    let markdown = "# Başlık\n\nTürkçe brief 🌱"

    let exportedURL = try await exporter.export(markdown)

    #expect(exportedURL == destination)
    #expect(try Data(contentsOf: destination) == Data(markdown.utf8))
    let siblings = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    )
    #expect(!siblings.contains { $0.lastPathComponent.hasSuffix(".tmp") })
}

@MainActor
@Test func systemPasteAutomatorForwardsOptionalAccessibilityPromptSemantics() {
    var prompts: [Bool] = []
    let paste = SystemPasteAutomator(
        trustChecking: { prompt in
            prompts.append(prompt)
            return prompt
        },
        commandVPosting: { true }
    )

    #expect(!paste.isTrusted(promptIfNeeded: false))
    #expect(paste.isTrusted(promptIfNeeded: true))
    #expect(prompts == [false, true])
}

@MainActor
private func makeCoordinator(
    events: HandoffEventRecorder,
    copyFails: Bool = false,
    openSucceeds: Bool = true,
    trusted: Bool = false,
    pasteSucceeds: Bool = true,
    exportURL: URL? = URL(fileURLWithPath: "/tmp/export.md")
) -> HandoffCoordinator {
    HandoffCoordinator(
        clipboard: HandoffSpyClipboard(events: events, fails: copyFails),
        opener: HandoffSpyOpener(events: events, succeeds: openSucceeds),
        paste: HandoffSpyPaste(
            events: events,
            trusted: trusted,
            succeeds: pasteSucceeds
        ),
        exporter: HandoffSpyExporter(events: events, url: exportURL)
    )
}

@MainActor
private final class HandoffEventRecorder {
    private(set) var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }
}

private enum HandoffFixtureError: Error {
    case copyFailed
}

@MainActor
private struct HandoffSpyClipboard: ClipboardWriting {
    let events: HandoffEventRecorder
    let fails: Bool

    func write(_ text: String) throws {
        events.record("copy:\(text)")
        if fails {
            throw HandoffFixtureError.copyFailed
        }
    }
}

@MainActor
private struct HandoffSpyOpener: DestinationOpening {
    let events: HandoffEventRecorder
    let succeeds: Bool

    func open(_ destination: Destination) async -> Bool {
        events.record("open:\(destination.rawValue)")
        return succeeds
    }
}

@MainActor
private struct HandoffSpyPaste: PasteAutomating {
    let events: HandoffEventRecorder
    let trusted: Bool
    let succeeds: Bool

    func isTrusted(promptIfNeeded: Bool) -> Bool {
        events.record("paste-trust-check:\(promptIfNeeded ? "prompt" : "no-prompt")")
        return trusted
    }

    func paste() -> Bool {
        events.record("paste")
        return succeeds
    }
}

@MainActor
private struct HandoffSpyExporter: MarkdownExporting {
    let events: HandoffEventRecorder
    let url: URL?

    func export(_ markdown: String) async throws -> URL? {
        events.record("export:\(markdown)")
        return url
    }
}
