import SwiftUI

@main
struct KotobaneApp: App {
    @State private var container = AppContainer.live()

    var body: some Scene {
        MenuBarExtra(
            "Kotobane",
            systemImage: container.capture.state.isRecording
                ? "waveform.circle.fill"
                : "waveform.circle"
        ) {
            MenuBarContent(container: container)
        }

        Window("Capture Review", id: "review") {
            ReviewWindow(container: container)
        }
        .defaultSize(width: 760, height: 620)

        Window("History", id: "history") {
            HistoryWindow(container: container)
        }
        .defaultSize(width: 680, height: 520)

        Settings {
            SettingsWindow(container: container)
        }
    }
}
