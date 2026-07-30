import AVFoundation
import Foundation
import Testing
@testable import KotobaneCore

@MainActor
@Test func successfulDefaultCapturePersistsTranscriptBeforeDeletingAudio() async throws {
    let fixture = CaptureFixture()

    await fixture.controller.start()
    await fixture.controller.stop()

    let capture = try #require(fixture.controller.state.capture)
    #expect(capture.transcript == "Merhaba")
    #expect(capture.audioFilename == nil)
    #expect(fixture.events.values == [
        "record-start", "record-stop", "transcribe", "persist", "delete-audio",
    ])
}

@MainActor
@Test func retainedCapturePersistsBeforeMovingAudioAndThenPersistsItsFilename() async throws {
    let fixture = CaptureFixture(retention: .retain)

    await fixture.controller.start()
    await fixture.controller.stop()

    let capture = try #require(fixture.controller.state.capture)
    #expect(capture.audioFilename == "\(fixture.id.uuidString).wav")
    #expect(fixture.events.values == [
        "record-start", "record-stop", "transcribe",
        "persist", "retain-audio", "persist",
    ])
    #expect(fixture.store.saved.first?.audioFilename == nil)
    #expect(fixture.store.saved.last?.audioFilename == capture.audioFilename)
}

@MainActor
@Test func deniedPermissionNeverStartsRecorderAndOffersSettingsRecovery() async throws {
    let fixture = CaptureFixture(authorization: .denied)

    await fixture.controller.start()

    let failure = try #require(fixture.controller.state.failure)
    #expect(failure.kind == .microphonePermissionDenied)
    #expect(failure.recovery == .openMicrophoneSettings)
    #expect(fixture.recorder.startCount == 0)
    #expect(fixture.files.createdURLs.isEmpty)
}

@MainActor
@Test func firstUsePermissionTransitionsThroughRequestAndThenRecords() async throws {
    let authorizer = SuspendingAuthorizer()
    let fixture = CaptureFixture(authorizer: authorizer)

    let firstStart = Task { @MainActor in await fixture.controller.start() }
    await authorizer.waitUntilRequested()
    #expect(fixture.controller.state == .requestingPermission)

    await fixture.controller.start()
    #expect(authorizer.requestCount == 1)

    authorizer.resolve(.authorized)
    await firstStart.value
    #expect(fixture.controller.state.isRecording)
    #expect(fixture.recorder.startCount == 1)
}

@MainActor
@Test func cancellationDuringPermissionRequestPreventsLateRecorderStart() async {
    let authorizer = SuspendingAuthorizer()
    let fixture = CaptureFixture(authorizer: authorizer)

    let start = Task { @MainActor in await fixture.controller.start() }
    await authorizer.waitUntilRequested()
    await fixture.controller.cancel()
    authorizer.resolve(.authorized)
    await start.value

    #expect(fixture.controller.state == .idle)
    #expect(fixture.recorder.startCount == 0)
}

@MainActor
@Test func missingInputDeviceRemovesInvalidTemporaryFileAndOffersRetry() async throws {
    let fixture = CaptureFixture(startError: .noInputDevice)

    await fixture.controller.start()

    let failure = try #require(fixture.controller.state.failure)
    #expect(failure.kind == .noInputDevice)
    #expect(failure.recovery == .retryRecording)
    #expect(fixture.events.values == ["record-start", "delete-audio"])
}

@MainActor
@Test func retryRecordingRecoveryStartsAFreshSession() async throws {
    let fixture = CaptureFixture(startError: .noInputDevice)
    await fixture.controller.start()
    fixture.recorder.startError = nil

    await fixture.controller.retry()

    #expect(fixture.controller.state.isRecording)
    #expect(fixture.recorder.startCount == 2)
}

@MainActor
@Test func zeroFrameCaptureIsDiscardedWithoutTranscription() async throws {
    let fixture = CaptureFixture(frameCount: 0)

    await fixture.controller.start()
    await fixture.controller.stop()

    let failure = try #require(fixture.controller.state.failure)
    #expect(failure.kind == .emptyRecording)
    #expect(failure.recovery == .retryRecording)
    #expect(fixture.engine.callCount == 0)
    #expect(fixture.events.values == ["record-start", "record-stop", "delete-audio"])
}

@MainActor
@Test func lateRecorderFailurePreservesValidPartialAudioForActionableRetry() async throws {
    let fixture = CaptureFixture(stopFailureAfterFrames: true)

    await fixture.controller.start()
    await fixture.controller.stop()

    let failure = try #require(fixture.controller.state.failure)
    #expect(failure.kind == .recordingFailed)
    #expect(failure.recovery == .retryTranscription)
    #expect(failure.preservedAudioURL == fixture.temporaryURL)
    #expect(fixture.files.deletedURLs.isEmpty)
    #expect(fixture.files.deleteAttempts == 0)
    #expect(fixture.engine.callCount == 0)

    await fixture.controller.retry()

    #expect(fixture.controller.state.capture?.transcript == "Merhaba")
    #expect(fixture.engine.callCount == 1)
    #expect(fixture.files.deletedURLs == [fixture.temporaryURL])
}

@MainActor
@Test func missingModelOffersTypedSettingsRecoveryAndPreservesAudio() async throws {
    let engine = ScriptedTranscriptionEngine([
        .failure(TranscriptionFailure.helperRejected(
            code: "model_unavailable",
            message: "Install the model."
        )),
    ])
    let fixture = CaptureFixture(engine: engine)

    await fixture.controller.start()
    await fixture.controller.stop()

    let failure = try #require(fixture.controller.state.failure)
    #expect(failure.kind == .modelUnavailable)
    #expect(failure.recovery == .openModelSettings)
    #expect(failure.message == "Model not installed. Install it in Settings before retrying.")
    #expect(failure.preservedAudioURL == fixture.temporaryURL)
    #expect(fixture.files.deletedURLs.isEmpty)
    #expect(!fixture.events.values.contains("delete-audio"))
}

@MainActor
@Test func otherTranscriptionFailurePreservesAudioAndRetryCanReachReview() async throws {
    let engine = ScriptedTranscriptionEngine([
        .failure(TranscriptionFailure.helperRejected(
            code: "helper_busy",
            message: "Try again."
        )),
        .success(.fixture(text: "Kurtarıldı")),
    ])
    let fixture = CaptureFixture(engine: engine)

    await fixture.controller.start()
    await fixture.controller.stop()

    let failure = try #require(fixture.controller.state.failure)
    #expect(failure.kind == .transcriptionFailed)
    #expect(failure.recovery == .retryTranscription)
    #expect(failure.preservedAudioURL == fixture.temporaryURL)
    #expect(!fixture.events.values.contains("delete-audio"))

    await fixture.controller.retry()

    #expect(fixture.controller.state.capture?.transcript == "Kurtarıldı")
    #expect(engine.callCount == 2)
    #expect(fixture.events.values.suffix(2) == ["persist", "delete-audio"])
}

@MainActor
@Test func persistenceFailurePreservesAudioAndRetryDoesNotRetranscribe() async throws {
    let fixture = CaptureFixture(storeFailures: 1)

    await fixture.controller.start()
    await fixture.controller.stop()

    let failure = try #require(fixture.controller.state.failure)
    #expect(failure.kind == .persistenceFailed)
    #expect(failure.recovery == .retryTranscription)
    #expect(failure.preservedAudioURL == fixture.temporaryURL)
    #expect(fixture.engine.callCount == 1)
    #expect(!fixture.events.values.contains("delete-audio"))

    await fixture.controller.retry()

    #expect(fixture.controller.state.capture?.transcript == "Merhaba")
    #expect(fixture.engine.callCount == 1)
    #expect(fixture.events.values.suffix(2) == ["persist", "delete-audio"])
}

@MainActor
@Test func failedDefaultRetentionKeepsAudioAndRetriesOnlyDeletion() async throws {
    let fixture = CaptureFixture(deleteFailures: 1)

    await fixture.controller.start()
    await fixture.controller.stop()

    let failure = try #require(fixture.controller.state.failure)
    #expect(failure.kind == .retentionFailed)
    #expect(failure.recovery == .retryRetention)
    #expect(failure.preservedAudioURL == fixture.temporaryURL)
    #expect(fixture.store.saved.count == 1)
    #expect(fixture.engine.callCount == 1)

    await fixture.controller.retry()

    #expect(fixture.controller.state.capture != nil)
    #expect(fixture.store.saved.count == 1)
    #expect(fixture.engine.callCount == 1)
    #expect(fixture.files.deleteAttempts == 2)
}

@MainActor
@Test func retainedAudioMetadataFailureRetriesWithoutMovingAudioTwice() async throws {
    let fixture = CaptureFixture(
        retention: .retain,
        storeFailureCalls: [2]
    )

    await fixture.controller.start()
    await fixture.controller.stop()

    let failure = try #require(fixture.controller.state.failure)
    #expect(failure.kind == .retentionFailed)
    #expect(failure.preservedAudioURL == fixture.retainedURL)
    #expect(fixture.files.retainAttempts == 1)
    #expect(fixture.store.saved.count == 1)

    await fixture.controller.retry()

    #expect(fixture.controller.state.capture?.audioFilename == "\(fixture.id.uuidString).wav")
    #expect(fixture.files.retainAttempts == 1)
    #expect(fixture.store.saved.count == 2)
}

@MainActor
@Test func cancelStopsRecorderBeforeRemovingOnlyOwnedTemporaryAudio() async {
    let fixture = CaptureFixture()
    await fixture.controller.start()

    await fixture.controller.cancel()

    #expect(fixture.controller.state == .idle)
    #expect(fixture.events.values == ["record-start", "record-stop", "delete-audio"])
    #expect(fixture.files.deletedURLs == [fixture.temporaryURL])
}

@MainActor
@Test func duplicateStopDuringTranscriptionStopsRecorderOnlyOnce() async {
    let engine = SuspendingTranscriptionEngine()
    let fixture = CaptureFixture(engine: engine)
    await fixture.controller.start()

    let firstStop = Task { @MainActor in await fixture.controller.stop() }
    await engine.waitUntilCalled()
    #expect(fixture.controller.state == .transcribing)

    await fixture.controller.stop()
    #expect(fixture.recorder.stopCount == 1)

    engine.resolve(.fixture())
    await firstStop.value
    #expect(fixture.recorder.stopCount == 1)
}

@MainActor
@Test func recordingMeterUpdatesPublishImmutableMainActorSnapshots() async throws {
    let fixture = CaptureFixture()
    await fixture.controller.start()

    fixture.recorder.publish(.init(elapsedSeconds: 2.5, rmsLevel: 0.75))
    await Task.yield()

    let snapshot = try #require(fixture.controller.state.recordingSnapshot)
    #expect(snapshot.elapsedSeconds == 2.5)
    #expect(snapshot.rmsLevel == 0.75)
}

@MainActor
@Test func completedPartialSegmentPublishesProvisionalTranscriptWhileRecording() async throws {
    let engine = ScriptedTranscriptionEngine([.success(.fixture(text: "Canlı taslak"))])
    let fixture = CaptureFixture(engine: engine)
    await fixture.controller.start()

    fixture.recorder.publishPartial(
        AudioRecording(
            fileURL: fixture.temporaryURL,
            frameCount: 96_000,
            durationSeconds: 6
        )
    )
    await waitForLiveDraftStatus(.available, in: fixture.controller)

    let snapshot = try #require(fixture.controller.state.recordingSnapshot)
    #expect(snapshot.partialTranscript == "Canlı taslak")
    #expect(fixture.controller.state.isRecording)
}

@MainActor
@Test func accuracyModeUsesSmallModelForLiveDraftAndAccuracyModelForFinalTranscript() async throws {
    let engine = ScriptedTranscriptionEngine([
        .success(.fixture(text: "Canlı taslak")),
        .success(.fixture(text: "Doğru son metin")),
    ])
    let fixture = CaptureFixture(engine: engine, model: .accuracy)
    await fixture.controller.start()

    fixture.recorder.publishPartial(
        AudioRecording(
            fileURL: fixture.temporaryURL,
            frameCount: 96_000,
            durationSeconds: 6
        )
    )
    await waitForLiveDraftStatus(.available, in: fixture.controller)
    await fixture.controller.stop()

    #expect(engine.requestModels == [.small, .accuracy])
    #expect(fixture.controller.state.capture?.transcript == "Doğru son metin")
}

@MainActor
@Test func failedPartialSegmentExplainsThatTheLiveDraftIsUnavailableWhileRecording() async throws {
    let engine = ScriptedTranscriptionEngine([
        .failure(TranscriptionFailure.helperRejected(
            code: "model_unavailable",
            message: "Install the model."
        )),
    ])
    let fixture = CaptureFixture(engine: engine)
    await fixture.controller.start()

    fixture.recorder.publishPartial(
        AudioRecording(
            fileURL: fixture.temporaryURL,
            frameCount: 96_000,
            durationSeconds: 6
        )
    )
    await waitForLiveDraftStatus(.unavailable, in: fixture.controller)

    let snapshot = try #require(fixture.controller.state.recordingSnapshot)
    #expect(snapshot.liveDraftStatus == .unavailable)
    #expect(snapshot.liveDraftMessage == "Live draft unavailable: Install the model.")
    #expect(fixture.controller.state.isRecording)
}

@Test func recorderWAVSettingsUseDependencyFreeLittleEndianIntegerPCM() {
    let settings = PCMInt16WAV.settings(sampleRate: 48_000, channelCount: 1)

    #expect(settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatLinearPCM)
    #expect(settings[AVLinearPCMBitDepthKey] as? Int == 16)
    #expect(settings[AVLinearPCMIsFloatKey] as? Bool == false)
    #expect(settings[AVLinearPCMIsBigEndianKey] as? Bool == false)
}

@Test func recorderUsesQwenCompatibleSixteenKilohertzOutput() {
    #expect(PCMInt16WAV.transcriptionSampleRate == 16_000)
}

@Test func partialTranscriptAccumulatorPreservesCompletedSegmentsInOrder() {
    var accumulator = PartialTranscriptAccumulator()

    accumulator.append("Merhaba")
    accumulator.append("Kotobane")

    #expect(accumulator.text == "Merhaba Kotobane")
}

@Test func rollingTranscriptAccumulatorReplacesTheUnstableSixSecondTail() {
    var accumulator = RollingTranscriptAccumulator()

    accumulator.replaceRollingWindow(with: "bir iki üç dört beş altı")
    accumulator.replaceRollingWindow(with: "iki üç dört beş altı yedi")

    #expect(accumulator.text == "bir iki üç dört beş altı yedi")
}

@Test func rollingTranscriptAccumulatorExposesCumulativeTextForLiveDisplay() {
    var accumulator = RollingTranscriptAccumulator()

    accumulator.replaceRollingWindow(with: "bir iki üç dört beş altı")
    accumulator.replaceRollingWindow(with: "iki üç dört beş altı yedi")

    #expect(accumulator.liveText == "bir iki üç dört beş altı yedi")
}

@Test func recorderSettingsProduceAnIntegerPCMWAVReadableByTheFastPath() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "sample.wav")

    do {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: PCMInt16WAV.settings(sampleRate: 48_000, channelCount: 1),
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        )
        buffer.frameLength = 4
        try file.write(from: buffer)
    }

    let data = try Data(contentsOf: url)
    #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
    let formatTagOffset = try #require(
        data.range(of: Data("fmt ".utf8))
    ).upperBound + 4
    let formatTag = UInt16(data[formatTagOffset])
        | (UInt16(data[formatTagOffset + 1]) << 8)
    #expect(formatTag == 1)
}

@Test func audioTapCallbackForwardsOffMainActorWithoutExecutorRequirement() async throws {
    let observation = TapCallbackObservation()
    let callback = AVAudioEngineRecorder.makeRealtimeTapCallback { buffer in
        observation.record(
            frameCapacity: buffer.frameCapacity,
            ranOnMainThread: Thread.isMainThread
        )
    }
    let callbackBox = UncheckedSendableTapCallback(callback)

    try await Task.detached {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)
        )
        callbackBox.callback(buffer, AVAudioTime(hostTime: 0))
    }.value

    #expect(observation.frameCapacity == 32)
    #expect(observation.ranOnMainThread == false)
}

@MainActor
@Test func audioFileManagerRejectsOutsideDeletionWithoutChangingTheFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let outside = FileManager.default.temporaryDirectory
        .appending(path: "\(UUID().uuidString).wav")
    try Data([1, 2, 3]).write(to: outside)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    let files = CaptureAudioFiles(root: root)
    #expect(throws: CaptureAudioFileError.self) {
        try files.removeTemporaryAudio(at: outside)
    }
    #expect(FileManager.default.fileExists(atPath: outside.path))
}

@MainActor
@Test func audioFileManagerRejectsSymlinkedTemporaryDirectoryWithoutChangingOutsideFiles() throws {
    let base = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let root = base.appending(path: "root", directoryHint: .isDirectory)
    let captures = root.appending(path: "captures", directoryHint: .isDirectory)
    let temporary = captures.appending(path: ".temporary", directoryHint: .isDirectory)
    let outside = base.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: outside)
    let outsideAudio = outside.appending(path: "owned.wav")
    try Data([1, 2, 3]).write(to: outsideAudio)
    defer { try? FileManager.default.removeItem(at: base) }

    let files = CaptureAudioFiles(root: root)
    #expect(throws: Error.self) {
        try files.removeTemporaryAudio(
            at: temporary.appending(path: "owned.wav", directoryHint: .notDirectory)
        )
    }
    #expect(FileManager.default.fileExists(atPath: outsideAudio.path))
}

@MainActor
private final class CaptureFixture {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let temporaryURL: URL
    var retainedURL: URL {
        URL(fileURLWithPath: "/private/tmp/\(id.uuidString).wav")
    }
    let events = CaptureEventLog()
    let authorizer: any MicrophoneAuthorizing
    let recorder: SpyAudioRecorder
    let engine: any FixtureTranscriptionEngine
    let store: SpyCaptureStore
    let files: SpyCaptureAudioFiles
    let controller: CaptureController

    init(
        authorization: MicrophoneAuthorization = .authorized,
        authorizer suppliedAuthorizer: (any MicrophoneAuthorizing)? = nil,
        retention: AudioRetentionPolicy = .deleteAfterTranscription,
        startError: AudioRecorderError? = nil,
        frameCount: AVAudioFramePosition = 4_800,
        stopFailureAfterFrames: Bool = false,
        engine suppliedEngine: (any FixtureTranscriptionEngine)? = nil,
        model: ModelChoice = .small,
        storeFailures: Int = 0,
        storeFailureCalls: Set<Int> = [],
        deleteFailures: Int = 0
    ) {
        let temporaryURL = URL(
            fileURLWithPath: "/private/tmp/Kotobane-\(UUID().uuidString).wav"
        )
        self.temporaryURL = temporaryURL
        let authorizer = suppliedAuthorizer ?? StubAuthorizer(authorization)
        let recorder = SpyAudioRecorder(
            events: events,
            recording: AudioRecording(
                fileURL: temporaryURL,
                frameCount: frameCount,
                durationSeconds: 0.1
            ),
            startError: startError,
            stopFailure: stopFailureAfterFrames
                ? AudioRecordingStopFailure(
                    error: .writeFailed("Disk write failed after valid audio."),
                    partialRecording: AudioRecording(
                        fileURL: temporaryURL,
                        frameCount: frameCount,
                        durationSeconds: 0.1
                    )
                )
                : nil
        )
        let engine = suppliedEngine ?? ScriptedTranscriptionEngine([
            .success(.fixture()),
        ])
        let failures: Set<Int>
        if !storeFailureCalls.isEmpty {
            failures = storeFailureCalls
        } else if storeFailures > 0 {
            failures = Set(1...storeFailures)
        } else {
            failures = []
        }
        let store = SpyCaptureStore(events: events, failureCalls: failures)
        let files = SpyCaptureAudioFiles(
            events: events,
            temporaryURL: temporaryURL,
            deleteFailuresRemaining: deleteFailures
        )
        let fixtureID = id

        self.authorizer = authorizer
        self.recorder = recorder
        self.engine = engine
        self.store = store
        self.files = files
        self.controller = CaptureController(
            authorizer: authorizer,
            recorder: recorder,
            transcriptionEngine: engine,
            store: store,
            audioFiles: files,
            retention: retention,
            languageHint: "Turkish",
            model: model,
            defaultIntent: .brainstorm,
            makeID: { fixtureID },
            now: { Date(timeIntervalSince1970: 1_234) }
        )
    }
}

@MainActor
private final class CaptureEventLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

@MainActor
private final class StubAuthorizer: MicrophoneAuthorizing {
    let authorization: MicrophoneAuthorization
    init(_ authorization: MicrophoneAuthorization) { self.authorization = authorization }
    func currentAuthorization() -> MicrophoneAuthorization { authorization }
    func requestAuthorization() async -> MicrophoneAuthorization { authorization }
}

@MainActor
private final class SuspendingAuthorizer: MicrophoneAuthorizing {
    private var continuation: CheckedContinuation<MicrophoneAuthorization, Never>?
    private var requestedContinuation: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    func currentAuthorization() -> MicrophoneAuthorization { .notDetermined }

    func requestAuthorization() async -> MicrophoneAuthorization {
        requestCount += 1
        requestedContinuation?.resume()
        requestedContinuation = nil
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRequested() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { requestedContinuation = $0 }
    }

    func resolve(_ result: MicrophoneAuthorization) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class SpyAudioRecorder: AudioRecordingManaging {
    let events: CaptureEventLog
    let recording: AudioRecording
    var startError: AudioRecorderError?
    let stopFailure: AudioRecordingStopFailure?
    private var update: (@Sendable (RecordingSnapshot) -> Void)?
    private var partialRecording: (@Sendable (AudioRecording) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(
        events: CaptureEventLog,
        recording: AudioRecording,
        startError: AudioRecorderError?,
        stopFailure: AudioRecordingStopFailure?
    ) {
        self.events = events
        self.recording = recording
        self.startError = startError
        self.stopFailure = stopFailure
    }

    func start(
        at url: URL,
        onUpdate: @escaping @Sendable (RecordingSnapshot) -> Void,
        onPartialRecording: @escaping @Sendable (AudioRecording) -> Void
    ) throws {
        startCount += 1
        events.append("record-start")
        if let startError { throw startError }
        update = onUpdate
        partialRecording = onPartialRecording
    }

    func stop() throws -> AudioRecording {
        stopCount += 1
        events.append("record-stop")
        if let stopFailure { throw stopFailure }
        return recording
    }

    func publish(_ snapshot: RecordingSnapshot) {
        update?(snapshot)
    }

    func publishPartial(_ recording: AudioRecording) {
        partialRecording?(recording)
    }
}

private protocol FixtureTranscriptionEngine: TranscriptionEngine {
    @MainActor var callCount: Int { get }
}

@MainActor
private func waitForLiveDraftStatus(
    _ expected: LiveDraftStatus,
    in controller: CaptureController
) async {
    for _ in 0..<1_000 {
        if controller.state.recordingSnapshot?.liveDraftStatus == expected {
            return
        }
        await Task.yield()
    }
}

private final class ScriptedTranscriptionEngine: FixtureTranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [Result<TranscriptionResult, Error>]
    private var calls = 0
    private var models: [ModelChoice] = []

    init(_ outcomes: [Result<TranscriptionResult, Error>]) {
        self.outcomes = outcomes
    }

    @MainActor var callCount: Int {
        lock.withLock { calls }
    }

    @MainActor var requestModels: [ModelChoice] {
        lock.withLock { models }
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let outcome = lock.withLock {
            calls += 1
            models.append(request.model)
            return outcomes.removeFirst()
        }
        await MainActor.run {
            CaptureFixtureRegistry.events(for: request.audioURL)?.append("transcribe")
        }
        return try outcome.get()
    }
}

private final class SuspendingTranscriptionEngine: FixtureTranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var resultContinuation: CheckedContinuation<TranscriptionResult, Never>?
    private var calledContinuation: CheckedContinuation<Void, Never>?

    @MainActor var callCount: Int { lock.withLock { calls } }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        lock.withLock {
            calls += 1
            calledContinuation?.resume()
            calledContinuation = nil
        }
        await MainActor.run {
            CaptureFixtureRegistry.events(for: request.audioURL)?.append("transcribe")
        }
        return await withCheckedContinuation { continuation in
            lock.withLock { resultContinuation = continuation }
        }
    }

    func waitUntilCalled() async {
        if lock.withLock({ calls > 0 }) { return }
        await withCheckedContinuation { continuation in
            lock.withLock { calledContinuation = continuation }
        }
    }

    func resolve(_ result: TranscriptionResult) {
        lock.withLock {
            resultContinuation?.resume(returning: result)
            resultContinuation = nil
        }
    }
}

@MainActor
private enum CaptureFixtureRegistry {
    private static var values: [URL: CaptureEventLog] = [:]
    static func register(_ events: CaptureEventLog, for url: URL) { values[url] = events }
    static func events(for url: URL) -> CaptureEventLog? { values[url] }
}

@MainActor
private final class SpyCaptureStore: CapturePersisting {
    let events: CaptureEventLog
    let failureCalls: Set<Int>
    private var callCount = 0
    private(set) var saved: [Capture] = []

    init(events: CaptureEventLog, failureCalls: Set<Int>) {
        self.events = events
        self.failureCalls = failureCalls
    }

    func save(_ capture: Capture) throws {
        events.append("persist")
        callCount += 1
        if failureCalls.contains(callCount) {
            throw CaptureFixtureError.persistence
        }
        saved.append(capture)
    }
}

@MainActor
private final class SpyCaptureAudioFiles: CaptureAudioFileManaging {
    let events: CaptureEventLog
    let temporaryURL: URL
    var deleteFailuresRemaining: Int
    private(set) var createdURLs: [URL] = []
    private(set) var deletedURLs: [URL] = []
    private(set) var deleteAttempts = 0
    private(set) var retainAttempts = 0

    init(
        events: CaptureEventLog,
        temporaryURL: URL,
        deleteFailuresRemaining: Int
    ) {
        self.events = events
        self.temporaryURL = temporaryURL
        self.deleteFailuresRemaining = deleteFailuresRemaining
        CaptureFixtureRegistry.register(events, for: temporaryURL)
    }

    func makeTemporaryURL(for id: UUID) throws -> URL {
        createdURLs.append(temporaryURL)
        return temporaryURL
    }

    func removeTemporaryAudio(at url: URL) throws {
        deleteAttempts += 1
        events.append("delete-audio")
        if deleteFailuresRemaining > 0 {
            deleteFailuresRemaining -= 1
            throw CaptureFixtureError.retention
        }
        deletedURLs.append(url)
    }

    func retainTemporaryAudio(at url: URL, captureID: UUID) throws -> RetainedAudio {
        retainAttempts += 1
        events.append("retain-audio")
        let filename = "\(captureID.uuidString).wav"
        return RetainedAudio(
            filename: filename,
            fileURL: URL(fileURLWithPath: "/private/tmp/\(filename)")
        )
    }
}

private enum CaptureFixtureError: Error {
    case persistence
    case retention
}

private final class TapCallbackObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFrameCapacity: AVAudioFrameCount?
    private var recordedMainThread: Bool?

    var frameCapacity: AVAudioFrameCount? {
        lock.withLock { recordedFrameCapacity }
    }

    var ranOnMainThread: Bool? {
        lock.withLock { recordedMainThread }
    }

    func record(frameCapacity: AVAudioFrameCount, ranOnMainThread: Bool) {
        lock.withLock {
            recordedFrameCapacity = frameCapacity
            recordedMainThread = ranOnMainThread
        }
    }
}

private struct UncheckedSendableTapCallback: @unchecked Sendable {
    let callback: AVAudioNodeTapBlock

    init(_ callback: @escaping AVAudioNodeTapBlock) {
        self.callback = callback
    }
}

private extension TranscriptionResult {
    static func fixture(text: String = "Merhaba") -> Self {
        .init(text: text, detectedLanguage: "Turkish", durationSeconds: 0.1)
    }
}
