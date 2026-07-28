import Testing
@testable import KotobaneCore

@MainActor
@Test func launchPresentationActivatesTheApplication() {
    let application = SpyApplicationActivator()
    let coordinator = LaunchPresentationCoordinator(application: application)

    coordinator.presentApplication()

    #expect(application.activationCount == 1)
    #expect(application.captureDeskPresentationCount == 1)
}

@MainActor
private final class SpyApplicationActivator: ApplicationActivating {
    private(set) var activationCount = 0
    private(set) var captureDeskPresentationCount = 0

    func activate() {
        activationCount += 1
    }

    func openCaptureDesk() {
        captureDeskPresentationCount += 1
    }
}
