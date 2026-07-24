import Foundation
import Observation

public struct ModelCatalog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let choice: ModelChoice
        public let repository: String
        public let revision: String
        public let displayDownloadBytes: Int64
        public let requiredInstalledBytes: Int64
        public let safetyMarginBytes: Int64

        public var requiredCapacityBytes: Int64 {
            requiredInstalledBytes + safetyMarginBytes
        }

        public init(
            choice: ModelChoice,
            repository: String,
            revision: String,
            displayDownloadBytes: Int64,
            requiredInstalledBytes: Int64,
            safetyMarginBytes: Int64
        ) {
            self.choice = choice
            self.repository = repository
            self.revision = revision
            self.displayDownloadBytes = displayDownloadBytes
            self.requiredInstalledBytes = requiredInstalledBytes
            self.safetyMarginBytes = safetyMarginBytes
        }
    }

    public static let official = ModelCatalog(entries: [
        Entry(
            choice: .small,
            repository: "Qwen/Qwen3-ASR-0.6B",
            revision: "5eb144179a02acc5e5ba31e748d22b0cf3e303b0",
            displayDownloadBytes: 1_880_619_678,
            requiredInstalledBytes: 1_880_619_678,
            safetyMarginBytes: 1_073_741_824
        ),
        Entry(
            choice: .accuracy,
            repository: "Qwen/Qwen3-ASR-1.7B",
            revision: "7278e1e70fe206f11671096ffdd38061171dd6e5",
            displayDownloadBytes: 4_703_114_308,
            requiredInstalledBytes: 4_703_114_308,
            safetyMarginBytes: 1_073_741_824
        ),
    ])

    private let entries: [ModelChoice: Entry]

    public init(entries: [Entry]) {
        self.entries = Dictionary(
            entries.map { ($0.choice, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public subscript(choice: ModelChoice) -> Entry? {
        entries[choice]
    }
}

public struct ModelDownloadProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64?

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(completedBytes) / Double(totalBytes)
    }

    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public enum ModelManagementFailure: Error, Equatable, Sendable {
    case insufficientSpace(required: Int64, available: Int64)
    case capacityUnavailable(message: String)
    case installer(code: String, message: String)
    case invalidReadyMarker
    case unsafeModelPath
    case deletionFailed(message: String)
    case unsupportedModel
}

public enum ModelState: Equatable, Sendable {
    case notInstalled
    case downloading(ModelDownloadProgress)
    case ready
    case failed(ModelManagementFailure)
}

@MainActor
public protocol ModelManaging: AnyObject {
    var selectedModel: ModelChoice { get }
    var state: ModelState { get }

    func refresh(_ model: ModelChoice)
    func isReady(_ model: ModelChoice) -> Bool
    func install(_ model: ModelChoice) async
    func delete(_ model: ModelChoice) async
}

@MainActor
public protocol DiskCapacityReading {
    func availableCapacity(at url: URL) throws -> Int64
}

public struct VolumeDiskCapacityReader: DiskCapacityReading {
    public init() {}

    public func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileReadUnknown)
        }
        return capacity
    }
}

public struct ModelInstallRequest: Equatable, Sendable {
    public let repository: String
    public let revision: String
    public let expectedBytes: Int64
    public let availableBytes: Int64
    public let destinationURL: URL
    public let stagingURL: URL

    public init(
        repository: String,
        revision: String,
        expectedBytes: Int64,
        availableBytes: Int64,
        destinationURL: URL,
        stagingURL: URL
    ) {
        self.repository = repository
        self.revision = revision
        self.expectedBytes = expectedBytes
        self.availableBytes = availableBytes
        self.destinationURL = destinationURL
        self.stagingURL = stagingURL
    }
}

public struct ModelInstallerFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

@MainActor
public protocol ModelInstallerRunning {
    /// Starts the user-requested network setup and returns one JSON event per line.
    func run(_ request: ModelInstallRequest) -> AsyncThrowingStream<String, Error>
}

@MainActor
@Observable
public final class ModelManager: ModelManaging {
    public private(set) var selectedModel: ModelChoice
    public private(set) var state: ModelState

    private let directories: AppDirectories
    private let catalog: ModelCatalog
    private let capacity: any DiskCapacityReading
    private let installer: any ModelInstallerRunning
    private let fileManager: FileManager
    private var operationID: UUID?

    public init(
        directories: AppDirectories,
        catalog: ModelCatalog = .official,
        capacity: any DiskCapacityReading = VolumeDiskCapacityReader(),
        installer: any ModelInstallerRunning,
        selectedModel: ModelChoice = .small,
        fileManager: FileManager = .default
    ) {
        self.directories = directories
        self.catalog = catalog
        self.capacity = capacity
        self.installer = installer
        self.selectedModel = selectedModel
        self.fileManager = fileManager
        state = .notInstalled
        state = validatedReady(selectedModel) ? .ready : .notInstalled
    }

    public func refresh(_ model: ModelChoice) {
        guard operationID == nil else { return }
        selectedModel = model
        state = validatedReady(model) ? .ready : .notInstalled
    }

    public func isReady(_ model: ModelChoice) -> Bool {
        validatedReady(model)
    }

    public func install(_ model: ModelChoice) async {
        guard operationID == nil else { return }
        selectedModel = model

        guard let spec = catalog[model] else {
            state = .failed(.unsupportedModel)
            return
        }
        guard !validatedReady(model) else {
            state = .ready
            return
        }

        let paths: ModelPaths
        do {
            paths = try safePaths(for: model, createDirectories: true)
        } catch {
            state = .failed(.unsafeModelPath)
            return
        }

        let availableBytes: Int64
        do {
            availableBytes = try capacity.availableCapacity(at: paths.modelsRoot)
        } catch {
            state = .failed(.capacityUnavailable(message: error.localizedDescription))
            return
        }
        guard availableBytes >= spec.requiredCapacityBytes else {
            state = .failed(
                .insufficientSpace(
                    required: spec.requiredCapacityBytes,
                    available: availableBytes
                )
            )
            return
        }

        let currentOperation = UUID()
        operationID = currentOperation
        state = .downloading(.init(completedBytes: 0, totalBytes: nil))
        let request = ModelInstallRequest(
            repository: spec.repository,
            revision: spec.revision,
            expectedBytes: spec.requiredInstalledBytes,
            availableBytes: availableBytes,
            destinationURL: paths.active,
            stagingURL: paths.staging
        )

        do {
            var sawCompletion = false
            for try await line in installer.run(request) {
                try Task.checkCancellation()
                guard operationID == currentOperation else { return }
                switch try decode(line) {
                case .progress(let progress):
                    guard !sawCompletion else {
                        throw ModelInstallerFailure(
                            code: "invalid_installer_output",
                            message: "Installer emitted progress after completion."
                        )
                    }
                    state = .downloading(progress)
                case .completed:
                    guard !sawCompletion else {
                        throw ModelInstallerFailure(
                            code: "invalid_installer_output",
                            message: "Installer emitted more than one completion event."
                        )
                    }
                    sawCompletion = true
                case .failed(let failure):
                    throw failure
                }
            }
            try Task.checkCancellation()
            guard operationID == currentOperation else { return }
            guard sawCompletion else {
                throw ModelInstallerFailure(
                    code: "invalid_installer_output",
                    message: "Installer exited without a completion event."
                )
            }
            guard validatedReady(model) else {
                state = .failed(.invalidReadyMarker)
                operationID = nil
                return
            }
            state = .ready
            operationID = nil
        } catch {
            guard operationID == currentOperation else { return }
            operationID = nil
            if Task.isCancelled || error is CancellationError {
                state = validatedReady(model) ? .ready : .notInstalled
            } else if let failure = error as? ModelInstallerFailure {
                state = .failed(.installer(code: failure.code, message: failure.message))
            } else {
                state = .failed(
                    .installer(
                        code: "installer_failed",
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    public func delete(_ model: ModelChoice) async {
        guard operationID == nil else { return }
        selectedModel = model

        let paths: ModelPaths
        do {
            paths = try safePaths(for: model, createDirectories: false)
        } catch ModelPathError.missingRoot {
            state = .notInstalled
            return
        } catch {
            state = .failed(.unsafeModelPath)
            return
        }

        do {
            if fileManager.fileExists(atPath: paths.active.path) {
                try fileManager.removeItem(at: paths.active)
            }
            if fileManager.fileExists(atPath: paths.staging.path) {
                try fileManager.removeItem(at: paths.staging)
            }
            state = .notInstalled
        } catch {
            state = .failed(.deletionFailed(message: error.localizedDescription))
        }
    }

    private func validatedReady(_ model: ModelChoice) -> Bool {
        guard let spec = catalog[model],
              let paths = try? safePaths(for: model, createDirectories: false),
              isNonSymlinkedDirectory(paths.active, directlyBelow: paths.modelsRoot)
        else {
            return false
        }

        let marker = paths.active.appending(path: "ready.json", directoryHint: .notDirectory)
        guard let values = try? marker.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        ),
            values.isSymbolicLink != true,
            values.isRegularFile == true,
            let size = values.fileSize,
            size > 0,
            size <= 64 * 1024,
            marker.resolvingSymlinksInPath().deletingLastPathComponent()
                == paths.active.resolvingSymlinksInPath(),
            let data = try? Data(contentsOf: marker),
            let ready = try? JSONDecoder().decode(ReadyMarker.self, from: data)
        else {
            return false
        }
        return ready.modelId == spec.repository
            && ready.revision == spec.revision
            && ready.expectedBytes == spec.requiredInstalledBytes
    }

    private func safePaths(
        for model: ModelChoice,
        createDirectories: Bool
    ) throws -> ModelPaths {
        let root = directories.root.standardizedFileURL
        if !fileManager.fileExists(atPath: root.path) {
            guard createDirectories else { throw ModelPathError.missingRoot }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        guard isNonSymlinkedDirectory(root, directlyBelow: nil) else {
            throw ModelPathError.unsafe
        }

        let modelsRoot = root.appending(path: "models", directoryHint: .isDirectory)
            .standardizedFileURL
        if !fileManager.fileExists(atPath: modelsRoot.path) {
            guard createDirectories else { throw ModelPathError.missingRoot }
            try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: false)
        }
        guard isNonSymlinkedDirectory(modelsRoot, directlyBelow: root) else {
            throw ModelPathError.unsafe
        }

        let stagingRoot = modelsRoot
            .appending(path: ".staging", directoryHint: .isDirectory)
            .standardizedFileURL
        if !fileManager.fileExists(atPath: stagingRoot.path), createDirectories {
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        }
        if fileManager.fileExists(atPath: stagingRoot.path),
           !isNonSymlinkedDirectory(stagingRoot, directlyBelow: modelsRoot) {
            throw ModelPathError.unsafe
        }

        let active = modelsRoot.appending(path: model.rawValue, directoryHint: .isDirectory)
            .standardizedFileURL
        let staging = stagingRoot.appending(path: model.rawValue, directoryHint: .isDirectory)
            .standardizedFileURL
        guard active.deletingLastPathComponent() == modelsRoot,
              staging.deletingLastPathComponent() == stagingRoot
        else {
            throw ModelPathError.unsafe
        }
        return ModelPaths(
            modelsRoot: modelsRoot,
            active: active,
            staging: staging
        )
    }

    private func isNonSymlinkedDirectory(_ url: URL, directlyBelow parent: URL?) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
        ),
            values.isSymbolicLink != true,
            values.isDirectory == true
        else {
            return false
        }
        guard let parent else { return true }
        return url.resolvingSymlinksInPath().deletingLastPathComponent()
            == parent.resolvingSymlinksInPath()
    }

    private func decode(_ line: String) throws -> InstallerEvent {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(InstallerEnvelope.self, from: data)
        else {
            throw ModelInstallerFailure(
                code: "invalid_installer_output",
                message: "Installer emitted malformed progress data."
            )
        }

        switch envelope.status {
        case "progress":
            guard let completedBytes = envelope.completedBytes,
                  completedBytes >= 0,
                  envelope.totalBytes.map({ $0 > 0 && completedBytes <= $0 }) ?? true
            else {
                throw ModelInstallerFailure(
                    code: "invalid_installer_output",
                    message: "Installer emitted invalid byte progress."
                )
            }
            return .progress(
                .init(
                    completedBytes: completedBytes,
                    totalBytes: envelope.totalBytes
                )
            )
        case "completed":
            return .completed
        case "failed":
            guard let code = envelope.code,
                  !code.isEmpty,
                  let message = envelope.message,
                  !message.isEmpty
            else {
                throw ModelInstallerFailure(
                    code: "invalid_installer_output",
                    message: "Installer emitted an incomplete failure."
                )
            }
            return .failed(.init(code: code, message: message))
        default:
            throw ModelInstallerFailure(
                code: "invalid_installer_output",
                message: "Installer emitted an unknown status."
            )
        }
    }
}

private struct ModelPaths {
    let modelsRoot: URL
    let active: URL
    let staging: URL
}

private enum ModelPathError: Error {
    case missingRoot
    case unsafe
}

private struct ReadyMarker: Decodable {
    let modelId: String
    let revision: String
    let expectedBytes: Int64
}

private struct InstallerEnvelope: Decodable {
    let status: String
    let completedBytes: Int64?
    let totalBytes: Int64?
    let code: String?
    let message: String?
}

private enum InstallerEvent {
    case progress(ModelDownloadProgress)
    case completed
    case failed(ModelInstallerFailure)
}
