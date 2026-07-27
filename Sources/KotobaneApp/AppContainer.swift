import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import KotobaneCore

@MainActor
@Observable
final class AppContainer {
    enum SettingsTab: Hashable {
        case general
        case models
        case destinations
        case privacy
    }

    enum Notice: Equatable {
        case success(String)
        case warning(String)
        case failure(String)

        var message: String {
            switch self {
            case .success(let message), .warning(let message), .failure(let message):
                message
            }
        }
    }

    var capture: CaptureController
    var modelManager: ModelManager
    var settings: AppSettings
    var reviewDraft: Capture?
    var selectedDestination: Destination = .codex
    var history: [Capture] = []
    var notice: Notice?
    var shortcutFailure: String?
    var historyFailure: String?
    var settingsFailure: String?
    var settingsTab: SettingsTab = .general
    var modelRemovalConfirmation: ModelChoice?
    var historyDeletionConfirmation: Capture?
    var fullDataDeletionConfirmation = false

    @ObservationIgnored private let directories: AppDirectories
    @ObservationIgnored private let captureStore: CaptureStore
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let authorizer: AVCaptureMicrophoneAuthorizer
    @ObservationIgnored private let recorder: AVAudioEngineRecorder
    @ObservationIgnored private let audioFiles: CaptureAudioFiles
    @ObservationIgnored private let transcriptionEngine: MLXHelperEngine
    @ObservationIgnored private let handoff: HandoffCoordinator
    @ObservationIgnored private let pasteAutomator: SystemPasteAutomator
    @ObservationIgnored private let shortcut: CarbonGlobalShortcut
    @ObservationIgnored private let overlay = RecorderOverlayPresenter()
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private var openWindowAction: ((String) -> Void)?

    private init(
        directories: AppDirectories,
        captureStore: CaptureStore,
        settingsStore: SettingsStore,
        authorizer: AVCaptureMicrophoneAuthorizer,
        recorder: AVAudioEngineRecorder,
        audioFiles: CaptureAudioFiles,
        transcriptionEngine: MLXHelperEngine,
        capture: CaptureController,
        modelManager: ModelManager,
        settings: AppSettings,
        handoff: HandoffCoordinator,
        pasteAutomator: SystemPasteAutomator,
        shortcut: CarbonGlobalShortcut,
        fileManager: FileManager
    ) {
        self.directories = directories
        self.captureStore = captureStore
        self.settingsStore = settingsStore
        self.authorizer = authorizer
        self.recorder = recorder
        self.audioFiles = audioFiles
        self.transcriptionEngine = transcriptionEngine
        self.capture = capture
        self.modelManager = modelManager
        self.settings = settings
        self.handoff = handoff
        self.pasteAutomator = pasteAutomator
        self.shortcut = shortcut
        self.fileManager = fileManager
    }

    static func live(fileManager: FileManager = .default) -> AppContainer {
        do {
            let directories = try AppDirectories(fileManager: fileManager)
            try fileManager.createDirectory(
                at: directories.root,
                withIntermediateDirectories: true
            )

            let captureStore = CaptureStore(root: directories.root, fileManager: fileManager)
            try captureStore.prepareDirectories()
            let settingsStore = SettingsStore(url: directories.settings, fileManager: fileManager)
            let settings: AppSettings
            let settingsLoadFailure: String?
            do {
                settings = try settingsStore.load()
                settingsLoadFailure = nil
            } catch {
                settings = .defaults
                settingsLoadFailure = "Settings could not be loaded. Defaults are active. \(error.localizedDescription)"
            }

            let authorizer = AVCaptureMicrophoneAuthorizer()
            let recorder = AVAudioEngineRecorder()
            let audioFiles = CaptureAudioFiles(root: directories.root, fileManager: fileManager)
            let transcriptionEngine = MLXHelperEngine(
                helperExecutableURL: bundledHelperURL(fileManager: fileManager),
                allowedAudioRoot: directories.root,
                timeout: .seconds(600)
            )
            let capture = makeCaptureController(
                settings: settings,
                authorizer: authorizer,
                recorder: recorder,
                transcriptionEngine: transcriptionEngine,
                captureStore: captureStore,
                audioFiles: audioFiles
            )
            let installer = ProcessModelInstaller(
                pythonURL: directories.root
                    .appending(path: "runtime/venv/bin/python", directoryHint: .notDirectory),
                installerScriptURL: bundledModelInstallerURL(fileManager: fileManager)
            )
            let modelManager = ModelManager(
                directories: directories,
                installer: installer,
                selectedModel: settings.model,
                fileManager: fileManager
            )
            let pasteAutomator = SystemPasteAutomator()
            let handoff = HandoffCoordinator(
                clipboard: SystemClipboardWriter(),
                opener: SystemDestinationOpener(),
                paste: pasteAutomator,
                exporter: SystemMarkdownExporter()
            )
            let container = AppContainer(
                directories: directories,
                captureStore: captureStore,
                settingsStore: settingsStore,
                authorizer: authorizer,
                recorder: recorder,
                audioFiles: audioFiles,
                transcriptionEngine: transcriptionEngine,
                capture: capture,
                modelManager: modelManager,
                settings: settings,
                handoff: handoff,
                pasteAutomator: pasteAutomator,
                shortcut: CarbonGlobalShortcut(),
                fileManager: fileManager
            )
            container.settingsFailure = settingsLoadFailure
            container.reloadHistory()
            container.registerShortcut()
            return container
        } catch {
            fatalError("Kotobane could not prepare its private Application Support directory: \(error)")
        }
    }

    func installWindowAction(_ action: @escaping (String) -> Void) {
        openWindowAction = action
    }

    func toggleCapture() {
        Task {
            if capture.state.isRecording {
                await stopCapture()
            } else {
                await startCapture()
            }
        }
    }

    func startCapture() async {
        notice = nil
        await capture.start()
        synchronizeCapturePresentation()
    }

    func stopCapture() async {
        await capture.stop()
        synchronizeCapturePresentation()
        if case .reviewing(let capture) = capture.state {
            reviewDraft = capture
            reloadHistory()
            openWindowAction?("review")
        }
    }

    func cancelCapture() async {
        await capture.cancel()
        overlay.hide()
        rebuildCaptureControllerIfIdle()
    }

    func retryCapture() async {
        notice = nil
        await capture.retry()
        synchronizeCapturePresentation()
        if case .reviewing(let capture) = capture.state {
            reviewDraft = capture
            reloadHistory()
            openWindowAction?("review")
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func exportPreservedAudio() {
        guard let source = capture.state.failure?.preservedAudioURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            notice = .success("A copy of the preserved recording was exported.")
        } catch {
            notice = .failure("The recording could not be exported. \(error.localizedDescription)")
        }
    }

    func deleteFailedCapture() {
        Task {
            await cancelCapture()
            notice = .success("The failed capture and its temporary audio were deleted.")
        }
    }

    func prepareCurrentReview() {
        if reviewDraft == nil, case .reviewing(let capture) = capture.state {
            reviewDraft = capture
        }
    }

    func openCapture(_ capture: Capture) {
        reviewDraft = capture
        notice = nil
        openWindowAction?("review")
    }

    @discardableResult
    func saveReview() -> Bool {
        guard var capture = reviewDraft else { return false }
        capture.modifiedAt = Date()
        do {
            try captureStore.save(capture)
            reviewDraft = capture
            reloadHistory()
            notice = .success("Capture changes were saved locally.")
            return true
        } catch {
            notice = .failure("The capture could not be saved. Check storage access, then retry.")
            return false
        }
    }

    func handoffReview() {
        guard saveReview(), let capture = reviewDraft else { return }
        let brief = BriefComposer.compose(
            intent: capture.intent,
            transcript: capture.transcript
        )
        Task {
            do {
                let result = try await handoff.perform(
                    brief: brief,
                    destination: selectedDestination,
                    pasteAfterOpening: settings.pasteAfterOpening
                )
                notice = handoffNotice(result)
            } catch {
                notice = .failure(
                    "The handoff could not be completed. Your capture remains saved; retry or choose Clipboard."
                )
            }
        }
    }

    func retryHandoff() {
        handoffReview()
    }

    func reloadHistory() {
        do {
            history = try captureStore.loadAll().sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString > $1.id.uuidString
                }
                return $0.createdAt > $1.createdAt
            }
            historyFailure = nil
        } catch {
            historyFailure = "Local history could not be loaded. \(error.localizedDescription)"
        }
    }

    func deleteHistoryCapture(_ capture: Capture) {
        do {
            try captureStore.delete(id: capture.id)
            if reviewDraft?.id == capture.id {
                reviewDraft = nil
            }
            reloadHistory()
            notice = .success("The capture and any retained audio were deleted.")
        } catch {
            historyFailure = "The capture could not be deleted. \(error.localizedDescription)"
        }
        historyDeletionConfirmation = nil
    }

    func saveSettings() {
        settings.version = AppSettings.currentVersion
        do {
            try settingsStore.save(settings)
            settingsFailure = nil
            registerShortcut()
            modelManager.refresh(settings.model)
            rebuildCaptureControllerIfIdle()
            notice = .success("Settings were saved.")
        } catch {
            settingsFailure = "Settings could not be saved. \(error.localizedDescription)"
        }
    }

    func setPasteAfterOpening(_ enabled: Bool) {
        settings.pasteAfterOpening = enabled
        if enabled {
            _ = pasteAutomator.isTrusted(promptIfNeeded: true)
        }
        saveSettings()
    }

    func showSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func showModelSettings() {
        settingsTab = .models
        showSettings()
    }

    func installSelectedModel() {
        let model = settings.model
        Task {
            await modelManager.install(model)
        }
    }

    func retryModelInstallation() {
        installSelectedModel()
    }

    func removeModel(_ model: ModelChoice) {
        Task {
            await modelManager.delete(model)
            modelRemovalConfirmation = nil
        }
    }

    func deleteAllLocalData() {
        Task {
            await capture.cancel()
            overlay.hide()
            do {
                try captureStore.deleteAll()
                let temporary = directories.captures
                    .appending(path: ".temporary", directoryHint: .isDirectory)
                if fileManager.fileExists(atPath: temporary.path) {
                    try fileManager.removeItem(at: temporary)
                }
                for model in ModelChoice.allCases {
                    await modelManager.delete(model)
                    if case .failed(let failure) = modelManager.state {
                        throw LocalDataDeletionError.model(failure)
                    }
                }
                reviewDraft = nil
                history = []
                fullDataDeletionConfirmation = false
                modelManager.refresh(settings.model)
                rebuildCaptureControllerIfIdle()
                notice = .success("All captures, recordings, temporary audio, and models were deleted.")
            } catch {
                fullDataDeletionConfirmation = false
                notice = .failure(
                    "Some local data could not be deleted. Close files using Kotobane data, then retry."
                )
                reloadHistory()
            }
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func registerShortcut() {
        shortcut.unregister()
        do {
            try shortcut.register(settings.shortcut) { [weak self] in
                self?.toggleCapture()
            }
            shortcutFailure = nil
        } catch GlobalShortcutError.conflict {
            shortcutFailure = "That shortcut is already used. Menu-bar recording remains available."
        } catch {
            shortcutFailure = "The global shortcut could not be registered. Menu-bar recording remains available."
        }
    }

    private func synchronizeCapturePresentation() {
        switch capture.state {
        case .recording:
            overlay.show(container: self)
        default:
            overlay.hide()
        }
    }

    private func rebuildCaptureControllerIfIdle() {
        guard capture.state == .idle else { return }
        capture = Self.makeCaptureController(
            settings: settings,
            authorizer: authorizer,
            recorder: recorder,
            transcriptionEngine: transcriptionEngine,
            captureStore: captureStore,
            audioFiles: audioFiles
        )
    }

    private static func makeCaptureController(
        settings: AppSettings,
        authorizer: AVCaptureMicrophoneAuthorizer,
        recorder: AVAudioEngineRecorder,
        transcriptionEngine: MLXHelperEngine,
        captureStore: CaptureStore,
        audioFiles: CaptureAudioFiles
    ) -> CaptureController {
        CaptureController(
            authorizer: authorizer,
            recorder: recorder,
            transcriptionEngine: transcriptionEngine,
            store: captureStore,
            audioFiles: audioFiles,
            retention: settings.audioRetention,
            languageHint: settings.languageHint,
            model: settings.model,
            defaultIntent: .brainstorm
        )
    }

    private func handoffNotice(_ result: HandoffResult) -> Notice {
        switch result {
        case .copied:
            .success("The brief was copied to the clipboard.")
        case .exportCancelled:
            .warning("Markdown export was cancelled. The capture remains saved.")
        case .exported(let url):
            .success("The Markdown brief was exported to \(url.lastPathComponent).")
        case .activated:
            .success("The brief was copied and the destination was opened. Paste when ready.")
        case .pasted:
            .success("The brief was copied, the destination was opened, and paste was requested.")
        case .manualPasteRequired(let reason):
            switch reason {
            case .destinationUnavailable:
                .warning("The brief is on the clipboard, but the destination could not be opened. Open it manually and paste.")
            case .accessibilityDenied:
                .warning("The brief is on the clipboard. Allow Accessibility access or paste it manually.")
            case .pasteFailed:
                .warning("The brief is on the clipboard, but automatic paste failed. Paste it manually.")
            }
        }
    }

    private static func bundledHelperURL(fileManager: FileManager) -> URL {
        let bundled = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/kotobane_helper.py", directoryHint: .notDirectory)
        if fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appending(path: "helper/kotobane_helper.py", directoryHint: .notDirectory)
    }

    private static func bundledModelInstallerURL(fileManager: FileManager) -> URL {
        let bundled = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/model_install.py", directoryHint: .notDirectory)
        if fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appending(path: "helper/model_install.py", directoryHint: .notDirectory)
    }
}

private enum LocalDataDeletionError: Error {
    case model(ModelManagementFailure)
}

@MainActor
private final class ProcessModelInstaller: ModelInstallerRunning {
    private let pythonURL: URL
    private let installerScriptURL: URL

    init(pythonURL: URL, installerScriptURL: URL) {
        self.pythonURL = pythonURL
        self.installerScriptURL = installerScriptURL
    }

    func run(_ request: ModelInstallRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
                continuation.finish(
                    throwing: ModelInstallerFailure(
                        code: "runtime_unavailable",
                        message: "Install Kotobane's local runtime before downloading a model."
                    )
                )
                return
            }
            guard FileManager.default.fileExists(atPath: installerScriptURL.path) else {
                continuation.finish(
                    throwing: ModelInstallerFailure(
                        code: "installer_unavailable",
                        message: "The bundled model installer is missing."
                    )
                )
                return
            }

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = pythonURL
            process.currentDirectoryURL = installerScriptURL.deletingLastPathComponent()
            process.arguments = [
                "-c",
                Self.installProgram,
                request.repository,
                request.destinationURL.path,
                String(request.expectedBytes),
                String(request.availableBytes),
            ]
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { process in
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                let diagnostics = stderr.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    let lines = String(decoding: output, as: UTF8.self)
                        .split(whereSeparator: \.isNewline)
                    for line in lines {
                        continuation.yield(String(line))
                    }
                    continuation.finish()
                } else {
                    let message = String(decoding: diagnostics, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.finish(
                        throwing: ModelInstallerFailure(
                            code: "installer_failed",
                            message: message.isEmpty
                                ? "The model installer exited with status \(process.terminationStatus)."
                                : message
                        )
                    )
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private static let installProgram = """
    import json
    import sys
    from pathlib import Path
    from model_install import install_model
    install_model(sys.argv[1], Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))
    print(json.dumps({"status": "completed"}, separators=(",", ":")), flush=True)
    """
}
