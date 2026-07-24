import AppKit
import SwiftUI
import KotobaneCore

struct RecorderOverlay: View {
    @Bindable var container: AppContainer

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recording")
                        .font(.headline)
                    Spacer()
                    Text(elapsed)
                        .font(.system(.body, design: .monospaced))
                }
                ProgressView(value: Double(snapshot.rmsLevel), total: 1)
                    .progressViewStyle(.linear)
                    .tint(.red)
                    .accessibilityLabel("Microphone level")
                    .accessibilityValue("\(Int(snapshot.rmsLevel * 100)) percent")
            }
            .frame(width: 190)

            Button("Cancel", role: .cancel) {
                Task { await container.cancelCapture() }
            }
            Button("Stop") {
                Task { await container.stopCapture() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary)
        }
        .shadow(radius: 18, y: 8)
        .padding(18)
    }

    private var snapshot: RecordingSnapshot {
        container.capture.state.recordingSnapshot
            ?? RecordingSnapshot(elapsedSeconds: 0, rmsLevel: 0)
    }

    private var elapsed: String {
        let totalSeconds = max(0, Int(snapshot.elapsedSeconds))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

@MainActor
final class RecorderOverlayPresenter {
    private var panel: NSPanel?

    func show(container: AppContainer) {
        if panel == nil {
            let hostingController = NSHostingController(
                rootView: RecorderOverlay(container: container)
            )
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 110),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hostingController
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = true
            self.panel = panel
        }
        positionOnActiveScreen()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionOnActiveScreen() {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - panelSize.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}
