import Foundation

public struct AppDirectories: Sendable {
    public let root: URL

    public var captures: URL {
        root.appending(path: "captures", directoryHint: .isDirectory)
    }

    public var settings: URL {
        root.appending(path: "settings.json", directoryHint: .notDirectory)
    }

    public init(root: URL) {
        self.root = root
    }

    public init(fileManager: FileManager = .default) throws {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.init(root: applicationSupport.appending(path: "Kotobane", directoryHint: .isDirectory))
    }
}
