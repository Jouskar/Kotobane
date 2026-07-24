import Darwin
import Foundation

struct POSIXProcessHandle: Sendable {
    let processID: pid_t

    static func spawn(
        command: HelperProcessCommand,
        environment: [String: String],
        pipes: ProcessPipeSet
    ) throws -> POSIXProcessHandle {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checkPOSIX(
            posix_spawn_file_actions_init(&actions),
            operation: "posix_spawn_file_actions_init"
        )
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checkPOSIX(
            posix_spawnattr_init(&attributes),
            operation: "posix_spawnattr_init"
        )
        defer { posix_spawnattr_destroy(&attributes) }

        try addFileActions(&actions, command: command, pipes: pipes)
        try configureSpawnAttributes(&attributes)

        let arguments = [command.executableURL.path] + command.arguments
        let environmentEntries = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = try withCStringVector(arguments) { argv in
            try withCStringVector(environmentEntries) { environmentPointer in
                posix_spawn(
                    &pid,
                    command.executableURL.path,
                    &actions,
                    &attributes,
                    argv,
                    environmentPointer
                )
            }
        }
        try checkPOSIX(result, operation: "posix_spawn")
        return POSIXProcessHandle(processID: pid)
    }

    func waitUntilExitIsObservable() throws {
        var information = siginfo_t()
        while waitid(
            P_PID,
            id_t(processID),
            &information,
            WEXITED | WNOWAIT
        ) == -1 {
            if errno == EINTR {
                continue
            }
            throw POSIXIOError(operation: "waitid", code: errno)
        }
    }

    func reap() throws -> Int32 {
        var status: Int32 = 0
        while waitpid(processID, &status, 0) == -1 {
            if errno == EINTR {
                continue
            }
            throw POSIXIOError(operation: "waitpid", code: errno)
        }
        return status
    }

    func signalGroup(_ signal: Int32) {
        _ = Darwin.kill(-processID, signal)
    }

    private static func addFileActions(
        _ actions: inout posix_spawn_file_actions_t?,
        command: HelperProcessCommand,
        pipes: ProcessPipeSet
    ) throws {
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(
                &actions,
                pipes.stdin.readEnd,
                STDIN_FILENO
            ),
            operation: "posix_spawn stdin dup2"
        )
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(
                &actions,
                pipes.stdout.writeEnd,
                STDOUT_FILENO
            ),
            operation: "posix_spawn stdout dup2"
        )
        try checkPOSIX(
            posix_spawn_file_actions_adddup2(
                &actions,
                pipes.stderr.writeEnd,
                STDERR_FILENO
            ),
            operation: "posix_spawn stderr dup2"
        )
        if let descriptor = command.isolationHandshakeDescriptor,
            let handshake = pipes.isolationHandshake
        {
            try checkPOSIX(
                posix_spawn_file_actions_adddup2(
                    &actions,
                    handshake.writeEnd,
                    descriptor
                ),
                operation: "posix_spawn isolation dup2"
            )
        }
        for descriptor in pipes.allDescriptors
        where descriptor != command.isolationHandshakeDescriptor {
            try checkPOSIX(
                posix_spawn_file_actions_addclose(&actions, descriptor),
                operation: "posix_spawn close"
            )
        }
    }

    private static func configureSpawnAttributes(
        _ attributes: inout posix_spawnattr_t?
    ) throws {
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        try checkPOSIX(
            posix_spawnattr_setsigmask(&attributes, &emptySignalMask),
            operation: "posix_spawnattr_setsigmask"
        )
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        try checkPOSIX(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            operation: "posix_spawnattr_setsigdefault"
        )
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
        )
        try checkPOSIX(
            posix_spawnattr_setflags(&attributes, flags),
            operation: "posix_spawnattr_setflags"
        )
        try checkPOSIX(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "posix_spawnattr_setpgroup"
        )
    }
}

struct ProcessPipePair: Sendable {
    var readEnd: Int32
    var writeEnd: Int32
}

struct ProcessPipeSet: Sendable {
    var stdin: ProcessPipePair
    var stdout: ProcessPipePair
    var stderr: ProcessPipePair
    var isolationHandshake: ProcessPipePair?

    init(needsIsolationHandshake: Bool, reservedDescriptor: Int32?) throws {
        var opened: [Int32] = []
        do {
            stdin = try Self.makePipe(opened: &opened)
            stdout = try Self.makePipe(opened: &opened)
            stderr = try Self.makePipe(opened: &opened)
            isolationHandshake = needsIsolationHandshake
                ? try Self.makePipe(opened: &opened)
                : nil
            if let reservedDescriptor {
                try relocateCollision(
                    with: reservedDescriptor,
                    opened: &opened
                )
            }
            for descriptor in allDescriptors {
                try setCloseOnExec(descriptor)
            }
            try setNonblocking(stdin.writeEnd)
            try setNonblocking(stdout.readEnd)
            try setNonblocking(stderr.readEnd)
            if let isolationHandshake {
                try setNonblocking(isolationHandshake.readEnd)
            }
            guard fcntl(stdin.writeEnd, F_SETNOSIGPIPE, 1) != -1 else {
                throw POSIXIOError(
                    operation: "fcntl(F_SETNOSIGPIPE)",
                    code: errno
                )
            }
        } catch {
            for descriptor in opened {
                Darwin.close(descriptor)
            }
            throw error
        }
    }

    var allDescriptors: [Int32] {
        var descriptors = [
            stdin.readEnd,
            stdin.writeEnd,
            stdout.readEnd,
            stdout.writeEnd,
            stderr.readEnd,
            stderr.writeEnd,
        ]
        if let isolationHandshake {
            descriptors.append(isolationHandshake.readEnd)
            descriptors.append(isolationHandshake.writeEnd)
        }
        return descriptors
    }

    mutating func closeChildEndsInParent() {
        Darwin.close(stdin.readEnd)
        Darwin.close(stdout.writeEnd)
        Darwin.close(stderr.writeEnd)
        if let isolationHandshake {
            Darwin.close(isolationHandshake.writeEnd)
        }
    }

    mutating func closeAll() {
        for descriptor in allDescriptors {
            Darwin.close(descriptor)
        }
    }

    private static func makePipe(
        opened: inout [Int32]
    ) throws -> ProcessPipePair {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXIOError(operation: "pipe", code: errno)
        }
        opened.append(contentsOf: descriptors)
        return ProcessPipePair(
            readEnd: descriptors[0],
            writeEnd: descriptors[1]
        )
    }

    private mutating func relocateCollision(
        with reservedDescriptor: Int32,
        opened: inout [Int32]
    ) throws {
        func relocate(_ descriptor: inout Int32) throws {
            guard descriptor == reservedDescriptor else {
                return
            }
            let replacement = fcntl(
                descriptor,
                F_DUPFD_CLOEXEC,
                reservedDescriptor + 1
            )
            guard replacement != -1 else {
                throw POSIXIOError(
                    operation: "fcntl(F_DUPFD_CLOEXEC)",
                    code: errno
                )
            }
            Darwin.close(descriptor)
            if let index = opened.firstIndex(of: descriptor) {
                opened[index] = replacement
            }
            descriptor = replacement
        }

        try relocate(&stdin.readEnd)
        try relocate(&stdin.writeEnd)
        try relocate(&stdout.readEnd)
        try relocate(&stdout.writeEnd)
        try relocate(&stderr.readEnd)
        try relocate(&stderr.writeEnd)
        if isolationHandshake != nil {
            try relocate(&isolationHandshake!.readEnd)
            try relocate(&isolationHandshake!.writeEnd)
        }
    }
}

private struct POSIXIOError: Error, LocalizedError {
    let operation: String
    let code: Int32

    var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

private func checkPOSIX(_ code: Int32, operation: String) throws {
    guard code == 0 else {
        throw POSIXIOError(operation: operation, code: code)
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

private func withCStringVector<Result>(
    _ strings: [String],
    _ body: (
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) throws -> Result
) throws -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    for string in strings {
        guard let pointer = strdup(string) else {
            throw POSIXIOError(operation: "strdup", code: ENOMEM)
        }
        pointers.append(pointer)
    }
    pointers.append(nil)
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}
