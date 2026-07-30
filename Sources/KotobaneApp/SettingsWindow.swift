import SwiftUI
import KotobaneCore

struct SettingsWindow: View {
    @Bindable var container: AppContainer

    var body: some View {
        TabView(selection: $container.settingsTab) {
            general
                .tag(AppContainer.SettingsTab.general)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            ModelSetupView(container: container)
                .tag(AppContainer.SettingsTab.models)
                .tabItem {
                    Label("Models", systemImage: "externaldrive")
                }

            destinations
                .tag(AppContainer.SettingsTab.destinations)
                .tabItem {
                    Label("Destinations", systemImage: "arrow.up.forward.app")
                }

            privacy
                .tag(AppContainer.SettingsTab.privacy)
                .tabItem {
                    Label("Privacy", systemImage: "hand.raised")
                }
        }
        .padding(20)
        .frame(width: 650, height: 540)
    }

    private var general: some View {
        Form {
            Section("Capture") {
                TextField("Language hint", text: $container.settings.languageHint)

                Picker("Default model", selection: $container.settings.model) {
                    ForEach(ModelChoice.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                Picker("Recording retention", selection: $container.settings.audioRetention) {
                    Text("Delete after transcript is safely saved")
                        .tag(AudioRetentionPolicy.deleteAfterTranscription)
                    Text("Keep recordings with local history")
                        .tag(AudioRetentionPolicy.retain)
                }

                Toggle(
                    "Accurate final transcript after stopping",
                    isOn: $container.settings.accurateFinalTranscript
                )
                Text(
                    "On: run a final full-recording local pass. Off: finish with the rolling live draft for faster handoff."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Global shortcut") {
                HStack {
                    Toggle("Control", isOn: modifier(.control))
                    Toggle("Option", isOn: modifier(.option))
                    Toggle("Shift", isOn: modifier(.shift))
                    Toggle("Command", isOn: modifier(.command))
                }
                Stepper(
                    "Key code: \(container.settings.shortcut.keyCode)",
                    value: shortcutKeyCode,
                    in: 0...127
                )
                Text("Default: Control–Option–Space (key code 49).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let failure = container.shortcutFailure {
                    HStack {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Restore Default") {
                            container.settings.shortcut = AppSettings.defaults.shortcut
                            container.saveSettings()
                        }
                    }
                }
            }

            Section {
                Button("Save Settings") {
                    container.saveSettings()
                }
                .buttonStyle(.borderedProminent)
            }

            if let failure = container.settingsFailure {
                Section {
                    HStack {
                        Label(failure, systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Retry Save") {
                            container.saveSettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var destinations: some View {
        Form {
            Section("Built-in destinations") {
                ForEach(Destination.builtIns, id: \.self) { destination in
                    HStack {
                        Label(destination.displayName, systemImage: icon(destination))
                        Spacer()
                        if let bundleIdentifier = destination.bundleIdentifier {
                            Text(bundleIdentifier)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(destination == .clipboard ? "System clipboard" : "User-selected file")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Codex and Claude copy the complete brief before Kotobane attempts to open the destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paste automation") {
                Toggle(
                    "Paste after opening Codex or Claude",
                    isOn: Binding(
                        get: { container.settings.pasteAfterOpening },
                        set: { container.setPasteAfterOpening($0) }
                    )
                )
                Text(
                    "Off by default. Enabling this asks macOS for Accessibility access. If access is denied, Kotobane still copies the brief and opens the destination."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("Local by default") {
                Text("Audio and transcript remain on this Mac until you send exported text.")
                Text(
                    "Kotobane records only when you explicitly start a capture. It does not continuously listen, capture system audio, use cloud transcription, collect telemetry, or create an account."
                )
                .foregroundStyle(.secondary)
            }

            Section("Delete all local data") {
                Text(
                    "Permanently remove capture records, retained recordings, temporary audio, and both downloaded models."
                )
                .foregroundStyle(.secondary)
                Button("Delete All Local Data…", role: .destructive) {
                    container.fullDataDeletionConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete all Kotobane local data?",
            isPresented: $container.fullDataDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Local Data", role: .destructive) {
                container.deleteAllLocalData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every capture, recording, temporary audio file, and downloaded transcription model.")
        }
    }

    private var shortcutKeyCode: Binding<UInt32> {
        Binding(
            get: { container.settings.shortcut.keyCode },
            set: { container.settings.shortcut.keyCode = $0 }
        )
    }

    private func modifier(_ modifier: Shortcut.Modifier) -> Binding<Bool> {
        Binding(
            get: { container.settings.shortcut.modifiers.contains(modifier) },
            set: { enabled in
                if enabled {
                    container.settings.shortcut.modifiers.insert(modifier)
                } else {
                    container.settings.shortcut.modifiers.remove(modifier)
                }
            }
        )
    }

    private func icon(_ destination: Destination) -> String {
        switch destination {
        case .codex: "terminal"
        case .claude: "text.bubble"
        case .clipboard: "doc.on.clipboard"
        case .markdown: "doc.text"
        }
    }
}
