import Foundation

@MainActor
public protocol ClipboardWriting {
    func write(_ text: String) throws
}

@MainActor
public protocol DestinationOpening {
    func open(_ destination: Destination) async -> Bool
}

@MainActor
public protocol PasteAutomating {
    func isTrusted(promptIfNeeded: Bool) -> Bool
    func paste() -> Bool
}

@MainActor
public protocol MarkdownExporting {
    func export(_ markdown: String) async throws -> URL?
}

public enum ManualPasteReason: Equatable, Sendable {
    case destinationUnavailable
    case accessibilityDenied
    case pasteFailed
}

public enum HandoffResult: Equatable, Sendable {
    case copied
    case exportCancelled
    case exported(URL)
    case activated(pasteAttempted: Bool)
    case pasted
    case manualPasteRequired(reason: ManualPasteReason)
}

@MainActor
public struct HandoffCoordinator {
    private let clipboard: any ClipboardWriting
    private let opener: any DestinationOpening
    private let paste: any PasteAutomating
    private let exporter: any MarkdownExporting

    public init(
        clipboard: any ClipboardWriting,
        opener: any DestinationOpening,
        paste: any PasteAutomating,
        exporter: any MarkdownExporting
    ) {
        self.clipboard = clipboard
        self.opener = opener
        self.paste = paste
        self.exporter = exporter
    }

    public func perform(
        brief: String,
        destination: Destination,
        pasteAfterOpening: Bool
    ) async throws -> HandoffResult {
        switch destination {
        case .clipboard:
            try clipboard.write(brief)
            return .copied

        case .markdown:
            guard let destinationURL = try await exporter.export(brief) else {
                return .exportCancelled
            }
            return .exported(destinationURL)

        case .codex, .claude:
            try clipboard.write(brief)
            guard await opener.open(destination) else {
                return .manualPasteRequired(reason: .destinationUnavailable)
            }

            guard pasteAfterOpening else {
                return .activated(pasteAttempted: false)
            }
            guard paste.isTrusted(promptIfNeeded: true) else {
                return .manualPasteRequired(reason: .accessibilityDenied)
            }
            guard paste.paste() else {
                return .manualPasteRequired(reason: .pasteFailed)
            }
            return .pasted
        }
    }
}
