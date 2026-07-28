import Foundation

@MainActor
public protocol ApplicationActivating: AnyObject {
    func activate()
    func openCaptureDesk()
}

@MainActor
public final class LaunchPresentationCoordinator {
    private let application: any ApplicationActivating

    public init(application: any ApplicationActivating) {
        self.application = application
    }

    public func presentApplication() {
        application.activate()
        application.openCaptureDesk()
    }
}
