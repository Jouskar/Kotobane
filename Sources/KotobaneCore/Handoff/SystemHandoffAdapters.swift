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
    private let applicationURLForURL: @MainActor (URL) -> URL?
    private let openApplication: @MainActor (URL, URL?) async -> OpenedApplication?
    private let activationWaiter: ApplicationActivationWaiter

    public init() {
        self.init(
            applicationURLForBundleIdentifier: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            },
            applicationURLForURL: {
                NSWorkspace.shared.urlForApplication(toOpen: $0)
            },
            openApplication: Self.openApplication,
            activationWaiter: ApplicationActivationWaiter(
                timeout: .seconds(3),
                pollInterval: .milliseconds(50)
            )
        )
    }

    init(
        applicationURLForBundleIdentifier: @escaping @MainActor (String) -> URL?,
        applicationURLForURL: @escaping @MainActor (URL) -> URL?,
        openApplication: @escaping @MainActor (URL, URL?) async -> OpenedApplication?,
        activationWaiter: ApplicationActivationWaiter
    ) {
        self.applicationURLForBundleIdentifier = applicationURLForBundleIdentifier
        self.applicationURLForURL = applicationURLForURL
        self.openApplication = openApplication
        self.activationWaiter = activationWaiter
    }

    public func open(_ destination: Destination) async -> Bool {
        if let bundleIdentifier = destination.bundleIdentifier,
           let applicationURL = applicationURLForBundleIdentifier(bundleIdentifier),
           await openAndWaitForActivation(
               applicationURL: applicationURL,
               contentURL: nil
           )
        {
            return true
        }

        guard let fallbackURL = destination.url,
              let handlerApplicationURL = applicationURLForURL(fallbackURL)
        else {
            return false
        }
        return await openAndWaitForActivation(
            applicationURL: handlerApplicationURL,
            contentURL: fallbackURL
        )
    }

    private func openAndWaitForActivation(
        applicationURL: URL,
        contentURL: URL?
    ) async -> Bool {
        guard let application = await openApplication(applicationURL, contentURL) else {
            return false
        }
        return await activationWaiter.waitUntilActive(application)
    }

    private static func openApplication(
        at applicationURL: URL,
        contentURL: URL?
    ) async -> OpenedApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        return await withCheckedContinuation { continuation in
            let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = {
                application,
                error in
                guard let application, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: OpenedApplication(
                        isActive: { application.isActive }
                    )
                )
            }

            if let contentURL {
                NSWorkspace.shared.open(
                    [contentURL],
                    withApplicationAt: applicationURL,
                    configuration: configuration,
                    completionHandler: completion
                )
            } else {
                NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration,
                    completionHandler: completion
                )
            }
        }
    }
}

final class OpenedApplication: @unchecked Sendable {
    private let activityChecking: @MainActor () -> Bool

    init(isActive: @escaping @MainActor () -> Bool) {
        self.activityChecking = isActive
    }

    @MainActor
    var isActive: Bool {
        activityChecking()
    }
}

@MainActor
struct ApplicationActivationWaiter {
    private let timeout: Duration
    private let pollInterval: Duration
    private let elapsed: @MainActor () -> Duration
    private let sleep: @MainActor (Duration) async throws -> Void

    init(timeout: Duration, pollInterval: Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        self.init(
            timeout: timeout,
            pollInterval: pollInterval,
            elapsed: { start.duration(to: clock.now) },
            sleep: { try await clock.sleep(for: $0) }
        )
    }

    init(
        timeout: Duration,
        pollInterval: Duration,
        elapsed: @escaping @MainActor () -> Duration,
        sleep: @escaping @MainActor (Duration) async throws -> Void
    ) {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.elapsed = elapsed
        self.sleep = sleep
    }

    func waitUntilActive(_ application: OpenedApplication) async -> Bool {
        let startedAt = elapsed()
        while true {
            if application.isActive {
                return true
            }

            let elapsedDuration = max(.zero, elapsed() - startedAt)
            guard timeout > .zero,
                  pollInterval > .zero,
                  elapsedDuration < timeout
            else {
                return false
            }

            let remaining = timeout - elapsedDuration
            do {
                try await sleep(min(pollInterval, remaining))
            } catch {
                return false
            }
        }
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
