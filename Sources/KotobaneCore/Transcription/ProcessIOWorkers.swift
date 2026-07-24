import Darwin
import Foundation

enum ProcessOutputStream {
    case stdout
    case stderr
}

enum ProcessIOWorkers {
    static func writeRequest(
        _ request: Data,
        to descriptor: Int32,
        state: () -> (stop: Bool, directProcessExited: Bool),
        didExit: (_ failed: Bool, _ incomplete: Bool) -> Void
    ) {
        var failed = false
        var offset = 0
        defer {
            Darwin.close(descriptor)
            didExit(failed, offset < request.count)
        }

        while offset < request.count {
            let currentState = state()
            if currentState.stop {
                return
            }
            if currentState.directProcessExited {
                failed = true
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
            failed = true
            return
        }
    }

    static func readOutput(
        from descriptor: Int32,
        shouldContinue: () -> Bool,
        consume: (Data) -> Bool,
        didExit: () -> Void
    ) {
        defer {
            Darwin.close(descriptor)
            didExit()
        }
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while shouldContinue() {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                guard consume(Data(buffer.prefix(count))) else {
                    return
                }
                continue
            }
            if count == 0 {
                return
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(2_000)
                continue
            }
            return
        }
    }

    static func readIsolationHandshake(
        from descriptor: Int32,
        shouldContinue: () -> Bool,
        didExit: (_ installed: Bool, _ failed: Bool) -> Void
    ) {
        var failed = false
        var installed = false
        defer {
            Darwin.close(descriptor)
            didExit(installed, failed)
        }
        var buffer = [UInt8](repeating: 0, count: 8)
        while shouldContinue() {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                installed = count == 1 && buffer[0] == 0x78
                failed = !installed
                return
            }
            if count == 0 {
                failed = true
                return
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(2_000)
                continue
            }
            failed = true
            return
        }
    }
}
