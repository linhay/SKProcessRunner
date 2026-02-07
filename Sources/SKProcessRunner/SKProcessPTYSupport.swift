import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum SKProcessPTYSupport {
    static func spawnPTYProcess(
        executableURL: URL,
        arguments: [String],
        configuration: SKProcessConfiguration,
        pty: SKProcessPTYConfiguration,
        baseEnvironment: [String: String]
    ) throws -> (pid: pid_t, masterFD: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1

        var window = winsize(
            ws_row: UInt16(max(1, pty.rows)),
            ws_col: UInt16(max(1, pty.cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        if openpty(&master, &slave, nil, nil, &window) != 0 {
            throw SKProcessRunError.ptyFailed("openpty failed with errno \(errno)")
        }

        var env = baseEnvironment
        for (k, v) in configuration.environment { env[k] = v }
        if env["TERM"] == nil {
            env["TERM"] = pty.term
        }

        let execPath = executableURL.path
        var argv = makeCStringArray([execPath] + arguments)
        var envp = makeCStringArray(env.map { "\($0.key)=\($0.value)" })
        defer {
            freeCStringArray(&argv)
            freeCStringArray(&envp)
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        if slave > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&fileActions, slave)
        }
        posix_spawn_file_actions_addclose(&fileActions, master)
#if canImport(Darwin)
        if let cwd = configuration.cwd {
            _ = cwd.path.withCString { path in
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            }
        }
#endif

        var attrs: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        var spawnFlags: Int16 = 0
#if canImport(Darwin)
        spawnFlags |= Int16(POSIX_SPAWN_SETSID)
#endif
        posix_spawnattr_setflags(&attrs, spawnFlags)

        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeBufferPointer { argvBuf in
            envp.withUnsafeBufferPointer { envBuf in
                posix_spawn(&pid, execPath, &fileActions, &attrs, argvBuf.baseAddress, envBuf.baseAddress)
            }
        }
        if spawnResult != 0 {
            close(master)
            close(slave)
            throw SKProcessRunError.ptyFailed("posix_spawn failed with errno \(spawnResult)")
        }

        close(slave)
        let fdFlags = fcntl(master, F_GETFL, 0)
        if fdFlags >= 0 {
            _ = fcntl(master, F_SETFL, fdFlags | O_NONBLOCK)
        }
        return (pid, master)
    }

    static func makeCStringArray(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var out: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        out.append(nil)
        return out
    }

    static func freeCStringArray(_ values: inout [UnsafeMutablePointer<CChar>?]) {
        for case let ptr? in values {
            free(ptr)
        }
        values.removeAll(keepingCapacity: false)
    }

    static func drainFD(_ fd: Int32) -> Data {
        var data = Data()
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let count = read(fd, &buffer, bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count < 0, errno == EAGAIN {
                break
            }
            break
        }

        return data
    }

    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = rawBuffer.count - offset
                let written = write(fd, base.advanced(by: offset), count)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == -1, errno == EINTR {
                    continue
                }
                if written == -1, errno == EAGAIN {
                    usleep(1_000)
                    continue
                }
                throw SKProcessRunError.ptyFailed("write failed with errno \(errno)")
            }
        }
    }

    static func waitForExit(pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { return status }
            if result == -1, errno == EINTR { continue }
            return status
        }
    }

    static func exitCode(from status: Int32) -> Int {
        if wIfExited(status) {
            return Int(wExitStatus(status))
        }
        if wIfSignaled(status) {
            return 128 + Int(wTermSig(status))
        }
        return -1
    }

    private static func wStatus(_ status: Int32) -> Int32 {
        status & 0x7f
    }

    private static func wIfExited(_ status: Int32) -> Bool {
        wStatus(status) == 0
    }

    private static func wExitStatus(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    private static func wIfSignaled(_ status: Int32) -> Bool {
        let ws = wStatus(status)
        return ws != 0 && ws != 0x7f
    }

    private static func wTermSig(_ status: Int32) -> Int32 {
        wStatus(status)
    }
}
