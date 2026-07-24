import Foundation

public struct MLXHelperEngine: TranscriptionEngine, Sendable {
    private let helperExecutableURL: URL
    private let allowedAudioRoot: URL
    private let timeout: Duration
    private let limits: HelperProcessLimits
    private let launcher: any ProcessLaunching

    public init(
        helperExecutableURL: URL,
        allowedAudioRoot: URL,
        timeout: Duration,
        limits: HelperProcessLimits = .init(),
        launcher: any ProcessLaunching = FoundationProcessLauncher()
    ) {
        self.helperExecutableURL = helperExecutableURL
        self.allowedAudioRoot = allowedAudioRoot
        self.timeout = timeout
        self.limits = limits
        self.launcher = launcher
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let audioURL = try validatedAudioURL(request.audioURL)
        let helperRequest = HelperRequest(
            id: request.id,
            action: "transcribe",
            audioPath: audioURL.path,
            language: request.language,
            model: request.model.rawValue
        )
        let requestLine: Data
        do {
            requestLine = try Data(HelperCodec.encode(helperRequest, limits: limits).utf8)
        } catch let error as HelperCodecError {
            throw TranscriptionFailure.invalidRequest(error.requestDescription)
        }
        let invocation = HelperProcessInvocation(
            executableURL: helperExecutableURL,
            request: requestLine,
            environment: Self.offlineEnvironment,
            timeout: timeout,
            limits: limits
        )

        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                return try await transcribeOnce(invocation, requestID: request.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as TranscriptionFailure {
                if attempt == 0, failure.permitsRestart {
                    continue
                }
                throw failure
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
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
        guard data.last == 0x0A else {
            throw TranscriptionFailure.protocolViolation(
                message: "Response must be newline-terminated",
                stderr: ""
            )
        }
        let line = data.dropLast()
        guard !line.isEmpty, !line.contains(0x0A) else {
            throw TranscriptionFailure.protocolViolation(
                message: "Expected exactly one newline-terminated response record",
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

private extension HelperCodecError {
    var requestDescription: String {
        switch self {
        case .fieldTooLarge(let field, let maximumBytes):
            "\(field) exceeds \(maximumBytes) UTF-8 bytes"
        case .requestTooLarge(let maximumBytes):
            "request exceeds \(maximumBytes) UTF-8 bytes"
        case .malformedResponse, .unknownStatus, .mismatchedID:
            String(describing: self)
        }
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
