import Foundation
import Testing
@testable import KotobaneCore

@Test func engineRestartsOnceAfterCrash() async throws {
    let fixture = try AudioFixture(named: "scripted-crash.wav")
    defer { fixture.remove() }
    let completedJSON = responseLine(id: fixture.requestID)
    let launcher = ScriptedProcessLauncher(
        outcomes: [
            .output(.init(stdout: Data(), stderr: Data("crashed".utf8), exitCode: 17)),
            .output(.init(stdout: completedJSON, stderr: Data(), exitCode: 0)),
        ]
    )
    let engine = fixture.engine(launcher: launcher)

    let result = try await engine.transcribe(fixture.request)

    #expect(result.text == "Merhaba")
    #expect(await launcher.launchCount == 2)
}

@Test func engineRestartsOnceAfterEOF() async throws {
    let fixture = try AudioFixture(named: "scripted-eof.wav")
    defer { fixture.remove() }
    let launcher = ScriptedProcessLauncher(
        outcomes: [
            .output(.init(stdout: Data(), stderr: Data("no response".utf8), exitCode: 0)),
            .output(.init(stdout: responseLine(id: fixture.requestID), stderr: Data(), exitCode: 0)),
        ]
    )

    let result = try await fixture.engine(launcher: launcher).transcribe(fixture.request)

    #expect(result.text == "Merhaba")
    #expect(await launcher.launchCount == 2)
}

@Test func engineRestartsOnceAfterTimeout() async throws {
    let fixture = try AudioFixture(named: "scripted-timeout.wav")
    defer { fixture.remove() }
    let launcher = ScriptedProcessLauncher(
        outcomes: [
            .failure(.timedOut),
            .output(.init(stdout: responseLine(id: fixture.requestID), stderr: Data(), exitCode: 0)),
        ]
    )

    let result = try await fixture.engine(launcher: launcher).transcribe(fixture.request)

    #expect(result.text == "Merhaba")
    #expect(await launcher.launchCount == 2)
}

@Test func engineStopsAfterSingleRestart() async throws {
    let fixture = try AudioFixture(named: "double-crash.wav")
    defer { fixture.remove() }
    let launcher = ScriptedProcessLauncher(
        outcomes: [
            .output(.init(stdout: Data(), stderr: Data("first".utf8), exitCode: 10)),
            .output(.init(stdout: Data(), stderr: Data("second".utf8), exitCode: 11)),
        ]
    )

    let failure = await transcriptionFailure {
        try await fixture.engine(launcher: launcher).transcribe(fixture.request)
    }

    #expect(failure == .helperCrashed(exitCode: 11, stderr: "second"))
    #expect(await launcher.launchCount == 2)
}

@Test(arguments: ["model_unavailable", "invalid_audio_path"])
func helperFailuresAreNeverRetried(_ code: String) async throws {
    let fixture = try AudioFixture(named: "\(code).wav")
    defer { fixture.remove() }
    let failed = failedResponseLine(id: fixture.requestID, code: code)
    let launcher = ScriptedProcessLauncher(
        outcomes: [.output(.init(stdout: failed, stderr: Data(), exitCode: 0))]
    )

    let failure = await transcriptionFailure {
        try await fixture.engine(launcher: launcher).transcribe(fixture.request)
    }

    #expect(failure == .helperRejected(code: code, message: "fixture failure"))
    #expect(await launcher.launchCount == 1)
}

@Test(arguments: [
    Data("{".utf8),
    Data(#"{"id":"00000000-0000-0000-0000-000000000001","status":"progress"}"#.utf8),
    Data(
        #"{"detectedLanguage":"tr","durationSeconds":1,"id":"00000000-0000-0000-0000-000000000002","status":"completed","text":"Merhaba"}"#
            .utf8
    ),
])
func protocolFailuresAreNeverRetried(_ stdout: Data) async throws {
    let fixture = try AudioFixture(
        named: "protocol.wav",
        requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )
    defer { fixture.remove() }
    let launcher = ScriptedProcessLauncher(
        outcomes: [.output(.init(stdout: stdout, stderr: Data("diagnostic".utf8), exitCode: 0))]
    )

    let failure = await transcriptionFailure {
        try await fixture.engine(launcher: launcher).transcribe(fixture.request)
    }

    guard case .protocolViolation(let message, let stderr) = failure else {
        Issue.record("Expected protocol violation, got \(String(describing: failure))")
        return
    }
    #expect(!message.isEmpty)
    #expect(stderr == "diagnostic")
    #expect(await launcher.launchCount == 1)
}

@Test func audioOutsideAllowedRootIsRejectedBeforeLaunch() async throws {
    let fixture = try AudioFixture(named: "inside.wav")
    defer { fixture.remove() }
    let outsideRoot = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let outsideAudio = outsideRoot.appending(path: "outside.wav")
    try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
    try Data("RIFF".utf8).write(to: outsideAudio)
    defer { try? FileManager.default.removeItem(at: outsideRoot) }
    let launcher = ScriptedProcessLauncher(outcomes: [])
    let request = TranscriptionRequest(
        id: fixture.requestID,
        audioURL: outsideAudio,
        language: "Turkish",
        model: .small
    )

    let failure = await transcriptionFailure {
        try await fixture.engine(launcher: launcher).transcribe(request)
    }

    #expect(failure == .invalidAudioPath(outsideAudio))
    #expect(await launcher.launchCount == 0)
}

@Test func symlinkedAudioIsRejectedBeforeLaunch() async throws {
    let fixture = try AudioFixture(named: "real.wav")
    defer { fixture.remove() }
    let link = fixture.root.appending(path: "linked.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.audioURL)
    let launcher = ScriptedProcessLauncher(outcomes: [])
    let request = TranscriptionRequest(
        id: fixture.requestID,
        audioURL: link,
        language: "Turkish",
        model: .small
    )

    let failure = await transcriptionFailure {
        try await fixture.engine(launcher: launcher).transcribe(request)
    }

    #expect(failure == .invalidAudioPath(link))
    #expect(await launcher.launchCount == 0)
}

@Test func invocationUsesCanonicalAudioPathOneRequestLineAndOfflineEnvironment() async throws {
    let fixture = try AudioFixture(
        named: "nested/../canonical.wav",
        requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )
    defer { fixture.remove() }
    let launcher = ScriptedProcessLauncher(
        outcomes: [
            .output(.init(stdout: responseLine(id: fixture.requestID), stderr: Data(), exitCode: 0))
        ]
    )

    _ = try await fixture.engine(launcher: launcher).transcribe(fixture.request)

    let invocation = try #require(await launcher.invocations.first)
    #expect(invocation.request.last == Character("\n").asciiValue)
    #expect(invocation.request.filter { $0 == Character("\n").asciiValue }.count == 1)
    #expect(invocation.environment["HF_HUB_OFFLINE"] == "1")
    #expect(invocation.environment["TRANSFORMERS_OFFLINE"] == "1")
    #expect(invocation.environment["NO_PROXY"] == "*")
    let encoded = try #require(String(data: invocation.request, encoding: .utf8))
    #expect(encoded.contains(#""audioPath":"\#(fixture.audioURL.standardizedFileURL.path)""#))
}

@Test func realHelperKeepsStderrSeparateFromSuccessfulResponse() async throws {
    let fixture = try AudioFixture(named: "stderr-success.wav")
    defer { fixture.remove() }

    let result = try await fixture.realEngine(timeout: .seconds(2)).transcribe(fixture.request)

    #expect(result.text == "Merhaba")
}

@Test func realHelperTimeoutTerminatesAndReapsBothAttempts() async throws {
    let fixture = try AudioFixture(named: "timeout.wav")
    defer { fixture.remove() }
    let marker = URL(fileURLWithPath: fixture.audioURL.path + ".terminated")

    let failure = await transcriptionFailure {
        try await fixture.realEngine(timeout: .milliseconds(750)).transcribe(fixture.request)
    }

    #expect(failure == .timedOut)
    let markerText = try String(contentsOf: marker, encoding: .utf8)
    #expect(markerText.split(separator: "\n").count == 2)
}

private actor ScriptedProcessLauncher: ProcessLaunching {
    enum Outcome: Sendable {
        case output(HelperProcessOutput)
        case failure(TranscriptionFailure)
    }

    private var outcomes: [Outcome]
    private(set) var invocations: [HelperProcessInvocation] = []

    var launchCount: Int {
        invocations.count
    }

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func run(_ invocation: HelperProcessInvocation) async throws -> HelperProcessOutput {
        invocations.append(invocation)
        guard !outcomes.isEmpty else {
            throw TranscriptionFailure.helperLaunch("Unexpected launch")
        }
        switch outcomes.removeFirst() {
        case .output(let output):
            return output
        case .failure(let failure):
            throw failure
        }
    }
}

private struct AudioFixture {
    let root: URL
    let audioURL: URL
    let requestID: UUID

    var request: TranscriptionRequest {
        .init(
            id: requestID,
            audioURL: audioURL,
            language: "Turkish",
            model: .small
        )
    }

    init(named name: String, requestID: UUID = UUID()) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let audioURL = root.appending(path: name)
        try FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("RIFF".utf8).write(to: audioURL)
        self.root = root
        self.audioURL = audioURL
        self.requestID = requestID
    }

    func engine(launcher: any ProcessLaunching) -> MLXHelperEngine {
        MLXHelperEngine(
            helperExecutableURL: URL(fileURLWithPath: "/fixture/helper"),
            allowedAudioRoot: root,
            timeout: .seconds(1),
            launcher: launcher
        )
    }

    func realEngine(timeout: Duration) -> MLXHelperEngine {
        MLXHelperEngine(
            helperExecutableURL: fakeHelperURL,
            allowedAudioRoot: root,
            timeout: timeout
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private var fakeHelperURL: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/fake-helper.py")
}

private func responseLine(id: UUID) -> Data {
    Data(
        (
            #"{"detectedLanguage":"tr","durationSeconds":1.25,"id":"\#(id.uuidString.lowercased())","status":"completed","text":"Merhaba"}"#
                + "\n"
        ).utf8
    )
}

private func failedResponseLine(id: UUID, code: String) -> Data {
    Data(
        (
            #"{"code":"\#(code)","id":"\#(id.uuidString.lowercased())","message":"fixture failure","status":"failed"}"#
                + "\n"
        ).utf8
    )
}

private func transcriptionFailure(
    _ operation: () async throws -> TranscriptionResult
) async -> TranscriptionFailure? {
    do {
        _ = try await operation()
        Issue.record("Expected transcription to fail")
        return nil
    } catch let failure as TranscriptionFailure {
        return failure
    } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
    }
}
