import AppKit
import SwiftUI
import KotobaneCore

struct MenuBarContent: View {
    @Bindable var container: AppContainer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            captureAction

            if isBusy {
                Label(statusLabel, systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }

            if let failure = container.capture.state.failure {
                Divider()
                failureSection(failure)
            }

            if let shortcutFailure = container.shortcutFailure {
                Divider()
                Text(shortcutFailure)
                Button("Choose Another Shortcut…") {
                    container.showSettings()
                }
            }

            Divider()

            Menu("Recent Captures") {
                if container.history.isEmpty {
                    Text("No captures yet")
                } else {
                    ForEach(container.history.prefix(8)) { capture in
                        Button(capture.title.isEmpty ? "Untitled Capture" : capture.title) {
                            container.openCapture(capture)
                        }
                    }
                }
                Divider()
                Button("Open History…") {
                    openWindow(id: "history")
                }
            }

            Button("Settings…") {
                container.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()
            Button("Quit Kotobane") {
                container.quit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .onAppear {
            container.installWindowAction { id in
                openWindow(id: id)
            }
            container.reloadHistory()
        }
    }

    @ViewBuilder
    private var captureAction: some View {
        if container.capture.state.isRecording {
            Button("Stop Capture") {
                Task { await container.stopCapture() }
            }
            .keyboardShortcut(.return, modifiers: [])
        } else {
            Button("Start Capture") {
                Task { await container.startCapture() }
            }
            .disabled(isBusy)
        }
    }

    private var isBusy: Bool {
        switch container.capture.state {
        case .requestingPermission, .transcribing:
            true
        case .idle, .recording, .reviewing, .failed:
            false
        }
    }

    private var statusLabel: String {
        switch container.capture.state {
        case .requestingPermission:
            "Requesting microphone access…"
        case .transcribing:
            "Transcribing locally…"
        default:
            ""
        }
    }

    @ViewBuilder
    private func failureSection(_ failure: CaptureFailure) -> some View {
        Text(failure.message)
        switch failure.recovery {
        case .openMicrophoneSettings:
            Button("Open Microphone Settings") {
                container.openMicrophoneSettings()
            }
            Button("Try Again") {
                Task { await container.retryCapture() }
            }
        case .retryRecording, .retryTranscription, .retryRetention:
            Button("Retry") {
                Task { await container.retryCapture() }
            }
        }

        if failure.preservedAudioURL != nil {
            Button("Export Preserved Audio…") {
                container.exportPreservedAudio()
            }
            Button("Delete Failed Capture", role: .destructive) {
                container.deleteFailedCapture()
            }
        }
    }
}
