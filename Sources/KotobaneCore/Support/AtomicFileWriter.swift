import Foundation

public struct AtomicFileWriter {
    private let fileSystem: any AtomicFileSystem

    public init(fileManager: FileManager = .default) {
        self.fileSystem = FoundationAtomicFileSystem(fileManager: fileManager)
    }

    init(fileSystem: any AtomicFileSystem) {
        self.fileSystem = fileSystem
    }

    public func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try fileSystem.createDirectory(at: directory)

        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try fileSystem.write(data, to: temporary)
            if fileSystem.fileExists(at: destination) {
                try fileSystem.replaceItem(at: destination, with: temporary)
            } else {
                try fileSystem.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileSystem.removeItem(at: temporary)
            throw error
        }
    }
}

protocol AtomicFileSystem {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func write(_ data: Data, to url: URL) throws
    func replaceItem(at destination: URL, with temporary: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
}

private struct FoundationAtomicFileSystem: AtomicFileSystem {
    let fileManager: FileManager

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
    }

    func replaceItem(at destination: URL, with temporary: URL) throws {
        _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try fileManager.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

struct StoragePathGuard {
    private let root: URL
    private let canonicalRoot: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager) {
        self.root = root.standardizedFileURL
        self.canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    @discardableResult
    func validate(_ candidate: URL) throws -> Bool {
        let candidate = candidate.standardizedFileURL
        guard Self.contains(candidate, in: root) else {
            throw StoragePathError.outsideRoot(candidate)
        }

        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        var current = root
        var exists = try validateComponent(current, mustBeDirectory: candidate != root)

        for (offset, component) in candidateComponents.dropFirst(rootComponents.count).enumerated() {
            current.append(path: component)
            let isLeaf = offset == candidateComponents.count - rootComponents.count - 1
            exists = try validateComponent(current, mustBeDirectory: !isLeaf)
        }

        let parent = candidate == root ? candidate : candidate.deletingLastPathComponent()
        let canonicalParent = parent.resolvingSymlinksInPath().standardizedFileURL
        guard Self.contains(canonicalParent, in: canonicalRoot) else {
            throw StoragePathError.outsideRoot(candidate)
        }
        return exists
    }

    private func validateComponent(_ url: URL, mustBeDirectory: Bool) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            let fileError = error as NSError
            guard fileError.domain == NSCocoaErrorDomain,
                  fileError.code == CocoaError.fileReadNoSuchFile.rawValue
            else {
                throw error
            }
            return false
        }

        let type = attributes[.type] as? FileAttributeType
        guard type != .typeSymbolicLink else {
            throw StoragePathError.symbolicLink(url)
        }
        if mustBeDirectory, type != .typeDirectory {
            throw StoragePathError.notDirectory(url)
        }
        return true
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

enum StoragePathError: Error, Equatable {
    case notDirectory(URL)
    case outsideRoot(URL)
    case symbolicLink(URL)
}
