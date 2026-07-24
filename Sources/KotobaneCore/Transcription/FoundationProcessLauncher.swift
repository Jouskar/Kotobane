import Foundation

public struct HelperProcessLimits: Sendable {
    public let maximumAudioPathBytes: Int
    public let maximumLanguageBytes: Int
    public let maximumModelBytes: Int
    public let maximumRequestBytes: Int
    public let maximumStdoutBytes: Int
    public let maximumStderrBytes: Int
    public let terminationGrace: Duration
    public let postExitPipeDrainGrace: Duration

    public init(
        maximumAudioPathBytes: Int = 4 * 1024,
        maximumLanguageBytes: Int = 256,
        maximumModelBytes: Int = 256,
        maximumRequestBytes: Int = 64 * 1024,
        maximumStdoutBytes: Int = 1024 * 1024,
        maximumStderrBytes: Int = 64 * 1024,
        terminationGrace: Duration = .milliseconds(200),
        postExitPipeDrainGrace: Duration = .milliseconds(50)
    ) {
        self.maximumAudioPathBytes = maximumAudioPathBytes
        self.maximumLanguageBytes = maximumLanguageBytes
        self.maximumModelBytes = maximumModelBytes
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
        self.terminationGrace = terminationGrace
        self.postExitPipeDrainGrace = postExitPipeDrainGrace
    }
}

public struct HelperProcessInvocation: Sendable {
    public let executableURL: URL
    public let request: Data
    public let environment: [String: String]
    public let timeout: Duration
    public let limits: HelperProcessLimits

    public init(
        executableURL: URL,
        request: Data,
        environment: [String: String],
        timeout: Duration,
        limits: HelperProcessLimits = .init()
    ) {
        self.executableURL = executableURL
        self.request = request
        self.environment = environment
        self.timeout = timeout
        self.limits = limits
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

public struct HelperProcessCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}

public protocol HelperProcessIsolating: Sendable {
    func command(for helperExecutableURL: URL) throws -> HelperProcessCommand
}

public struct SandboxExecNetworkIsolation: HelperProcessIsolating {
    public static let denyNetworkProfile =
        "(version 1)\n(allow default)\n(deny network*)\n"

    private let sandboxExecutableURL: URL

    public init(
        sandboxExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    ) {
        self.sandboxExecutableURL = sandboxExecutableURL
    }

    public func command(for helperExecutableURL: URL) throws -> HelperProcessCommand {
        guard FileManager.default.isExecutableFile(atPath: sandboxExecutableURL.path) else {
            throw TranscriptionFailure.isolationUnavailable(sandboxExecutableURL.path)
        }
        return HelperProcessCommand(
            executableURL: sandboxExecutableURL,
            arguments: [
                "-p",
                Self.denyNetworkProfile,
                helperExecutableURL.path,
            ]
        )
    }
}

public struct FoundationProcessLauncher: ProcessLaunching {
    private let isolation: any HelperProcessIsolating

    public init(
        isolation: any HelperProcessIsolating = SandboxExecNetworkIsolation()
    ) {
        self.isolation = isolation
    }

    public func run(_ invocation: HelperProcessInvocation) async throws -> HelperProcessOutput {
        try Task.checkCancellation()
        guard invocation.request.count <= invocation.limits.maximumRequestBytes else {
            throw TranscriptionFailure.invalidRequest(
                "request exceeds \(invocation.limits.maximumRequestBytes) UTF-8 bytes"
            )
        }

        let command: HelperProcessCommand
        do {
            command = try isolation.command(for: invocation.executableURL)
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch {
            throw TranscriptionFailure.isolationUnavailable(error.localizedDescription)
        }

        let execution = ProcessExecution(invocation: invocation, command: command)
        return try await execution.execute()
    }
}
