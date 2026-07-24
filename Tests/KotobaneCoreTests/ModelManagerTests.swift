import Foundation
import Testing
@testable import KotobaneCore

@MainActor
@Test func officialModelCatalogMatchesPinnedTaskFiveMetadata() throws {
    let small = try #require(ModelCatalog.official[.small])
    #expect(small.repository == "Qwen/Qwen3-ASR-0.6B")
    #expect(small.revision == "5eb144179a02acc5e5ba31e748d22b0cf3e303b0")
    #expect(small.displayDownloadBytes == 1_880_619_678)
    #expect(small.requiredInstalledBytes == 1_880_619_678)
    #expect(small.safetyMarginBytes == 1_073_741_824)
    #expect(small.requiredCapacityBytes == 2_954_361_502)

    let accuracy = try #require(ModelCatalog.official[.accuracy])
    #expect(accuracy.repository == "Qwen/Qwen3-ASR-1.7B")
    #expect(accuracy.revision == "7278e1e70fe206f11671096ffdd38061171dd6e5")
    #expect(accuracy.displayDownloadBytes == 4_703_114_308)
    #expect(accuracy.requiredInstalledBytes == 4_703_114_308)
    #expect(accuracy.safetyMarginBytes == 1_073_741_824)
    #expect(accuracy.requiredCapacityBytes == 5_776_856_132)
}

@MainActor
@Test func insufficientSpacePreventsInstallerLaunch() async throws {
    let fixture = try ModelManagerFixture(availableBytes: 4_399, installedBytes: 4_000)

    await fixture.manager.install(.small)

    #expect(
        fixture.manager.state
            == .failed(.insufficientSpace(required: 5_000, available: 4_399))
    )
    #expect(fixture.installer.launchCount == 0)
}

@MainActor
@Test func structuredProgressIsPublishedAndValidActivationBecomesReady() async throws {
    let fixture = try ModelManagerFixture()
    fixture.installer.onRun = { request, continuation in
        #expect(request.repository == fixture.spec.repository)
        #expect(request.revision == fixture.spec.revision)
        #expect(request.expectedBytes == fixture.spec.requiredInstalledBytes)
        #expect(request.availableBytes == fixture.capacity.availableBytes)
        #expect(request.destinationURL.path == fixture.activeURL.path)
        #expect(request.stagingURL.path == fixture.stagingURL.path)
        continuation.yield(#"{"status":"progress","completedBytes":25,"totalBytes":100}"#)
    }

    let install = Task { @MainActor in await fixture.manager.install(.small) }
    await fixture.installer.waitForLaunch()
    await waitUntil {
        fixture.manager.state
            == .downloading(.init(completedBytes: 25, totalBytes: 100))
    }

    #expect(
        fixture.manager.state
            == .downloading(.init(completedBytes: 25, totalBytes: 100))
    )

    try fixture.writeReadyMarker()
    fixture.installer.continuation?.yield(#"{"status":"completed"}"#)
    fixture.installer.continuation?.finish()
    await install.value

    #expect(fixture.manager.state == .ready)
    #expect(fixture.manager.isReady(.small))
}

@MainActor
@Test func typedInstallerFailurePreservesCodeAndMessage() async throws {
    let fixture = try ModelManagerFixture()
    fixture.installer.lines = [
        #"{"status":"failed","code":"checksum_mismatch","message":"Downloaded weights failed SHA-256 verification."}"#,
    ]

    await fixture.manager.install(.small)

    #expect(
        fixture.manager.state
            == .failed(
                .installer(
                    code: "checksum_mismatch",
                    message: "Downloaded weights failed SHA-256 verification."
                )
            )
    )
}

@MainActor
@Test func stagingOrInvalidActiveMarkerIsNeverReady() async throws {
    let fixture = try ModelManagerFixture()
    try fixture.writeReadyMarker(at: fixture.stagingURL)

    fixture.manager.refresh(.small)
    #expect(fixture.manager.state == .notInstalled)

    fixture.installer.onRun = { _, continuation in
        try? fixture.writeReadyMarker(revision: "mutable-main")
        continuation.yield(#"{"status":"completed"}"#)
        continuation.finish()
    }
    await fixture.manager.install(.small)

    #expect(fixture.manager.state == .failed(.invalidReadyMarker))
    #expect(!fixture.manager.isReady(.small))
}

@MainActor
@Test func symlinkedMarkerAndEscapingModelDirectoryAreRejected() async throws {
    let fixture = try ModelManagerFixture()
    let outside = fixture.root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideMarker = outside.appending(path: "ready.json")
    try fixture.writeReadyMarker(at: outside)

    try FileManager.default.createDirectory(
        at: fixture.activeURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: fixture.activeURL.appending(path: "ready.json"),
        withDestinationURL: outsideMarker
    )
    fixture.manager.refresh(.small)
    #expect(fixture.manager.state == .notInstalled)

    try FileManager.default.removeItem(at: fixture.activeURL)
    try FileManager.default.createSymbolicLink(
        at: fixture.activeURL,
        withDestinationURL: outside
    )
    fixture.manager.refresh(.small)
    #expect(fixture.manager.state == .notInstalled)

    await fixture.manager.delete(.small)
    #expect(!FileManager.default.fileExists(atPath: fixture.activeURL.path))
    #expect(FileManager.default.fileExists(atPath: outsideMarker.path))
}

@MainActor
@Test func duplicateInstallAndDeleteCannotRaceActiveInstallation() async throws {
    let fixture = try ModelManagerFixture()
    fixture.installer.onRun = { _, _ in }

    let first = Task { @MainActor in await fixture.manager.install(.small) }
    await fixture.installer.waitForLaunch()
    await fixture.manager.install(.small)
    await fixture.manager.delete(.small)

    #expect(fixture.installer.launchCount == 1)
    #expect(fixture.manager.state == .downloading(.init(completedBytes: 0, totalBytes: nil)))

    fixture.installer.continuation?.yield(
        #"{"status":"failed","code":"network_error","message":"Offline."}"#
    )
    fixture.installer.continuation?.finish()
    await first.value
}

@MainActor
@Test func cancellationReturnsToNotInstalledAndIgnoresLateProgress() async throws {
    let fixture = try ModelManagerFixture()
    fixture.installer.onRun = { _, _ in }

    let install = Task { @MainActor in await fixture.manager.install(.small) }
    await fixture.installer.waitForLaunch()
    install.cancel()
    await install.value

    #expect(fixture.manager.state == .notInstalled)
    fixture.installer.continuation?.yield(
        #"{"status":"progress","completedBytes":100,"totalBytes":100}"#
    )
    #expect(fixture.manager.state == .notInstalled)
}

@MainActor
@Test func deletionRemovesOnlySelectedActiveAndSelectedStagingPaths() async throws {
    let fixture = try ModelManagerFixture()
    let siblingActive = fixture.modelsRoot.appending(path: ModelChoice.accuracy.rawValue)
    let siblingStaging = fixture.modelsRoot
        .appending(path: ".staging")
        .appending(path: ModelChoice.accuracy.rawValue)
    try createSentinel(in: fixture.activeURL)
    try createSentinel(in: fixture.stagingURL)
    try createSentinel(in: siblingActive)
    try createSentinel(in: siblingStaging)
    let rootSentinel = fixture.modelsRoot.appending(path: "keep.txt")
    try Data("keep".utf8).write(to: rootSentinel)

    await fixture.manager.delete(.small)

    #expect(!FileManager.default.fileExists(atPath: fixture.activeURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.stagingURL.path))
    #expect(FileManager.default.fileExists(atPath: siblingActive.path))
    #expect(FileManager.default.fileExists(atPath: siblingStaging.path))
    #expect(FileManager.default.fileExists(atPath: rootSentinel.path))
    #expect(fixture.manager.state == .notInstalled)
}

@MainActor
@Test func symlinkedModelsRootBlocksInstallAndScopedDeletion() async throws {
    let fixture = try ModelManagerFixture(createModelsRoot: false)
    let outside = fixture.root.appending(path: "outside-models", directoryHint: .isDirectory)
    let outsideSelected = outside.appending(path: ModelChoice.small.rawValue)
    try createSentinel(in: outsideSelected)
    try FileManager.default.createSymbolicLink(
        at: fixture.modelsRoot,
        withDestinationURL: outside
    )

    await fixture.manager.install(.small)
    #expect(fixture.installer.launchCount == 0)
    #expect(fixture.manager.state == .failed(.unsafeModelPath))

    await fixture.manager.delete(.small)
    #expect(fixture.manager.state == .failed(.unsafeModelPath))
    #expect(FileManager.default.fileExists(
        atPath: outsideSelected.appending(path: "sentinel").path
    ))
}

private func createSentinel(in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: directory.appending(path: "sentinel"))
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    while !condition() {
        await Task.yield()
    }
}

private final class ModelManagerTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "Kotobane-ModelManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
private final class ModelManagerFixture {
    let temporary: ModelManagerTemporaryDirectory
    let root: URL
    let modelsRoot: URL
    let activeURL: URL
    let stagingURL: URL
    let capacity: StubModelCapacity
    let installer: ControllableModelInstaller
    let catalog: ModelCatalog
    let spec: ModelCatalog.Entry
    let manager: ModelManager

    init(
        availableBytes: Int64 = 8_000,
        installedBytes: Int64 = 4_000,
        createModelsRoot: Bool = true
    ) throws {
        temporary = try ModelManagerTemporaryDirectory()
        root = temporary.url
        modelsRoot = root.appending(path: "models", directoryHint: .isDirectory)
        activeURL = modelsRoot.appending(path: ModelChoice.small.rawValue)
        stagingURL = modelsRoot
            .appending(path: ".staging", directoryHint: .isDirectory)
            .appending(path: ModelChoice.small.rawValue, directoryHint: .isDirectory)
        if createModelsRoot {
            try FileManager.default.createDirectory(
                at: modelsRoot,
                withIntermediateDirectories: true
            )
        }
        capacity = StubModelCapacity(availableBytes: availableBytes)
        installer = ControllableModelInstaller()
        spec = ModelCatalog.Entry(
            choice: .small,
            repository: "Qwen/Fixture",
            revision: "fixture-revision",
            displayDownloadBytes: installedBytes,
            requiredInstalledBytes: installedBytes,
            safetyMarginBytes: 1_000
        )
        catalog = ModelCatalog(entries: [spec])
        manager = ModelManager(
            directories: AppDirectories(root: root),
            catalog: catalog,
            capacity: capacity,
            installer: installer
        )
    }

    func writeReadyMarker(
        at directory: URL? = nil,
        revision: String? = nil
    ) throws {
        let directory = directory ?? activeURL
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: [
                "modelId": spec.repository,
                "revision": revision ?? spec.revision,
                "expectedBytes": spec.requiredInstalledBytes,
            ],
            options: [.sortedKeys]
        )
        try data.write(to: directory.appending(path: "ready.json"))
    }
}

@MainActor
private final class StubModelCapacity: DiskCapacityReading {
    let availableBytes: Int64

    init(availableBytes: Int64) {
        self.availableBytes = availableBytes
    }

    func availableCapacity(at url: URL) throws -> Int64 {
        availableBytes
    }
}

@MainActor
private final class ControllableModelInstaller: ModelInstallerRunning {
    var lines: [String] = []
    var onRun: ((ModelInstallRequest, AsyncThrowingStream<String, Error>.Continuation) -> Void)?
    private(set) var launchCount = 0
    private(set) var requests: [ModelInstallRequest] = []
    var continuation: AsyncThrowingStream<String, Error>.Continuation?

    func run(_ request: ModelInstallRequest) -> AsyncThrowingStream<String, Error> {
        launchCount += 1
        requests.append(request)
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            if let onRun {
                onRun(request, continuation)
            } else {
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }
    }

    func waitForLaunch() async {
        while launchCount == 0 {
            await Task.yield()
        }
    }
}
