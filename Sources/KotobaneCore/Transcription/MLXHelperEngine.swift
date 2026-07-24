import Foundation

public struct HelperProcessInvocation: Sendable {
    public let executableURL: URL
    public let request: Data
    public let environment: [String: String]
    public let timeout: Duration

    public init(
        executableURL: URL,
        request: Data,
        environment: [String: String],
        timeout: Duration
    ) {
        self.executableURL = executableURL
        self.request = request
        self.environment = environment
        self.timeout = timeout
    }
}

public struct HelperProcessOutput: Equatable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol ProcessLaunching: Sendable {
    func run(_ invocation: HelperProcessInvocation) async throws -> HelperProcessOutput
}

public struct MLXHelperEngine: TranscriptionEngine, Sendable {
    private let helperExecutableURL: URL
    private let allowedAudioRoot: URL
    private let timeout: Duration
    private let launcher: any ProcessLaunching

    public init(
        helperExecutableURL: URL,
        allowedAudioRoot: URL,
        timeout: Duration,
        launcher: any ProcessLaunching = FoundationProcessLauncher()
    ) {
        self.helperExecutableURL = helperExecutableURL
        self.allowedAudioRoot = allowedAudioRoot
        self.timeout = timeout
        self.launcher = launcher
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let audioURL = try validatedAudioURL(request.audioURL)
        let helperRequest = HelperRequest(
            id: request.id,
            action: "transcribe",
            audioPath: audioURL.path,
            language: request.language,
            model: request.model.rawValue
        )
        let requestLine = try Data(HelperCodec.encode(helperRequest).utf8)
        let invocation = HelperProcessInvocation(
            executableURL: helperExecutableURL,
            request: requestLine,
            environment: Self.offlineEnvironment,
            timeout: timeout
        )

        for attempt in 0...1 {
            do {
                return try await transcribeOnce(invocation, requestID: request.id)
            } catch let failure as TranscriptionFailure {
                if attempt == 0, failure.permitsRestart {
                    continue
                }
                throw failure
            } catch {
                throw TranscriptionFailure.helperLaunch(error.localizedDescription)
            }
        }
        preconditionFailure("Retry loop must return or throw")
    }

    private func validatedAudioURL(_ audioURL: URL) throws -> URL {
        let standardized = audioURL.standardizedFileURL
        do {
            let exists = try StoragePathGuard(
                root: allowedAudioRoot,
                fileManager: .default
            ).validate(standardized)
            guard exists else {
                throw TranscriptionFailure.invalidAudioPath(audioURL)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: standardized.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw TranscriptionFailure.invalidAudioPath(audioURL)
            }
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        } catch is StoragePathError {
            throw TranscriptionFailure.invalidAudioPath(audioURL)
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch {
            throw TranscriptionFailure.invalidAudioPath(audioURL)
        }
    }

    private func transcribeOnce(
        _ invocation: HelperProcessInvocation,
        requestID: UUID
    ) async throws -> TranscriptionResult {
        let output = try await launcher.run(invocation)
        let stderr = String(decoding: output.stderr, as: UTF8.self)

        guard output.exitCode == 0 else {
            throw TranscriptionFailure.helperCrashed(
                exitCode: output.exitCode,
                stderr: stderr
            )
        }
        guard !output.stdout.isEmpty else {
            throw TranscriptionFailure.unexpectedEOF(stderr: stderr)
        }

        let line: Data
        do {
            line = try Self.singleResponseLine(from: output.stdout)
        } catch let failure as TranscriptionFailure {
            throw TranscriptionFailure.protocolViolation(
                message: failure.protocolMessage,
                stderr: stderr
            )
        }

        let response: HelperResponse
        do {
            response = try HelperCodec.decode(line, expectedID: requestID)
        } catch {
            throw TranscriptionFailure.protocolViolation(
                message: String(describing: error),
                stderr: stderr
            )
        }

        switch response {
        case .completed(let completed):
            return TranscriptionResult(
                text: completed.text,
                detectedLanguage: completed.detectedLanguage,
                durationSeconds: completed.durationSeconds
            )
        case .failed(let failed):
            throw TranscriptionFailure.helperRejected(
                code: failed.code,
                message: failed.message
            )
        }
    }

    private static func singleResponseLine(from data: Data) throws -> Data {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard lines.count == 1, let line = lines.first, !line.isEmpty else {
            throw TranscriptionFailure.protocolViolation(
                message: "Expected exactly one response line",
                stderr: ""
            )
        }
        return Data(line)
    }

    private static var offlineEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["NO_PROXY"] = "*"
        return environment
    }
}

public struct FoundationProcessLauncher: ProcessLaunching {
    public init() {}

    public func run(_ invocation: HelperProcessInvocation) async throws -> HelperProcessOutput {
        let execution = ProcessExecution(invocation: invocation)
        do {
            try execution.launch()
            try execution.sendRequest(invocation.request)
        } catch {
            execution.terminate()
            execution.reapIfRunning()
            throw TranscriptionFailure.helperLaunch(error.localizedDescription)
        }

        async let stdout = execution.readStdout()
        async let stderr = execution.readStderr()
        let didTimeOut = await execution.wait(timeout: invocation.timeout)
        let output = await HelperProcessOutput(
            stdout: stdout,
            stderr: stderr,
            exitCode: execution.exitCode
        )
        if didTimeOut {
            throw TranscriptionFailure.timedOut
        }
        return output
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()

    init(invocation: HelperProcessInvocation) {
        process.executableURL = invocation.executableURL
        process.environment = invocation.environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    var exitCode: Int32 {
        process.terminationStatus
    }

    func launch() throws {
        try process.run()
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
    }

    func sendRequest(_ request: Data) throws {
        defer { stdin.fileHandleForWriting.closeFile() }
        try stdin.fileHandleForWriting.write(contentsOf: request)
    }

    func readStdout() -> Data {
        stdout.fileHandleForReading.readDataToEndOfFile()
    }

    func readStderr() -> Data {
        stderr.fileHandleForReading.readDataToEndOfFile()
    }

    func wait(timeout: Duration) async -> Bool {
        enum Event {
            case exited
            case timedOut
            case cancelled
        }

        return await withTaskGroup(of: Event.self) { group in
            group.addTask {
                self.waitUntilExit()
                return .exited
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }

            let first = await group.next()
            if case .timedOut = first {
                terminate()
            }
            group.cancelAll()
            while await group.next() != nil {}
            return first == .timedOut
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    func reapIfRunning() {
        if process.isRunning {
            process.waitUntilExit()
        }
    }

    private func waitUntilExit() {
        process.waitUntilExit()
    }
}

private extension TranscriptionFailure {
    var protocolMessage: String {
        switch self {
        case .protocolViolation(let message, _):
            message
        default:
            String(describing: self)
        }
    }
}
