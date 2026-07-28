import SwiftUI
import KotobaneCore

struct ReviewWindow: View {
    @Bindable var container: AppContainer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if container.reviewDraft != nil {
                reviewForm
            } else {
                ContentUnavailableView(
                    "No Capture Selected",
                    systemImage: "waveform",
                    description: Text("Record a note or open a capture from local history.")
                )
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 500)
        .onAppear {
            container.installWindowAction { id in
                openWindow(id: id)
            }
            container.prepareCurrentReview()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Capture Review")
                    .font(.largeTitle.bold())
                Text("Edit every word before anything leaves this Mac.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("History") {
                openWindow(id: "history")
            }
        }
    }

    private var reviewForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Title", text: title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            VStack(alignment: .leading, spacing: 6) {
                Text("Transcript")
                    .font(.headline)
                TextEditor(text: transcript)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .frame(minHeight: 220)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Intent")
                        .font(.headline)
                    Picker("Intent", selection: intent) {
                        ForEach(CaptureIntent.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Send to")
                        .font(.headline)
                    Picker("Send to", selection: $container.selectedDestination) {
                        ForEach(Destination.builtIns, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }

            Text("Audio and transcript remain on this Mac until you send exported text.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if container.selectedDestination == .codex
                || container.selectedDestination == .claude {
                Text(
                    "Text submitted to \(container.selectedDestination.displayName) is governed by that product’s separate policies."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let notice = container.notice {
                NoticeView(notice: notice) {
                    container.retryHandoff()
                }
            }

            HStack {
                Spacer()
                Button("Save Changes") {
                    container.saveReview()
                }
                Button(primaryActionTitle) {
                    container.handoffReview()
                }
                .buttonStyle(.borderedProminent)
                .disabled(transcript.wrappedValue.isEmpty)
            }
        }
    }

    private var title: Binding<String> {
        Binding(
            get: { container.reviewDraft?.title ?? "" },
            set: { container.reviewDraft?.title = $0 }
        )
    }

    private var transcript: Binding<String> {
        Binding(
            get: { container.reviewDraft?.transcript ?? "" },
            set: { container.reviewDraft?.transcript = $0 }
        )
    }

    private var intent: Binding<CaptureIntent> {
        Binding(
            get: { container.reviewDraft?.intent ?? .brainstorm },
            set: { container.reviewDraft?.intent = $0 }
        )
    }

    private var primaryActionTitle: String {
        switch container.selectedDestination {
        case .clipboard:
            "Copy Brief"
        case .markdown:
            "Export Markdown…"
        case .codex, .claude:
            "Send to \(container.selectedDestination.displayName)"
        }
    }
}

struct NoticeView: View {
    let notice: AppContainer.Notice
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(notice.message, systemImage: icon)
                .foregroundStyle(color)
            Spacer()
            if case .failure = notice, let retry {
                Button("Retry", action: retry)
            }
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch notice {
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .failure: "xmark.octagon"
        }
    }

    private var color: Color {
        switch notice {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

extension CaptureIntent {
    var displayName: String {
        switch self {
        case .brainstorm: "Brainstorm"
        case .task: "Task"
        case .projectIdea: "Project Idea"
        case .meetingNote: "Meeting Note"
        case .freeform: "Freeform"
        case .transcriptOnly: "Transcript only"
        }
    }
}
