import SwiftUI
import KotobaneCore

struct CaptureDeskWindow: View {
    @Bindable var container: AppContainer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            captureCard
            recentCaptures
        }
        .padding(28)
        .frame(minWidth: 680, minHeight: 500)
        .onAppear { container.reloadHistory() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Kotobane")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Speak the thought. Keep the context.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Label(modelStatus, systemImage: modelReady ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(modelReady ? .green : .orange)
                Text("Audio stays on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var captureCard: some View {
        HStack(spacing: 20) {
            Image(systemName: container.capture.state.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(container.capture.state.isRecording ? .red : .accentColor)

            VStack(alignment: .leading, spacing: 7) {
                Text(captureTitle).font(.title3.weight(.semibold))
                Text(captureSubtitle).foregroundStyle(.secondary)
                if let snapshot = container.capture.state.recordingSnapshot {
                    RecordingWaveform(rmsLevel: snapshot.rmsLevel)
                    Text(
                        snapshot.partialTranscript.isEmpty
                            ? (snapshot.liveDraftMessage ?? "Listening for a live local draft…")
                            : snapshot.partialTranscript
                    )
                    .font(.caption)
                    .foregroundStyle(snapshot.liveDraftStatus == .unavailable ? .orange : .secondary)
                    .lineLimit(2)
                }
            }
            Spacer()
            captureButton
        }
        .padding(22)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var captureButton: some View {
        if container.capture.state.isRecording {
            Button("Stop") { Task { await container.stopCapture() } }
                .buttonStyle(.borderedProminent).tint(.red)
        } else {
            Button("Record") { Task { await container.startCapture() } }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
        }
    }

    private var recentCaptures: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent captures").font(.headline)
                Spacer()
                Button("History") { openWindow(id: "history") }
            }
            if container.history.isEmpty {
                ContentUnavailableView(
                    "No captures yet",
                    systemImage: "waveform",
                    description: Text("Start a recording when an idea arrives. You can edit every word before sharing it."))
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(container.history.prefix(4)) { capture in
                    Button {
                        container.openCapture(capture)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(capture.title.isEmpty ? "Untitled capture" : capture.title)
                                    .foregroundStyle(.primary).fontWeight(.medium)
                                Text(capture.transcript).lineLimit(1)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(capture.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    if capture.id != container.history.prefix(4).last?.id { Divider() }
                }
            }
        }
    }

    private var modelReady: Bool { container.modelManager.isReady(container.settings.model) }
    private var modelStatus: String { modelReady ? "Local model ready" : "Model needs setup" }
    private var isBusy: Bool {
        switch container.capture.state {
        case .requestingPermission, .transcribing: true
        case .idle, .recording, .reviewing, .failed: false
        }
    }
    private var captureTitle: String {
        switch container.capture.state {
        case .recording: "Recording"
        case .transcribing: "Transcribing locally"
        case .requestingPermission: "Requesting microphone access"
        case .failed: "Capture needs attention"
        case .idle, .reviewing: "Ready when you are"
        }
    }
    private var captureSubtitle: String {
        switch container.capture.state {
        case .recording: "Kotobane is listening only until you stop."
        case .transcribing: "Your recording stays on this Mac."
        case .requestingPermission: "macOS will ask before recording."
        case .failed: "Open the menu bar item for recovery actions."
        case .idle, .reviewing: "Capture a spoken thought without structuring it first."
        }
    }
}
