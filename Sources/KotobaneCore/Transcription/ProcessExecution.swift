import Darwin
import Foundation

final class ProcessExecution: @unchecked Sendable {
    private enum TerminationCause {
        case cancellation
        case timeout
        case protocolViolation(String)
        case writeFailure
        case isolationFailure
        case lifecycleFailure(String)
    }

    private let invocation: HelperProcessInvocation
    private let command: HelperProcessCommand
    private let observer: any ProcessLifecycleObserving
    private let generation = UUID()
    private let lock = NSLock()
    private let reapSemaphore = DispatchSemaphore(value: 0)

    private var continuation: CheckedContinuation<HelperProcessOutput, Error>?
    private var process: POSIXProcessHandle?
    private var processStarted = false
    private var directProcessExited = false
    private var directProcessReaped = false
    private var exitCode: Int32 = 0
    private var stdinWorkerExited = false
    private var stdoutWorkerExited = false
    private var stderrWorkerExited = false
    private var isolationWorkerExited: Bool
    private var stdoutData = Data()
    private var stderrData = Data()
    private var terminationCause: TerminationCause?
    private var cancellationRequested = false
    private var stopInput = false
    private var stopOutputs = false
    private var stopIsolation = false
    private var generationIsValid = true
    private var didFinish = false
    private var reapWasAllowed = false
    private var sigtermWasSent = false
    private var escalationWasReserved = false
    private var escalationDidFire = false
    private var postExitCleanupWasReserved = false
    private var timeoutTask: Task<Void, Never>?
    private var escalationTask: Task<Void, Never>?
    private var postExitCleanupTask: Task<Void, Never>?

    init(
        invocation: HelperProcessInvocation,
        command: HelperProcessCommand,
        observer: any ProcessLifecycleObserving
    ) {
        self.invocation = invocation
        self.command = command
        self.observer = observer
        isolationWorkerExited = command.isolationHandshakeDescriptor == nil
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
            finishBeforeSpawn(with: CancellationError())
            return
        }

        var pipes: ProcessPipeSet
        do {
            pipes = try ProcessPipeSet(
                needsIsolationHandshake: command.isolationHandshakeDescriptor != nil,
                reservedDescriptor: command.isolationHandshakeDescriptor
            )
        } catch {
            finishBeforeSpawn(
                with: TranscriptionFailure.helperLaunch(error.localizedDescription)
            )
            return
        }

        let process: POSIXProcessHandle
        do {
            process = try POSIXProcessHandle.spawn(
                command: command,
                environment: invocation.environment,
                pipes: pipes
            )
        } catch {
            pipes.closeAll()
            let failure: TranscriptionFailure
            if command.isolationHandshakeDescriptor != nil {
                failure = .isolationUnavailable(
                    "Unable to launch sandbox wrapper: \(error.localizedDescription)"
                )
            } else {
                failure = .helperLaunch(error.localizedDescription)
            }
            finishBeforeSpawn(with: failure)
            return
        }

        pipes.closeChildEndsInParent()
        lock.lock()
        self.process = process
        processStarted = true
        let mustCancel = cancellationRequested
        lock.unlock()

        startWorkers(pipes: pipes, process: process)
        startTimeout()
        if mustCancel {
            requestTermination(.cancellation, generation: generation)
        }
    }

    private func startWorkers(
        pipes: ProcessPipeSet,
        process: POSIXProcessHandle
    ) {
        let currentGeneration = generation
        Thread.detachNewThread {
            ProcessIOWorkers.writeRequest(
                self.invocation.request,
                to: pipes.stdin.writeEnd,
                state: {
                    self.inputWorkerState(generation: currentGeneration)
                },
                didExit: { failed, incomplete in
                    self.inputWorkerDidExit(
                        failed: failed,
                        incomplete: incomplete,
                        generation: currentGeneration
                    )
                }
            )
        }
        Thread.detachNewThread {
            ProcessIOWorkers.readOutput(
                from: pipes.stdout.readEnd,
                shouldContinue: {
                    self.outputWorkerShouldContinue(
                        generation: currentGeneration
                    )
                },
                consume: { data in
                    self.append(
                        data,
                        to: .stdout,
                        generation: currentGeneration
                    )
                },
                didExit: {
                    self.outputWorkerDidExit(
                        .stdout,
                        generation: currentGeneration
                    )
                }
            )
        }
        Thread.detachNewThread {
            ProcessIOWorkers.readOutput(
                from: pipes.stderr.readEnd,
                shouldContinue: {
                    self.outputWorkerShouldContinue(
                        generation: currentGeneration
                    )
                },
                consume: { data in
                    self.append(
                        data,
                        to: .stderr,
                        generation: currentGeneration
                    )
                },
                didExit: {
                    self.outputWorkerDidExit(
                        .stderr,
                        generation: currentGeneration
                    )
                }
            )
        }
        if let handshake = pipes.isolationHandshake {
            Thread.detachNewThread {
                ProcessIOWorkers.readIsolationHandshake(
                    from: handshake.readEnd,
                    shouldContinue: {
                        self.isolationWorkerShouldContinue(
                            generation: currentGeneration
                        )
                    },
                    didExit: { _, failed in
                        self.isolationWorkerDidExit(
                            failed: failed,
                            generation: currentGeneration
                        )
                    }
                )
            }
        }
        Thread.detachNewThread {
            self.waitForDirectProcess(process, generation: currentGeneration)
        }
    }

    private func startTimeout() {
        let currentGeneration = generation
        let timer = Task.detached {
            do {
                try await ContinuousClock().sleep(for: self.invocation.timeout)
            } catch {
                return
            }
            self.timeoutExpired(generation: currentGeneration)
        }
        lock.lock()
        if generationIsValid, !didFinish, !directProcessExited {
            timeoutTask = timer
        } else {
            timer.cancel()
        }
        lock.unlock()
    }

    private func waitForDirectProcess(
        _ process: POSIXProcessHandle,
        generation: UUID
    ) {
        do {
            try process.waitUntilExitIsObservable()
            directProcessDidExit(generation: generation)
            reapSemaphore.wait()
            let status = try process.reap()
            directProcessDidReap(
                status: status,
                generation: generation
            )
        } catch {
            requestTermination(
                .lifecycleFailure(error.localizedDescription),
                generation: generation
            )
            directProcessDidReapAfterWaitFailure(
                status: (try? process.reap()) ?? 0,
                generation: generation
            )
        }
    }

    private func inputWorkerState(generation: UUID) -> (
        stop: Bool,
        directProcessExited: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard generationIsValid, self.generation == generation else {
            return (true, false)
        }
        return (stopInput, directProcessExited)
    }

    private func outputWorkerShouldContinue(generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generationIsValid
            && self.generation == generation
            && !stopOutputs
    }

    private func isolationWorkerShouldContinue(generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generationIsValid
            && self.generation == generation
            && !stopIsolation
    }

    private func append(
        _ data: Data,
        to stream: ProcessOutputStream,
        generation: UUID
    ) -> Bool {
        var violation: String?
        lock.lock()
        guard generationIsValid, self.generation == generation else {
            lock.unlock()
            return false
        }
        switch stream {
        case .stdout:
            let maximum = invocation.limits.maximumStdoutBytes
            let remaining = max(0, maximum - stdoutData.count)
            stdoutData.append(data.prefix(remaining))
            if data.count > remaining {
                violation = "stdout exceeded \(maximum) bytes"
            }
        case .stderr:
            let maximum = invocation.limits.maximumStderrBytes
            let remaining = max(0, maximum - stderrData.count)
            stderrData.append(data.prefix(remaining))
            if data.count > remaining {
                violation = "stderr exceeded \(maximum) bytes"
            }
        }
        lock.unlock()
        if let violation {
            requestTermination(
                .protocolViolation(violation),
                generation: generation
            )
            return false
        }
        return true
    }

    private func inputWorkerDidExit(
        failed: Bool,
        incomplete: Bool,
        generation: UUID
    ) {
        lock.lock()
        guard generationIsValid, self.generation == generation else {
            lock.unlock()
            return
        }
        stdinWorkerExited = true
        lock.unlock()
        observer.processLifecycleDidEmit(.stdinWorkerExited)
        if failed || (incomplete && !terminationIsAlreadyRequested) {
            requestTermination(.writeFailure, generation: generation)
        }
        workerStateDidChange()
    }

    private func outputWorkerDidExit(
        _ stream: ProcessOutputStream,
        generation: UUID
    ) {
        lock.lock()
        guard generationIsValid, self.generation == generation else {
            lock.unlock()
            return
        }
        switch stream {
        case .stdout:
            stdoutWorkerExited = true
        case .stderr:
            stderrWorkerExited = true
        }
        lock.unlock()
        observer.processLifecycleDidEmit(
            stream == .stdout ? .stdoutWorkerExited : .stderrWorkerExited
        )
        workerStateDidChange()
    }

    private func isolationWorkerDidExit(
        failed: Bool,
        generation: UUID
    ) {
        lock.lock()
        guard generationIsValid, self.generation == generation else {
            lock.unlock()
            return
        }
        isolationWorkerExited = true
        let alreadyTerminating = terminationCause != nil
        lock.unlock()
        observer.processLifecycleDidEmit(.isolationWorkerExited)
        if failed, !alreadyTerminating {
            requestTermination(.isolationFailure, generation: generation)
        }
        workerStateDidChange()
    }

    private var terminationIsAlreadyRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationCause != nil
    }

    private func directProcessDidExit(generation: UUID) {
        var timer: Task<Void, Never>?
        var schedulePostExitCleanup = false
        lock.lock()
        guard generationIsValid, self.generation == generation else {
            lock.unlock()
            return
        }
        directProcessExited = true
        timer = timeoutTask
        timeoutTask = nil
        if !stopOutputs,
            (!stdoutWorkerExited || !stderrWorkerExited),
            !postExitCleanupWasReserved
        {
            postExitCleanupWasReserved = true
            schedulePostExitCleanup = true
        }
        lock.unlock()
        timer?.cancel()
        observer.processLifecycleDidEmit(.directProcessExited)
        if schedulePostExitCleanup {
            schedulePostExitCleanupTask(generation: generation)
        }
        workerStateDidChange()
    }

    private func directProcessDidReap(status: Int32, generation: UUID) {
        lock.lock()
        guard generationIsValid, self.generation == generation else {
            lock.unlock()
            return
        }
        directProcessReaped = true
        exitCode = Self.exitCode(fromWaitStatus: status)
        lock.unlock()
        maybeFinish()
    }

    private func directProcessDidReapAfterWaitFailure(
        status: Int32,
        generation: UUID
    ) {
        lock.lock()
        guard generationIsValid, self.generation == generation else {
            lock.unlock()
            return
        }
        directProcessExited = true
        directProcessReaped = true
        exitCode = Self.exitCode(fromWaitStatus: status)
        stopInput = true
        stopOutputs = true
        stopIsolation = true
        lock.unlock()
        observer.processLifecycleDidEmit(.directProcessExited)
        maybeFinish()
    }

    private func workerStateDidChange() {
        var allowReap = false
        lock.lock()
        if generationIsValid,
            directProcessExited,
            stdinWorkerExited,
            stdoutWorkerExited,
            stderrWorkerExited,
            isolationWorkerExited,
            (!escalationWasReserved || escalationDidFire),
            !reapWasAllowed
        {
            reapWasAllowed = true
            allowReap = true
        }
        lock.unlock()
        if allowReap {
            reapSemaphore.signal()
        }
        maybeFinish()
    }

    private func timeoutExpired(generation: UUID) {
        requestTermination(.timeout, generation: generation)
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let started = processStarted
        let currentGeneration = generation
        lock.unlock()
        if started {
            requestTermination(.cancellation, generation: currentGeneration)
        }
    }

    private func requestTermination(_ cause: TerminationCause, generation: UUID) {
        var sendSIGTERM = false
        var scheduleEscalation = false
        var timer: Task<Void, Never>?
        lock.lock()
        guard generationIsValid, self.generation == generation, !didFinish else {
            lock.unlock()
            return
        }
        if case .cancellation = cause {
            terminationCause = .cancellation
        } else if terminationCause == nil {
            terminationCause = cause
        }
        stopInput = true
        switch cause {
        case .cancellation, .timeout, .protocolViolation:
            stopOutputs = true
            stopIsolation = true
        case .isolationFailure:
            stopIsolation = true
        case .writeFailure, .lifecycleFailure:
            break
        }
        timer = timeoutTask
        timeoutTask = nil
        if !sigtermWasSent, process != nil {
            sigtermWasSent = true
            sendSIGTERM = true
        }
        if !escalationWasReserved, process != nil {
            escalationWasReserved = true
            scheduleEscalation = true
        }
        lock.unlock()

        timer?.cancel()
        if sendSIGTERM {
            signalProcessGroup(SIGTERM, generation: generation)
        }
        if scheduleEscalation {
            scheduleEscalationTask(generation: generation)
        }
    }

    private func scheduleEscalationTask(generation: UUID) {
        let task = Task.detached {
            do {
                try await ContinuousClock().sleep(
                    for: self.invocation.limits.terminationGrace
                )
            } catch {
                return
            }
            self.forceKill(generation: generation)
        }
        lock.lock()
        if generationIsValid,
            self.generation == generation,
            escalationWasReserved,
            escalationTask == nil
        {
            escalationTask = task
        } else {
            task.cancel()
        }
        lock.unlock()
    }

    private func forceKill(generation: UUID) {
        var didAttempt = false
        lock.lock()
        guard generationIsValid,
            self.generation == generation,
            escalationWasReserved,
            !escalationDidFire,
            !didFinish,
            let process
        else {
            lock.unlock()
            return
        }
        escalationDidFire = true
        process.signalGroup(SIGKILL)
        didAttempt = true
        lock.unlock()
        if didAttempt {
            observer.processLifecycleDidEmit(
                .signal(generation: generation, signal: SIGKILL)
            )
        }
        workerStateDidChange()
    }

    private func schedulePostExitCleanupTask(generation: UUID) {
        let task = Task.detached {
            do {
                try await ContinuousClock().sleep(
                    for: self.invocation.limits.postExitPipeDrainGrace
                )
            } catch {
                return
            }
            self.cleanUpExitedProcessGroup(generation: generation)
        }
        lock.lock()
        if generationIsValid,
            self.generation == generation,
            postExitCleanupWasReserved,
            postExitCleanupTask == nil
        {
            postExitCleanupTask = task
        } else {
            task.cancel()
        }
        lock.unlock()
    }

    private func cleanUpExitedProcessGroup(generation: UUID) {
        var didAttempt = false
        lock.lock()
        if generationIsValid,
            self.generation == generation,
            !didFinish,
            (!stdoutWorkerExited || !stderrWorkerExited),
            let process
        {
            process.signalGroup(SIGKILL)
            didAttempt = true
        }
        lock.unlock()
        if didAttempt {
            observer.processLifecycleDidEmit(
                .signal(generation: generation, signal: SIGKILL)
            )
        }
    }

    private func signalProcessGroup(_ signal: Int32, generation: UUID) {
        var didAttempt = false
        lock.lock()
        if generationIsValid,
            self.generation == generation,
            !didFinish,
            let process
        {
            process.signalGroup(signal)
            didAttempt = true
        }
        lock.unlock()
        if didAttempt {
            observer.processLifecycleDidEmit(
                .signal(generation: generation, signal: signal)
            )
        }
    }

    private func maybeFinish() {
        var result: Result<HelperProcessOutput, Error>?
        var continuation: CheckedContinuation<HelperProcessOutput, Error>?
        var timer: Task<Void, Never>?
        var escalation: Task<Void, Never>?
        var postExitCleanup: Task<Void, Never>?
        lock.lock()
        if generationIsValid,
            !didFinish,
            directProcessReaped,
            stdinWorkerExited,
            stdoutWorkerExited,
            stderrWorkerExited,
            isolationWorkerExited
        {
            didFinish = true
            generationIsValid = false
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
            case .isolationFailure:
                result = .failure(
                    TranscriptionFailure.isolationUnavailable(
                        stderrText.isEmpty
                            ? "Network sandbox failed before helper launch"
                            : stderrText
                    )
                )
            case .lifecycleFailure(let message):
                result = .failure(TranscriptionFailure.helperLaunch(message))
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
            timer = timeoutTask
            timeoutTask = nil
            escalation = escalationTask
            escalationTask = nil
            postExitCleanup = postExitCleanupTask
            postExitCleanupTask = nil
        }
        lock.unlock()

        guard let result, let continuation else {
            return
        }
        timer?.cancel()
        escalation?.cancel()
        postExitCleanup?.cancel()
        observer.processLifecycleDidEmit(.willResume)
        continuation.resume(with: result)
    }

    private func finishBeforeSpawn(with error: Error) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        generationIsValid = false
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        observer.processLifecycleDidEmit(.willResume)
        continuation?.resume(throwing: error)
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + terminationSignal
    }
}
