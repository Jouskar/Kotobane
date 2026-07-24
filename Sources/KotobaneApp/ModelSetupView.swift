import AppKit
import SwiftUI
import KotobaneCore

struct ModelSetupView: View {
    @Bindable var container: AppContainer

    var body: some View {
        Form {
            Section("Local transcription model") {
                Picker("Model", selection: modelSelection) {
                    ForEach(ModelChoice.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                if let entry = ModelCatalog.official[container.settings.model] {
                    LabeledContent("Download") {
                        Text(entry.displayDownloadBytes, format: .byteCount(style: .file))
                    }
                    LabeledContent("Minimum free space") {
                        Text(entry.requiredCapacityBytes, format: .byteCount(style: .file))
                    }
                    Text(
                        "Model installation is the only network-dependent setup. Recording and transcription make no network request after setup."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Status") {
                stateContent
            }

            Section {
                HStack {
                    if container.modelManager.isReady(container.settings.model) {
                        Button("Remove Model…", role: .destructive) {
                            container.modelRemovalConfirmation = container.settings.model
                        }
                    } else {
                        Button("Install Model") {
                            container.installSelectedModel()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDownloading)
                    }
                    Spacer()
                    Button("Refresh") {
                        container.modelManager.refresh(container.settings.model)
                    }
                    .disabled(isDownloading)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove this local model?",
            isPresented: modelRemovalPresented,
            titleVisibility: .visible,
            presenting: container.modelRemovalConfirmation
        ) { model in
            Button("Remove \(model.displayName)", role: .destructive) {
                container.removeModel(model)
            }
            Button("Cancel", role: .cancel) {
                container.modelRemovalConfirmation = nil
            }
        } message: { model in
            Text("\(model.displayName) and any interrupted staging data will be deleted. Captures and transcripts are not affected.")
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch container.modelManager.state {
        case .notInstalled:
            Label("Not installed", systemImage: "arrow.down.circle")
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                Label("Downloading and validating…", systemImage: "arrow.down.circle.fill")
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text(progressDescription(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready for offline transcription", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Label(modelFailureMessage(failure), systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                HStack {
                    Button("Retry Installation") {
                        container.retryModelInstallation()
                    }
                    if requiresStorageRecovery(failure) {
                        Button("Open Storage Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    Button("Remove Partial Download", role: .destructive) {
                        container.modelRemovalConfirmation = container.settings.model
                    }
                }
            }
        }
    }

    private var modelSelection: Binding<ModelChoice> {
        Binding(
            get: { container.settings.model },
            set: { model in
                container.settings.model = model
                container.modelManager.refresh(model)
                container.saveSettings()
            }
        )
    }

    private var modelRemovalPresented: Binding<Bool> {
        Binding(
            get: { container.modelRemovalConfirmation != nil },
            set: {
                if !$0 {
                    container.modelRemovalConfirmation = nil
                }
            }
        )
    }

    private var isDownloading: Bool {
        if case .downloading = container.modelManager.state {
            return true
        }
        return false
    }

    private func progressDescription(_ progress: ModelDownloadProgress) -> String {
        let completed = progress.completedBytes.formatted(.byteCount(style: .file))
        if let total = progress.totalBytes {
            return "\(completed) of \(total.formatted(.byteCount(style: .file)))"
        }
        return completed
    }

    private func requiresStorageRecovery(_ failure: ModelManagementFailure) -> Bool {
        if case .insufficientSpace = failure { return true }
        return false
    }

    private func modelFailureMessage(_ failure: ModelManagementFailure) -> String {
        switch failure {
        case .insufficientSpace(let required, let available):
            "Not enough disk space. \(required.formatted(.byteCount(style: .file))) required; \(available.formatted(.byteCount(style: .file))) available."
        case .capacityUnavailable(let message):
            "Available disk space could not be checked. \(message)"
        case .installer(let code, let message):
            "\(message) (\(code))"
        case .invalidReadyMarker:
            "The downloaded model failed integrity validation. Remove it and retry."
        case .unsafeModelPath:
            "The model directory is unsafe. Remove the linked path, then retry."
        case .deletionFailed(let message):
            "The model could not be removed. \(message)"
        case .unsupportedModel:
            "This model is not supported by this version of Kotobane."
        }
    }
}

extension ModelChoice {
    var displayName: String {
        switch self {
        case .small: "Qwen3-ASR 0.6B (Recommended)"
        case .accuracy: "Qwen3-ASR 1.7B (Higher accuracy)"
        }
    }
}
