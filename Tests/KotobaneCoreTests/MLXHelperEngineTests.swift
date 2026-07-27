import Foundation
import Darwin
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

@Test func completedResponseWithoutTrailingNewlineIsRejectedWithoutRetry() async throws {
    let fixture = try AudioFixture(named: "missing-newline.wav")
    defer { fixture.remove() }
    let stdout = Data(
        #"{"detectedLanguage":"tr","durationSeconds":1.25,"id":"\#(fixture.requestID.uuidString.lowercased())","status":"completed","text":"Merhaba"}"#
            .utf8
    )
    let launcher = ScriptedProcessLauncher(
        outcomes: [.output(.init(stdout: stdout, stderr: Data(), exitCode: 0))]
    )

    let failure = await transcriptionFailure {
        try await fixture.engine(launcher: launcher).transcribe(fixture.request)
    }

    guard case .protocolViolation(let message, _) = failure else {
        Issue.record("Expected protocol violation, got \(String(describing: failure))")
        return
    }
    #expect(message.contains("newline"))
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

@Test func configuredRuntimeBinPrecedesSystemPythonForHelperLaunch() async throws {
    let fixture = try AudioFixture(named: "runtime-path.wav")
    defer { fixture.remove() }
    let launcher = ScriptedProcessLauncher(
        outcomes: [.output(.init(stdout: responseLine(id: fixture.requestID), stderr: Data(), exitCode: 0))]
    )
    let runtimeBin = URL(fileURLWithPath: "/private/Kotobane/runtime/venv/bin")
    let engine = MLXHelperEngine(
        helperExecutableURL: URL(fileURLWithPath: "/fixture/helper"),
        allowedAudioRoot: fixture.root,
        timeout: .seconds(1),
        runtimeBinDirectory: runtimeBin,
        launcher: launcher
    )

    _ = try await engine.transcribe(fixture.request)

    let invocation = try #require(await launcher.invocations.first)
    #expect(invocation.environment["PATH"]?.hasPrefix(runtimeBin.path + ":") == true)
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

@Test func cancellingRealHelperTerminatesReapsAndDoesNotRetry() async throws {
    let fixture = try AudioFixture(named: "cancel-hostile.wav")
    defer { fixture.remove() }
    let pidsURL = URL(fileURLWithPath: fixture.audioURL.path + ".pids")
    let engine = fixture.realEngine(
        timeout: .seconds(5),
        limits: .init(terminationGrace: .milliseconds(75))
    )
    let task = Task {
        try await engine.transcribe(fixture.request)
    }
    try await waitForFile(pidsURL)

    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
    }
    let pids = try recordedPIDs(at: pidsURL)
    #expect(pids.count == 1)
    for pid in pids {
        #expect(!processExists(pid))
    }
}

@Test func hostileTimeoutEscalatesToSIGKILLAndReapsBothAttempts() async throws {
    let fixture = try AudioFixture(named: "hostile-timeout.wav")
    defer { fixture.remove() }
    let pidsURL = URL(fileURLWithPath: fixture.audioURL.path + ".pids")
    let limits = HelperProcessLimits(terminationGrace: .milliseconds(75))

    let failure = await transcriptionFailure {
        try await fixture.realEngine(
            timeout: .milliseconds(350),
            limits: limits
        ).transcribe(fixture.request)
    }

    #expect(failure == .timedOut)
    let pids = try recordedPIDs(at: pidsURL)
    #expect(pids.count == 2)
    for pid in pids {
        #expect(!processExists(pid))
    }
}

@Test func oversizedStdoutIsANonRetryableProtocolFailure() async throws {
    let fixture = try AudioFixture(named: "oversized-stdout.wav")
    defer { fixture.remove() }
    let limits = HelperProcessLimits(maximumStdoutBytes: 256)

    let failure = await transcriptionFailure {
        try await fixture.realEngine(timeout: .seconds(2), limits: limits)
            .transcribe(fixture.request)
    }

    guard case .protocolViolation(let message, _) = failure else {
        Issue.record("Expected protocol violation, got \(String(describing: failure))")
        return
    }
    #expect(message.contains("stdout"))
    #expect(try recordedPIDs(at: URL(fileURLWithPath: fixture.audioURL.path + ".pids")).count == 1)
}

@Test func oversizedStderrIsANonRetryableProtocolFailureWithBoundedDiagnostics() async throws {
    let fixture = try AudioFixture(named: "oversized-stderr.wav")
    defer { fixture.remove() }
    let limits = HelperProcessLimits(maximumStderrBytes: 256)

    let failure = await transcriptionFailure {
        try await fixture.realEngine(timeout: .seconds(2), limits: limits)
            .transcribe(fixture.request)
    }

    guard case .protocolViolation(let message, let stderr) = failure else {
        Issue.record("Expected protocol violation, got \(String(describing: failure))")
        return
    }
    #expect(message.contains("stderr"))
    #expect(Data(stderr.utf8).count <= 256)
    #expect(try recordedPIDs(at: URL(fileURLWithPath: fixture.audioURL.path + ".pids")).count == 1)
}

@Test func descendantHoldingPipesOpenCannotDelaySuccessfulResponse() async throws {
    let fixture = try AudioFixture(named: "descendant-held-pipe.wav")
    defer { fixture.remove() }
    let clock = ContinuousClock()
    let start = clock.now

    let result = try await fixture.realEngine(timeout: .seconds(2)).transcribe(fixture.request)

    #expect(result.text == "Merhaba")
    #expect(start.duration(to: clock.now) < .seconds(1))
    let descendantPID = try #require(
        recordedPIDs(
            at: URL(fileURLWithPath: fixture.audioURL.path + ".descendant-pid")
        ).first
    )
    try await waitForProcessExit(descendantPID)
    #expect(!processExists(descendantPID))
}

@Test func launcherResumesOnlyAfterDirectProcessAndAllIOWorkersExit() async throws {
    let fixture = try AudioFixture(named: "worker-order.wav")
    defer { fixture.remove() }
    let observer = RecordingProcessLifecycleObserver()

    let result = try await fixture.realEngine(
        timeout: .seconds(2),
        observer: observer
    ).transcribe(fixture.request)

    #expect(result.text == "Merhaba")
    let events = observer.events
    let resume = try #require(events.firstIndex(of: .willResume))
    for event in [
        ProcessLifecycleEvent.directProcessExited,
        .stdinWorkerExited,
        .stdoutWorkerExited,
        .stderrWorkerExited,
    ] {
        let exit = try #require(events.firstIndex(of: event))
        #expect(exit < resume)
    }
}

@Test func delayedSecondResponseRecordIsDrainedAndRejectedWithoutRetry() async throws {
    let fixture = try AudioFixture(named: "delayed-second-record.wav")
    defer { fixture.remove() }
    let pidsURL = URL(fileURLWithPath: fixture.audioURL.path + ".pids")
    let clock = ContinuousClock()
    let start = clock.now

    let failure = await transcriptionFailure {
        try await fixture.realEngine(timeout: .seconds(2)).transcribe(fixture.request)
    }

    guard case .protocolViolation(let message, _) = failure else {
        Issue.record("Expected protocol violation, got \(String(describing: failure))")
        return
    }
    #expect(message.contains("exactly one"))
    #expect(start.duration(to: clock.now) >= .milliseconds(150))
    #expect(try recordedPIDs(at: pidsURL).count == 1)
}

@Test func helperExitingBeforeReadingRequestIsClassifiedAsCrashAndRetriedOnce() async throws {
    let fixture = try AudioFixture(named: "exit-before-read.wav")
    defer { fixture.remove() }
    let marker = fixture.root.appending(path: "exit-before-read.marker")
    let limits = HelperProcessLimits(
        maximumLanguageBytes: 96 * 1024,
        maximumRequestBytes: 128 * 1024
    )
    let request = TranscriptionRequest(
        id: fixture.requestID,
        audioURL: fixture.audioURL,
        language: String(repeating: "a", count: 80 * 1024),
        model: .small
    )

    let result = try await fixture.realEngine(
        timeout: .seconds(2),
        limits: limits,
        forcedMode: "exit-before-read-once",
        markerURL: marker
    ).transcribe(request)

    #expect(result.text == "Merhaba")
    #expect(try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").count == 1)
}

@Test func processRunFailureIsHelperLaunchAndIsNotRetried() async throws {
    let fixture = try AudioFixture(named: "launch-failure.wav")
    defer { fixture.remove() }
    let isolation = CountingNoopIsolation()
    let engine = MLXHelperEngine(
        helperExecutableURL: URL(fileURLWithPath: "/definitely/missing/helper"),
        allowedAudioRoot: fixture.root,
        timeout: .seconds(1),
        launcher: FoundationProcessLauncher(isolation: isolation)
    )

    let failure = await transcriptionFailure {
        try await engine.transcribe(fixture.request)
    }

    guard case .helperLaunch = failure else {
        Issue.record("Expected helper launch failure, got \(String(describing: failure))")
        return
    }
    #expect(isolation.commandCount == 0)
}

@Test func oversizedInputIsRejectedBeforeLaunch() async throws {
    let fixture = try AudioFixture(named: "oversized-input.wav")
    defer { fixture.remove() }
    let launcher = ScriptedProcessLauncher(outcomes: [])
    let request = TranscriptionRequest(
        id: fixture.requestID,
        audioURL: fixture.audioURL,
        language: String(repeating: "ü", count: 200),
        model: .small
    )
    let engine = fixture.engine(
        launcher: launcher,
        limits: .init(maximumLanguageBytes: 64)
    )

    let failure = await transcriptionFailure {
        try await engine.transcribe(request)
    }

    #expect(failure == .invalidRequest("language exceeds 64 UTF-8 bytes"))
    #expect(await launcher.launchCount == 0)
}

@Test func nonReadingHelperRequestWriteIsBoundedByTimeout() async throws {
    let fixture = try AudioFixture(named: "non-reading.wav")
    defer { fixture.remove() }
    let pidsURL = fixture.root.appending(path: "non-reading.pids")
    let limits = HelperProcessLimits(
        maximumLanguageBytes: 96 * 1024,
        maximumRequestBytes: 128 * 1024,
        terminationGrace: .milliseconds(75)
    )
    let request = TranscriptionRequest(
        id: fixture.requestID,
        audioURL: fixture.audioURL,
        language: String(repeating: "a", count: 80 * 1024),
        model: .small
    )

    let failure = await transcriptionFailure {
        try await fixture.realEngine(
            timeout: .milliseconds(350),
            limits: limits,
            forcedMode: "non-reading",
            markerURL: pidsURL
        ).transcribe(request)
    }

    #expect(failure == .timedOut)
    let pids = try recordedPIDs(at: pidsURL)
    #expect(pids.count == 2)
    for pid in pids {
        #expect(!processExists(pid))
    }
}

@Test func productionIsolationUsesExactDenyNetworkSandboxWrapper() throws {
    let helperURL = URL(fileURLWithPath: "/fixture/helper")

    let command = try SandboxExecNetworkIsolation(
        launchShimExecutableURL: URL(fileURLWithPath: "/fixture/launch-shim")
    ).command(for: helperURL)

    #expect(command.executableURL.path == "/usr/bin/sandbox-exec")
    #expect(
        command.arguments == [
            "-p",
            "(version 1)\n(allow default)\n(deny network*)\n",
            "/fixture/launch-shim",
            "63",
            "64",
            "/fixture/helper",
        ]
    )
    #expect(command.isolationHandshakeDescriptor == 63)
    #expect(command.execStatusDescriptor == 64)
}

@Test func developmentIsolationUsesLaunchShimBesideSwiftPMExecutable() {
    let executable = URL(fileURLWithPath: "/tmp/.build/arm64-apple-macosx/debug/Kotobane")
    let expected = executable
        .deletingLastPathComponent()
        .appending(path: "kotobane-launch-shim")

    let resolved = SandboxExecNetworkIsolation.defaultLaunchShimURL(
        bundleURL: URL(fileURLWithPath: "/tmp/.build/arm64-apple-macosx/debug"),
        executableURL: executable,
        isExecutable: { $0 == expected }
    )

    #expect(resolved == expected)
}

@Test func productionSandboxStrategyRunsHelperOnlyAfterIsolationHandshake() async throws {
    let fixture = try AudioFixture(named: "production-wrapper.wav")
    defer { fixture.remove() }
    let invocation = try fixture.directInvocation(
        environment: [
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "NO_PROXY": "*",
        ]
    )
    let launcher = FoundationProcessLauncher(
        isolation: SandboxExecNetworkIsolation(
            sandboxExecutableURL: fakeHelperURL,
            launchShimExecutableURL: testLaunchShimURL
        )
    )

    let output = try await launcher.run(invocation)

    #expect(output.exitCode == 0)
    #expect(!output.stdout.isEmpty)
}

@Test func productionSandboxRejectionIsNonRetryableIsolationFailure() async throws {
    let fixture = try AudioFixture(named: "production-rejection.wav")
    defer { fixture.remove() }
    let invocation = try fixture.directInvocation(
        environment: ["KOTOBANE_FAKE_SANDBOX_MODE": "reject"]
    )
    let launcher = FoundationProcessLauncher(
        isolation: SandboxExecNetworkIsolation(
            sandboxExecutableURL: fakeHelperURL,
            launchShimExecutableURL: testLaunchShimURL
        )
    )

    do {
        _ = try await launcher.run(invocation)
        Issue.record("Expected isolation failure")
    } catch let failure as TranscriptionFailure {
        guard case .isolationUnavailable(let diagnostic) = failure else {
            Issue.record("Expected isolation failure, got \(failure)")
            return
        }
        #expect(diagnostic.contains("fixture sandbox rejected"))
        #expect(!failure.permitsRestart)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func invalidExecutableFormatIsNonRetryableHelperLaunch() async throws {
    let fixture = try AudioFixture(named: "invalid-format-audio.wav")
    defer { fixture.remove() }
    let invalidHelper = try makeExecutableFixture(
        in: fixture.root,
        named: "invalid-format-helper",
        contents: "this is not an executable image"
    )
    let observer = RecordingProcessLifecycleObserver()
    let launcher = FoundationProcessLauncher(
        isolation: SandboxExecNetworkIsolation(
            sandboxExecutableURL: fakeHelperURL,
            launchShimExecutableURL: testLaunchShimURL
        ),
        lifecycleObserver: observer
    )
    let engine = MLXHelperEngine(
        helperExecutableURL: invalidHelper,
        allowedAudioRoot: fixture.root,
        timeout: .seconds(2),
        launcher: launcher
    )

    let failure = await transcriptionFailure {
        try await engine.transcribe(fixture.request)
    }

    guard case .helperLaunch(let diagnostic) = failure else {
        Issue.record("Expected helper launch failure, got \(String(describing: failure))")
        return
    }
    #expect(diagnostic.contains("errno"))
    #expect(!observer.events.contains(.stdinWorkerExited))
    #expect(observer.events.filter { $0 == .directProcessExited }.count == 1)
}

@Test func missingShebangInterpreterIsNonRetryableHelperLaunch() async throws {
    let fixture = try AudioFixture(named: "missing-interpreter-audio.wav")
    defer { fixture.remove() }
    let invalidHelper = try makeExecutableFixture(
        in: fixture.root,
        named: "missing-interpreter-helper",
        contents: "#!/definitely/missing/kotobane-interpreter\n"
    )
    let observer = RecordingProcessLifecycleObserver()
    let launcher = FoundationProcessLauncher(
        isolation: SandboxExecNetworkIsolation(
            sandboxExecutableURL: fakeHelperURL,
            launchShimExecutableURL: testLaunchShimURL
        ),
        lifecycleObserver: observer
    )
    let engine = MLXHelperEngine(
        helperExecutableURL: invalidHelper,
        allowedAudioRoot: fixture.root,
        timeout: .seconds(2),
        launcher: launcher
    )

    let failure = await transcriptionFailure {
        try await engine.transcribe(fixture.request)
    }

    guard case .helperLaunch(let diagnostic) = failure else {
        Issue.record("Expected helper launch failure, got \(String(describing: failure))")
        return
    }
    #expect(diagnostic.contains("errno 2"))
    #expect(!observer.events.contains(.stdinWorkerExited))
    #expect(observer.events.filter { $0 == .directProcessExited }.count == 1)
}

@Test func helperRemovedAfterPrevalidationIsNonRetryableHelperLaunch() async throws {
    let fixture = try AudioFixture(named: "removed-helper-audio.wav")
    defer { fixture.remove() }
    let helper = try makeExecutableFixture(
        in: fixture.root,
        named: "removed-helper",
        contents: "#!/bin/sh\nexit 0\n"
    )
    let observer = RecordingProcessLifecycleObserver()
    let launcher = FoundationProcessLauncher(
        isolation: SandboxExecNetworkIsolation(
            sandboxExecutableURL: fakeHelperURL,
            launchShimExecutableURL: testLaunchShimURL
        ),
        lifecycleObserver: observer,
        preSpawnHook: {
            try! FileManager.default.removeItem(at: helper)
        }
    )
    let engine = MLXHelperEngine(
        helperExecutableURL: helper,
        allowedAudioRoot: fixture.root,
        timeout: .seconds(2),
        launcher: launcher
    )

    let failure = await transcriptionFailure {
        try await engine.transcribe(fixture.request)
    }

    guard case .helperLaunch(let diagnostic) = failure else {
        Issue.record("Expected helper launch failure, got \(String(describing: failure))")
        return
    }
    #expect(diagnostic.contains("errno 2"))
    #expect(!observer.events.contains(.stdinWorkerExited))
    #expect(observer.events.filter { $0 == .directProcessExited }.count == 1)
}

@Test func sandboxRejectionWinsBeforeLargeRequestWriterCanStart() async throws {
    let fixture = try AudioFixture(named: "sandbox-rejection-large.wav")
    defer { fixture.remove() }
    let rejectingSandbox = try makeExecutableFixture(
        in: fixture.root,
        named: "rejecting-sandbox",
        contents: "#!/bin/sh\necho fixture sandbox rejected profile >&2\nexit 78\n"
    )
    let observer = RecordingProcessLifecycleObserver()
    let launcher = FoundationProcessLauncher(
        isolation: SandboxExecNetworkIsolation(
            sandboxExecutableURL: rejectingSandbox,
            launchShimExecutableURL: testLaunchShimURL
        ),
        lifecycleObserver: observer
    )
    let limits = HelperProcessLimits(
        maximumLanguageBytes: 96 * 1024,
        maximumRequestBytes: 128 * 1024,
        terminationGrace: .milliseconds(75)
    )
    let engine = MLXHelperEngine(
        helperExecutableURL: fakeHelperURL,
        allowedAudioRoot: fixture.root,
        timeout: .seconds(2),
        limits: limits,
        launcher: launcher
    )
    let request = TranscriptionRequest(
        id: fixture.requestID,
        audioURL: fixture.audioURL,
        language: String(repeating: "a", count: 80 * 1024),
        model: .small
    )

    let failure = await transcriptionFailure {
        try await engine.transcribe(request)
    }

    guard case .isolationUnavailable(let diagnostic) = failure else {
        Issue.record("Expected isolation failure, got \(String(describing: failure))")
        return
    }
    #expect(diagnostic.contains("fixture sandbox rejected"))
    #expect(!observer.events.contains(.stdinWorkerExited))
    #expect(observer.events.filter { $0 == .directProcessExited }.count == 1)
}

@Test func successfulExecHandshakeKeepsActualHelperCrashRetryableOnce() async throws {
    let fixture = try AudioFixture(named: "crash.wav")
    defer { fixture.remove() }
    let observer = RecordingProcessLifecycleObserver()
    let launcher = FoundationProcessLauncher(
        isolation: SandboxExecNetworkIsolation(
            sandboxExecutableURL: fakeHelperURL,
            launchShimExecutableURL: testLaunchShimURL
        ),
        lifecycleObserver: observer
    )
    let engine = MLXHelperEngine(
        helperExecutableURL: fakeHelperURL,
        allowedAudioRoot: fixture.root,
        timeout: .seconds(2),
        launcher: launcher
    )

    let failure = await transcriptionFailure {
        try await engine.transcribe(fixture.request)
    }

    guard case .helperCrashed(let exitCode, let stderr) = failure else {
        Issue.record("Expected helper crash, got \(String(describing: failure))")
        return
    }
    #expect(exitCode == 17)
    #expect(stderr.contains("fixture crash"))
    #expect(observer.events.filter { $0 == .directProcessExited }.count == 2)
    let firstExec = try #require(
        observer.events.firstIndex(of: .execStatusWorkerExited)
    )
    let firstInput = try #require(
        observer.events.firstIndex(of: .stdinWorkerExited)
    )
    #expect(firstExec < firstInput)
}

@Test func hostileDescendantsWithoutSelfGroupingAreKilledAsOneSpawnGroup() async throws {
    let fixture = try AudioFixture(named: "hostile-descendant-timeout.wav")
    defer { fixture.remove() }
    let pidsURL = URL(fileURLWithPath: fixture.audioURL.path + ".pids")
    let observer = RecordingProcessLifecycleObserver()

    let failure = await transcriptionFailure {
        try await fixture.realEngine(
            timeout: .milliseconds(350),
            limits: .init(terminationGrace: .milliseconds(75)),
            observer: observer
        ).transcribe(fixture.request)
    }

    #expect(failure == .timedOut)
    let pids = try recordedPIDs(at: pidsURL)
    #expect(pids.count == 4)
    for pid in pids {
        try await waitForProcessExit(pid)
        #expect(!processExists(pid))
    }
    let signals = observer.events.compactMap { event -> (UUID, Int32)? in
        guard case .signal(let generation, let signal) = event else {
            return nil
        }
        return (generation, signal)
    }
    #expect(signals.filter { $0.1 == SIGTERM }.count == 2)
    #expect(signals.filter { $0.1 == SIGKILL }.count == 2)
    #expect(Set(signals.map(\.0)).count == 2)
}

@Test func productionIsolationFailsClosedWhenSandboxExecIsUnavailable() async {
    let missingSandbox = URL(fileURLWithPath: "/definitely/missing/sandbox-exec")
    let launcher = FoundationProcessLauncher(
        isolation: SandboxExecNetworkIsolation(sandboxExecutableURL: missingSandbox)
    )
    let invocation = HelperProcessInvocation(
        executableURL: fakeHelperURL,
        request: Data("{}\n".utf8),
        environment: [:],
        timeout: .seconds(1)
    )

    do {
        _ = try await launcher.run(invocation)
        Issue.record("Expected network isolation installation to fail closed")
    } catch let failure as TranscriptionFailure {
        #expect(failure == .isolationUnavailable(missingSandbox.path))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
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

    func engine(
        launcher: any ProcessLaunching,
        limits: HelperProcessLimits = .init()
    ) -> MLXHelperEngine {
        MLXHelperEngine(
            helperExecutableURL: URL(fileURLWithPath: "/fixture/helper"),
            allowedAudioRoot: root,
            timeout: .seconds(1),
            limits: limits,
            launcher: launcher
        )
    }

    func realEngine(
        timeout: Duration,
        limits: HelperProcessLimits = .init(),
        forcedMode: String? = nil,
        markerURL: URL? = nil,
        observer: (any ProcessLifecycleObserving)? = nil
    ) -> MLXHelperEngine {
        let isolation = TestProcessIsolation(
            forcedMode: forcedMode,
            markerURL: markerURL
        )
        let launcher: FoundationProcessLauncher
        if let observer {
            launcher = FoundationProcessLauncher(
                isolation: isolation,
                lifecycleObserver: observer
            )
        } else {
            launcher = FoundationProcessLauncher(isolation: isolation)
        }
        return MLXHelperEngine(
            helperExecutableURL: fakeHelperURL,
            allowedAudioRoot: root,
            timeout: timeout,
            limits: limits,
            launcher: launcher
        )
    }

    func directInvocation(environment: [String: String]) throws -> HelperProcessInvocation {
        let request = HelperRequest(
            id: requestID,
            action: "transcribe",
            audioPath: audioURL.path,
            language: "Turkish",
            model: ModelChoice.small.rawValue
        )
        var mergedEnvironment = ProcessInfo.processInfo.environment
        mergedEnvironment.merge(environment) { _, new in new }
        return HelperProcessInvocation(
            executableURL: fakeHelperURL,
            request: Data(try HelperCodec.encode(request).utf8),
            environment: mergedEnvironment,
            timeout: .seconds(2)
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

private var testLaunchShimURL: URL {
    guard let path = ProcessInfo.processInfo.environment["KOTOBANE_TEST_LAUNCH_SHIM"] else {
        fatalError("scripts/swift-test.sh must provide KOTOBANE_TEST_LAUNCH_SHIM")
    }
    return URL(fileURLWithPath: path)
}

private func makeExecutableFixture(
    in directory: URL,
    named name: String,
    contents: String
) throws -> URL {
    let url = directory.appending(path: name)
    try Data(contents.utf8).write(to: url)
    guard chmod(url.path, 0o700) == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
    return url
}

private struct TestProcessIsolation: HelperProcessIsolating {
    let forcedMode: String?
    let markerURL: URL?

    func command(for helperExecutableURL: URL) throws -> HelperProcessCommand {
        var arguments: [String] = []
        if let forcedMode {
            arguments.append(forcedMode)
        }
        if let markerURL {
            arguments.append(markerURL.path)
        }
        return HelperProcessCommand(
            executableURL: helperExecutableURL,
            arguments: arguments
        )
    }
}

private final class CountingNoopIsolation: HelperProcessIsolating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var commandCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func command(for helperExecutableURL: URL) throws -> HelperProcessCommand {
        lock.lock()
        count += 1
        lock.unlock()
        return HelperProcessCommand(executableURL: helperExecutableURL, arguments: [])
    }
}

private final class RecordingProcessLifecycleObserver:
    ProcessLifecycleObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedEvents: [ProcessLifecycleEvent] = []

    var events: [ProcessLifecycleEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func processLifecycleDidEmit(_ event: ProcessLifecycleEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
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

private func waitForFile(_ url: URL) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !FileManager.default.fileExists(atPath: url.path) {
        guard clock.now < deadline else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try await clock.sleep(for: .milliseconds(10))
    }
}

private func waitForProcessExit(_ pid: pid_t) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while processExists(pid) {
        guard clock.now < deadline else {
            return
        }
        try await clock.sleep(for: .milliseconds(10))
    }
}

private func recordedPIDs(at url: URL) throws -> [pid_t] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .compactMap { pid_t($0) }
}

private func processExists(_ pid: pid_t) -> Bool {
    errno = 0
    if kill(pid, 0) == 0 {
        return true
    }
    return errno != ESRCH
}
