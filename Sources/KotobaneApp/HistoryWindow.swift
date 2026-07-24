import SwiftUI
import KotobaneCore

struct HistoryWindow: View {
    @Bindable var container: AppContainer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Local History")
                    .font(.largeTitle.bold())
                Spacer()
                Button {
                    container.reloadHistory()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }

            if let failure = container.historyFailure {
                HStack {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry") {
                        container.reloadHistory()
                    }
                }
            }

            if container.history.isEmpty {
                ContentUnavailableView(
                    "No Captures",
                    systemImage: "tray",
                    description: Text("Completed captures stay on this Mac and appear here.")
                )
            } else {
                List(container.history) { capture in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capture.title.isEmpty ? "Untitled Capture" : capture.title)
                                .font(.headline)
                            HStack {
                                Text(capture.intent.displayName)
                                Text(capture.createdAt, format: .dateTime)
                                Text(duration(capture.durationSeconds))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(capture.transcript)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") {
                            container.openCapture(capture)
                            openWindow(id: "review")
                        }
                        Button(role: .destructive) {
                            container.historyDeletionConfirmation = capture
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete capture")
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }

            if let notice = container.notice {
                NoticeView(notice: notice)
            }
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 400)
        .onAppear {
            container.installWindowAction { id in
                openWindow(id: id)
            }
            container.reloadHistory()
        }
        .confirmationDialog(
            "Delete this capture?",
            isPresented: deleteConfirmationPresented,
            titleVisibility: .visible,
            presenting: container.historyDeletionConfirmation
        ) { capture in
            Button("Delete Capture", role: .destructive) {
                container.deleteHistoryCapture(capture)
            }
            Button("Cancel", role: .cancel) {
                container.historyDeletionConfirmation = nil
            }
        } message: { _ in
            Text("The transcript metadata and any retained recording will be permanently deleted.")
        }
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { container.historyDeletionConfirmation != nil },
            set: {
                if !$0 {
                    container.historyDeletionConfirmation = nil
                }
            }
        )
    }

    private func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
