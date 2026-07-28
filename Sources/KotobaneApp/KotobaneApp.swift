import SwiftUI
import AppKit
import KotobaneCore

@main
struct KotobaneApp: App {
    @NSApplicationDelegateAdaptor(KotobaneAppDelegate.self) private var appDelegate
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
        .menuBarExtraStyle(.menu)

        Window("Kotobane", id: "desk") {
            CaptureDeskWindow(container: container)
        }
        .defaultSize(width: 760, height: 560)

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

@MainActor
private final class KotobaneAppDelegate: NSObject, NSApplicationDelegate {
    private let launchPresentation = LaunchPresentationCoordinator(
        application: SystemApplicationActivator()
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [launchPresentation] in
            launchPresentation.presentApplication()
        }
    }
}

@MainActor
private final class SystemApplicationActivator: ApplicationActivating {
    func activate() {
        NSRunningApplication.current.activate(options: [])
    }
}
