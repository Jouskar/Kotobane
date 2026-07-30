import Foundation

public final class PersistentMLXHelperEngine: TranscriptionEngine, @unchecked Sendable {
    private let worker: PersistentHelperWorker
    private let allowedAudioRoot: URL
    private let limits: HelperProcessLimits

    public init(
        helperExecutableURL: URL,
        allowedAudioRoot: URL,
        runtimeBinDirectory: URL? = nil,
        limits: HelperProcessLimits = .init()
    ) {
        self.allowedAudioRoot = allowedAudioRoot
        self.limits = limits
        worker = PersistentHelperWorker(
            helperExecutableURL: helperExecutableURL,
            runtimeBinDirectory: runtimeBinDirectory
        )
    }

    deinit {
        worker.stop()
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
        let line: Data
        do {
            line = try Data(HelperCodec.encode(helperRequest, limits: limits).utf8)
        } catch let error as HelperCodecError {
            throw TranscriptionFailure.invalidRequest(String(describing: error))
        }

        let output = try await worker.run(request: line)
        let response: HelperResponse
        do {
            response = try HelperCodec.decode(output, expectedID: request.id)
        } catch {
            throw TranscriptionFailure.protocolViolation(
                message: String(describing: error),
                stderr: ""
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

    private func validatedAudioURL(_ audioURL: URL) throws -> URL {
        let standardized = audioURL.standardizedFileURL
        do {
            let exists = try StoragePathGuard(
                root: allowedAudioRoot,
                fileManager: .default
            ).validate(standardized)
            guard exists else { throw TranscriptionFailure.invalidAudioPath(audioURL) }
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
}

private final class PersistentHelperWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let helperExecutableURL: URL
    private let runtimeBinDirectory: URL?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?

    init(helperExecutableURL: URL, runtimeBinDirectory: URL?) {
        self.helperExecutableURL = helperExecutableURL
        self.runtimeBinDirectory = runtimeBinDirectory
    }

    func run(request: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { [self] in
            try lock.withLock {
                do {
                    return try send(request)
                } catch {
                    stopLocked()
                    return try send(request)
                }
            }
        }.value
    }

    func stop() {
        lock.withLock { stopLocked() }
    }

    private func send(_ request: Data) throws -> Data {
        try startIfNeeded()
        guard let process, process.isRunning,
              let input, let output
        else {
            throw TranscriptionFailure.helperLaunch("The local transcription helper did not start.")
        }
        input.fileHandleForWriting.write(request)
        let response = output.fileHandleForReading.availableData
        guard !response.isEmpty else {
            throw TranscriptionFailure.unexpectedEOF(stderr: "")
        }
        guard response.last == 0x0A else {
            throw TranscriptionFailure.protocolViolation(
                message: "Response must be newline-terminated",
                stderr: ""
            )
        }
        let line = response.dropLast()
        guard !line.isEmpty, !line.contains(0x0A) else {
            throw TranscriptionFailure.protocolViolation(
                message: "Expected exactly one response record",
                stderr: ""
            )
        }
        return Data(line)
    }

    private func startIfNeeded() throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: helperExecutableURL.path) else {
            throw TranscriptionFailure.helperLaunch(
                "Helper executable is missing or not executable: \(helperExecutableURL.path)"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw TranscriptionFailure.isolationUnavailable("/usr/bin/sandbox-exec")
        }

        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-p", SandboxExecNetworkIsolation.denyNetworkProfile,
            helperExecutableURL.path,
        ]
        process.currentDirectoryURL = helperExecutableURL.deletingLastPathComponent()
        process.environment = environment()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.input = input
        self.output = output
        self.process = process
    }

    private func stopLocked() {
        input?.fileHandleForWriting.closeFile()
        output?.fileHandleForReading.closeFile()
        if let process, process.isRunning {
            process.terminate()
        }
        input = nil
        output = nil
        process = nil
    }

    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let runtimeBinDirectory {
            let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = runtimeBinDirectory.path + ":" + existingPath
        }
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["NO_PROXY"] = "*"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        return environment
    }
}
