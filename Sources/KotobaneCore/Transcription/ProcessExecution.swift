import Darwin
import Foundation

final class ProcessExecution: @unchecked Sendable {
    private enum TerminationCause {
        case cancellation
        case timeout
        case protocolViolation(String)
        case writeFailure
    }

    private enum Stream {
        case stdout
        case stderr
    }

    private let invocation: HelperProcessInvocation
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()

    private var continuation: CheckedContinuation<HelperProcessOutput, Error>?
    private var processStarted = false
    private var processExited = false
    private var processID: pid_t?
    private var ownedProcessGroupID: pid_t?
    private var exitCode: Int32 = 0
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutFinished = false
    private var stderrFinished = false
    private var writerFinished = false
    private var terminationCause: TerminationCause?
    private var cancellationRequested = false
    private var didFinish = false
    private var stdinClosed = false
    private var stdoutClosed = false
    private var stderrClosed = false
    private var timeoutTask: Task<Void, Never>?
    private var escalationTask: Task<Void, Never>?
    private var pipeDrainTask: Task<Void, Never>?

    init(invocation: HelperProcessInvocation, command: HelperProcessCommand) {
        self.invocation = invocation
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = invocation.environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func execute() async throws -> HelperProcessOutput {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func start(_ continuation: CheckedContinuation<HelperProcessOutput, Error>) {
        lock.lock()
        self.continuation = continuation
        let wasCancelled = cancellationRequested
        lock.unlock()
        guard !wasCancelled else {
            finishBeforeLaunch(with: CancellationError())
            return
        }

        do {
            try configureNonblockingIO()
            process.terminationHandler = { [weak self] process in
                process.waitUntilExit()
                self?.didExit(status: process.terminationStatus)
            }
            try process.run()
        } catch {
            closeAllHandles()
            finishBeforeLaunch(
                with: TranscriptionFailure.helperLaunch(error.localizedDescription)
            )
            return
        }

        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let pid = process.processIdentifier
        let ownsGroup = setpgid(pid, pid) == 0
        lock.lock()
        processStarted = true
        processID = pid
        if ownsGroup {
            ownedProcessGroupID = pid
        }
        let mustCancel = cancellationRequested
        lock.unlock()

        startWorkers()
        if mustCancel {
            beginTermination(.cancellation)
        }
    }

    private func configureNonblockingIO() throws {
        for descriptor in [
            stdin.fileHandleForReading.fileDescriptor,
            stdin.fileHandleForWriting.fileDescriptor,
            stdout.fileHandleForReading.fileDescriptor,
            stdout.fileHandleForWriting.fileDescriptor,
            stderr.fileHandleForReading.fileDescriptor,
            stderr.fileHandleForWriting.fileDescriptor,
        ] {
            try setCloseOnExec(descriptor)
        }
        try setNonblocking(stdin.fileHandleForWriting.fileDescriptor)
        try setNonblocking(stdout.fileHandleForReading.fileDescriptor)
        try setNonblocking(stderr.fileHandleForReading.fileDescriptor)
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXIOError(operation: "fcntl(F_SETNOSIGPIPE)", code: errno)
        }
    }

    private func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags != -1,
            fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != -1
        else {
            throw POSIXIOError(operation: "fcntl(FD_CLOEXEC)", code: errno)
        }
    }

    private func setNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1,
            fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1
        else {
            throw POSIXIOError(operation: "fcntl(O_NONBLOCK)", code: errno)
        }
    }

    private func startWorkers() {
        let stdinDescriptor = stdin.fileHandleForWriting.fileDescriptor
        let stdoutDescriptor = stdout.fileHandleForReading.fileDescriptor
        let stderrDescriptor = stderr.fileHandleForReading.fileDescriptor

        Thread.detachNewThread {
            self.writeRequest(to: stdinDescriptor)
        }
        Thread.detachNewThread {
            self.readStream(.stdout, from: stdoutDescriptor)
        }
        Thread.detachNewThread {
            self.readStream(.stderr, from: stderrDescriptor)
        }
        let timer = Task.detached {
            do {
                try await ContinuousClock().sleep(for: self.invocation.timeout)
            } catch {
                return
            }
            self.timeoutExpired()
        }
        lock.lock()
        if didFinish || terminationCause != nil || processExited {
            timer.cancel()
        } else {
            timeoutTask = timer
        }
        lock.unlock()
    }

    private func writeRequest(to descriptor: Int32) {
        var offset = 0
        let request = invocation.request
        while offset < request.count {
            guard shouldContinueWriting else {
                writerDidFinish(
                    error: processHasExited
                        ? POSIXIOError(operation: "write", code: EPIPE)
                        : nil
                )
                return
            }
            let written = request.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else {
                    return 0
                }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    request.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == -1, errno == EINTR {
                continue
            }
            if written == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(2_000)
                continue
            }
            let code = written == -1 ? errno : EPIPE
            writerDidFinish(error: POSIXIOError(operation: "write", code: code))
            return
        }
        closeStdin()
        writerDidFinish(error: nil)
    }

    private func readStream(_ stream: Stream, from descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while shouldContinueReading(stream) {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let keepReading = consume(
                    Data(buffer.prefix(count)),
                    from: stream
                )
                if !keepReading {
                    return
                }
                continue
            }
            if count == 0 {
                readerDidFinish(stream)
                return
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(2_000)
                continue
            }
            readerDidFinish(stream)
            return
        }
    }

    private func consume(_ data: Data, from stream: Stream) -> Bool {
        detectOwnedProcessGroup()
        var violation: String?
        var closeStream = false
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return false
        }
        switch stream {
        case .stdout:
            let maximum = invocation.limits.maximumStdoutBytes
            let remaining = max(0, maximum - stdoutData.count)
            stdoutData.append(data.prefix(remaining))
            if data.count > remaining {
                stdoutFinished = true
                violation = "stdout exceeded \(maximum) bytes"
                closeStream = true
            } else if let newline = stdoutData.firstIndex(of: 0x0A) {
                if newline != stdoutData.index(before: stdoutData.endIndex) {
                    violation = "Expected exactly one response line"
                }
                stdoutFinished = true
                closeStream = true
            }
        case .stderr:
            let maximum = invocation.limits.maximumStderrBytes
            let remaining = max(0, maximum - stderrData.count)
            stderrData.append(data.prefix(remaining))
            if data.count > remaining {
                stderrFinished = true
                violation = "stderr exceeded \(maximum) bytes"
                closeStream = true
            }
        }
        lock.unlock()

        if closeStream {
            close(stream)
        }
        if let violation {
            beginTermination(.protocolViolation(violation))
            return false
        }
        if closeStream {
            maybeFinish()
            return false
        }
        return true
    }

    private var shouldContinueWriting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !didFinish && terminationCause == nil && !processExited
    }

    private var processHasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return processExited
    }

    private func shouldContinueReading(_ stream: Stream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else {
            return false
        }
        switch stream {
        case .stdout:
            return !stdoutFinished
        case .stderr:
            return !stderrFinished
        }
    }

    private func writerDidFinish(error: Error?) {
        var shouldTerminate = false
        lock.lock()
        guard !writerFinished else {
            lock.unlock()
            return
        }
        writerFinished = true
        if error != nil, terminationCause == nil {
            shouldTerminate = true
        }
        lock.unlock()
        closeStdin()
        if shouldTerminate {
            beginTermination(.writeFailure)
        } else {
            maybeFinish()
        }
    }

    private func readerDidFinish(_ stream: Stream) {
        lock.lock()
        switch stream {
        case .stdout:
            stdoutFinished = true
        case .stderr:
            stderrFinished = true
        }
        lock.unlock()
        close(stream)
        maybeFinish()
    }

    private func didExit(status: Int32) {
        lock.lock()
        guard !processExited else {
            lock.unlock()
            return
        }
        processExited = true
        exitCode = status
        let timer = timeoutTask
        timeoutTask = nil
        lock.unlock()
        timer?.cancel()
        closeStdin()

        let drain = Task.detached {
            do {
                try await ContinuousClock().sleep(
                    for: self.invocation.limits.postExitPipeDrainGrace
                )
            } catch {
                return
            }
            self.endPostExitDrain()
        }
        lock.lock()
        if didFinish {
            drain.cancel()
        } else {
            pipeDrainTask = drain
        }
        lock.unlock()
        maybeFinish()
    }

    private func endPostExitDrain() {
        var killOwnedGroup = false
        lock.lock()
        killOwnedGroup =
            ownedProcessGroupID != nil && (!stdoutFinished || !stderrFinished)
        stdoutFinished = true
        stderrFinished = true
        pipeDrainTask = nil
        lock.unlock()
        if killOwnedGroup {
            signalOwnedProcess(SIGKILL, includeExitedGroup: true)
        }
        closeStdout()
        closeStderr()
        maybeFinish()
    }

    private func timeoutExpired() {
        beginTermination(.timeout)
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let started = processStarted
        lock.unlock()
        if started {
            beginTermination(.cancellation)
        }
    }

    private func beginTermination(_ cause: TerminationCause) {
        var shouldSignal = false
        var shouldScheduleEscalation = false
        var timer: Task<Void, Never>?
        lock.lock()
        if case .cancellation = cause {
            terminationCause = .cancellation
        } else if terminationCause == nil {
            terminationCause = cause
        }
        if !didFinish {
            timer = timeoutTask
            timeoutTask = nil
            shouldSignal = !processExited
            shouldScheduleEscalation = escalationTask == nil
            stdoutFinished = true
            stderrFinished = true
        }
        lock.unlock()

        timer?.cancel()
        closeStdin()
        closeStdout()
        closeStderr()
        if shouldSignal {
            signalOwnedProcess(SIGTERM, includeExitedGroup: false)
        }
        if shouldScheduleEscalation {
            let escalation = Task.detached {
                do {
                    try await ContinuousClock().sleep(
                        for: self.invocation.limits.terminationGrace
                    )
                } catch {
                    return
                }
                self.forceKill()
            }
            lock.lock()
            if didFinish {
                escalation.cancel()
            } else {
                escalationTask = escalation
            }
            lock.unlock()
        }
        maybeFinish()
    }

    private func forceKill() {
        signalOwnedProcess(SIGKILL, includeExitedGroup: true)
        lock.lock()
        escalationTask = nil
        lock.unlock()
        maybeFinish()
    }

    private func signalOwnedProcess(_ signal: Int32, includeExitedGroup: Bool) {
        detectOwnedProcessGroup()
        lock.lock()
        let pid = processID
        let groupID = ownedProcessGroupID
        let exited = processExited
        lock.unlock()
        if let groupID, includeExitedGroup || !exited {
            _ = Darwin.kill(-groupID, signal)
        } else if let pid, !exited {
            _ = Darwin.kill(pid, signal)
        }
    }

    private func detectOwnedProcessGroup() {
        lock.lock()
        guard ownedProcessGroupID == nil, let pid = processID, !processExited else {
            lock.unlock()
            return
        }
        lock.unlock()
        guard getpgid(pid) == pid else {
            return
        }
        lock.lock()
        if !processExited {
            ownedProcessGroupID = pid
        }
        lock.unlock()
    }

    private func maybeFinish() {
        var result: Result<HelperProcessOutput, Error>?
        var continuation: CheckedContinuation<HelperProcessOutput, Error>?
        var timeout: Task<Void, Never>?
        var escalation: Task<Void, Never>?
        var drain: Task<Void, Never>?
        lock.lock()
        if !didFinish,
            processExited,
            writerFinished,
            stdoutFinished,
            stderrFinished
        {
            didFinish = true
            let stderrText = String(decoding: stderrData, as: UTF8.self)
            switch terminationCause {
            case .cancellation:
                result = .failure(CancellationError())
            case .timeout:
                result = .failure(TranscriptionFailure.timedOut)
            case .protocolViolation(let message):
                result = .failure(
                    TranscriptionFailure.protocolViolation(
                        message: message,
                        stderr: stderrText
                    )
                )
            case .writeFailure:
                result = .failure(
                    TranscriptionFailure.helperCrashed(
                        exitCode: exitCode,
                        stderr: stderrText
                    )
                )
            case nil:
                result = .success(
                    HelperProcessOutput(
                        stdout: stdoutData,
                        stderr: stderrData,
                        exitCode: exitCode
                    )
                )
            }
            continuation = self.continuation
            self.continuation = nil
            timeout = timeoutTask
            timeoutTask = nil
            escalation = escalationTask
            escalationTask = nil
            drain = pipeDrainTask
            pipeDrainTask = nil
        }
        lock.unlock()

        guard let result, let continuation else {
            return
        }
        timeout?.cancel()
        escalation?.cancel()
        drain?.cancel()
        closeAllHandles()
        continuation.resume(with: result)
    }

    private func finishBeforeLaunch(with error: Error) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func close(_ stream: Stream) {
        switch stream {
        case .stdout:
            closeStdout()
        case .stderr:
            closeStderr()
        }
    }

    private func closeStdin() {
        lock.lock()
        guard !stdinClosed else {
            lock.unlock()
            return
        }
        stdinClosed = true
        lock.unlock()
        try? stdin.fileHandleForWriting.close()
    }

    private func closeStdout() {
        lock.lock()
        guard !stdoutClosed else {
            lock.unlock()
            return
        }
        stdoutClosed = true
        lock.unlock()
        try? stdout.fileHandleForReading.close()
    }

    private func closeStderr() {
        lock.lock()
        guard !stderrClosed else {
            lock.unlock()
            return
        }
        stderrClosed = true
        lock.unlock()
        try? stderr.fileHandleForReading.close()
    }

    private func closeAllHandles() {
        closeStdin()
        closeStdout()
        closeStderr()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }
}

private struct POSIXIOError: Error {
    let operation: String
    let code: Int32
}
