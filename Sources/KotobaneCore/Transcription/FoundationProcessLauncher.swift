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
    public let isolationHandshakeDescriptor: Int32?
    public let execStatusDescriptor: Int32?

    public init(
        executableURL: URL,
        arguments: [String],
        isolationHandshakeDescriptor: Int32? = nil,
        execStatusDescriptor: Int32? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.isolationHandshakeDescriptor = isolationHandshakeDescriptor
        self.execStatusDescriptor = execStatusDescriptor
    }
}

public protocol HelperProcessIsolating: Sendable {
    func command(for helperExecutableURL: URL) throws -> HelperProcessCommand
}

public struct SandboxExecNetworkIsolation: HelperProcessIsolating {
    public static let denyNetworkProfile =
        "(version 1)\n(allow default)\n(deny network*)\n"
    public static let handshakeDescriptor: Int32 = 63
    public static let execStatusDescriptor: Int32 = 64

    private let sandboxExecutableURL: URL
    private let launchShimExecutableURL: URL

    public init(
        sandboxExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
        launchShimExecutableURL: URL = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/kotobane-launch-shim")
    ) {
        self.sandboxExecutableURL = sandboxExecutableURL
        self.launchShimExecutableURL = launchShimExecutableURL
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
                launchShimExecutableURL.path,
                String(Self.handshakeDescriptor),
                String(Self.execStatusDescriptor),
                helperExecutableURL.path,
            ],
            isolationHandshakeDescriptor: Self.handshakeDescriptor,
            execStatusDescriptor: Self.execStatusDescriptor
        )
    }
}

enum ProcessLifecycleEvent: Equatable, Sendable {
    case directProcessExited
    case stdinWorkerExited
    case stdoutWorkerExited
    case stderrWorkerExited
    case isolationWorkerExited
    case execStatusWorkerExited
    case signal(generation: UUID, signal: Int32)
    case willResume
}

protocol ProcessLifecycleObserving: Sendable {
    func processLifecycleDidEmit(_ event: ProcessLifecycleEvent)
}

private struct NullProcessLifecycleObserver: ProcessLifecycleObserving {
    func processLifecycleDidEmit(_ event: ProcessLifecycleEvent) {}
}

public struct FoundationProcessLauncher: ProcessLaunching {
    private let isolation: any HelperProcessIsolating
    private let lifecycleObserver: any ProcessLifecycleObserving
    private let preSpawnHook: (@Sendable () -> Void)?

    public init(
        isolation: any HelperProcessIsolating = SandboxExecNetworkIsolation()
    ) {
        self.isolation = isolation
        lifecycleObserver = NullProcessLifecycleObserver()
        preSpawnHook = nil
    }

    init(
        isolation: any HelperProcessIsolating,
        lifecycleObserver: any ProcessLifecycleObserving,
        preSpawnHook: (@Sendable () -> Void)? = nil
    ) {
        self.isolation = isolation
        self.lifecycleObserver = lifecycleObserver
        self.preSpawnHook = preSpawnHook
    }

    public func run(_ invocation: HelperProcessInvocation) async throws -> HelperProcessOutput {
        try Task.checkCancellation()
        guard invocation.request.count <= invocation.limits.maximumRequestBytes else {
            throw TranscriptionFailure.invalidRequest(
                "request exceeds \(invocation.limits.maximumRequestBytes) UTF-8 bytes"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: invocation.executableURL.path) else {
            throw TranscriptionFailure.helperLaunch(
                "Helper executable is missing or not executable: \(invocation.executableURL.path)"
            )
        }
        preSpawnHook?()

        let command: HelperProcessCommand
        do {
            command = try isolation.command(for: invocation.executableURL)
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch {
            throw TranscriptionFailure.isolationUnavailable(error.localizedDescription)
        }

        let execution = ProcessExecution(
            invocation: invocation,
            command: command,
            observer: lifecycleObserver
        )
        return try await execution.execute()
    }
}
