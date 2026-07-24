import AppKit
@preconcurrency import ApplicationServices
import Foundation
import UniformTypeIdentifiers

public enum SystemHandoffError: Error, Equatable {
    case clipboardWriteFailed
}

@MainActor
public struct SystemClipboardWriter: ClipboardWriting {
    public init() {}

    public func write(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw SystemHandoffError.clipboardWriteFailed
        }
    }
}

@MainActor
public struct SystemDestinationOpener: DestinationOpening {
    private let applicationURLForBundleIdentifier: @MainActor (String) -> URL?
    private let launchApplication: @MainActor (URL) async -> Bool
    private let openURL: @MainActor (URL) -> Bool

    public init() {
        self.init(
            applicationURLForBundleIdentifier: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            },
            launchApplication: { applicationURL in
                await withCheckedContinuation { continuation in
                    NSWorkspace.shared.openApplication(
                        at: applicationURL,
                        configuration: NSWorkspace.OpenConfiguration()
                    ) { application, error in
                        continuation.resume(returning: application != nil && error == nil)
                    }
                }
            },
            openURL: { NSWorkspace.shared.open($0) }
        )
    }

    init(
        applicationURLForBundleIdentifier: @escaping @MainActor (String) -> URL?,
        launchApplication: @escaping @MainActor (URL) async -> Bool,
        openURL: @escaping @MainActor (URL) -> Bool
    ) {
        self.applicationURLForBundleIdentifier = applicationURLForBundleIdentifier
        self.launchApplication = launchApplication
        self.openURL = openURL
    }

    public func open(_ destination: Destination) async -> Bool {
        if let bundleIdentifier = destination.bundleIdentifier,
           let applicationURL = applicationURLForBundleIdentifier(bundleIdentifier),
           await launchApplication(applicationURL)
        {
            return true
        }

        guard let fallbackURL = destination.url else {
            return false
        }
        return openURL(fallbackURL)
    }
}

@MainActor
public struct SystemPasteAutomator: PasteAutomating {
    private let trustChecking: @MainActor (Bool) -> Bool
    private let commandVPosting: @MainActor () -> Bool

    public init() {
        self.init(
            trustChecking: { promptIfNeeded in
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                return AXIsProcessTrustedWithOptions(
                    [promptKey: promptIfNeeded] as CFDictionary
                )
            },
            commandVPosting: Self.postCommandV
        )
    }

    init(
        trustChecking: @escaping @MainActor (Bool) -> Bool,
        commandVPosting: @escaping @MainActor () -> Bool
    ) {
        self.trustChecking = trustChecking
        self.commandVPosting = commandVPosting
    }

    public func isTrusted(promptIfNeeded: Bool) -> Bool {
        trustChecking(promptIfNeeded)
    }

    public func paste() -> Bool {
        commandVPosting()
    }

    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(9),
            keyDown: true
        ),
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(9),
            keyDown: false
        )
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
public struct SystemMarkdownExporter: MarkdownExporting {
    private let destinationChoosing: @MainActor () async -> URL?
    private let writer: AtomicFileWriter

    public init(writer: AtomicFileWriter = AtomicFileWriter()) {
        self.init(destinationChoosing: Self.chooseDestination, writer: writer)
    }

    init(
        destinationChoosing: @escaping @MainActor () async -> URL?,
        writer: AtomicFileWriter
    ) {
        self.destinationChoosing = destinationChoosing
        self.writer = writer
    }

    public func export(_ markdown: String) async throws -> URL? {
        guard let destination = await destinationChoosing() else {
            return nil
        }
        try writer.write(Data(markdown.utf8), to: destination)
        return destination
    }

    private static func chooseDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Kotobane Brief.md"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
