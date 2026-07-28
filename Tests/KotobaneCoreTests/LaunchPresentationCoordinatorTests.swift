import Testing
@testable import KotobaneCore

@MainActor
@Test func launchPresentationActivatesTheApplication() {
    let application = SpyApplicationActivator()
    let coordinator = LaunchPresentationCoordinator(application: application)

    coordinator.presentApplication()

    #expect(application.activationCount == 1)
}

@MainActor
private final class SpyApplicationActivator: ApplicationActivating {
    private(set) var activationCount = 0

    func activate() {
        activationCount += 1
    }
}
