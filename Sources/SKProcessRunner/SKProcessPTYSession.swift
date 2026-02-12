import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public actor SKProcessPTYSession {
    public let output: AsyncStream<Data>
    public nonisolated let pid: pid_t

    private let masterFD: Int32
    private let throwOnNonZeroExit: Bool
    private let timeoutMs: Int
    private let maxOutputBytes: Int

    private let state: SKProcessRunnerState
    private let masterHandle: FileHandle
    private let readSource: DispatchSourceRead
    private let timer: DispatchSourceTimer
    private var outputContinuation: AsyncStream<Data>.Continuation?
    private var waiters: [CheckedContinuation<SKProcessResult, Error>] = []

    private var isClosed = false
    private var isFinished = false
    private var finishedResult: SKProcessResult?
    private var finishedError: Error?

    public init(_ payload: SKProcessPayload) throws {
        let (resolved, configuration, baseEnv) = try SKProcessEnvironmentResolver.resolveExecutableAndConfiguration(payload)
        let pty = payload.pty ?? .init()
        let timeoutMs = max(1_000, min(configuration.timeoutMs, 30 * 60 * 1000))
        let maxOutputBytes = max(8 * 1024, min(configuration.maxOutputBytes, 2 * 1024 * 1024))

        let (pid, masterFD) = try SKProcessPTYSupport.spawnPTYProcess(
            executableURL: resolved,
            arguments: payload.arguments,
            configuration: configuration,
            pty: pty,
            baseEnvironment: baseEnv
        )

        self.pid = pid
        self.masterFD = masterFD
        self.throwOnNonZeroExit = payload.throwOnNonZeroExit
        self.timeoutMs = timeoutMs
        self.maxOutputBytes = maxOutputBytes

        self.state = SKProcessRunnerState(
            maxOutputBytes: maxOutputBytes,
            spoolFullOutput: configuration.spoolFullOutput,
            fullOutputDirectory: configuration.fullOutputDirectory
        )
        self.masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)

        var continuationRef: AsyncStream<Data>.Continuation?
        self.output = AsyncStream<Data> { continuation in
            continuationRef = continuation
        }
        self.outputContinuation = continuationRef

        self.readSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .utility))
        self.timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

        self.readSource.setEventHandler { [masterHandle] in
            let data = masterHandle.availableData
            guard !data.isEmpty else { return }
            Task { await self.handleRead(data) }
        }
        self.readSource.resume()

        self.timer.schedule(deadline: .now() + .milliseconds(timeoutMs))
        self.timer.setEventHandler {
            Task { await self.handleTimeout() }
        }
        self.timer.resume()

        DispatchQueue.global(qos: .utility).async {
            let status = SKProcessPTYSupport.waitForExit(pid: pid)
            Task { await self.handleExit(status: status) }
        }
    }

    public func send(_ data: Data) async throws {
        guard !isClosed else {
            throw SKProcessRunError.ptyFailed("stdin is closed")
        }
        try SKProcessPTYSupport.writeAll(fd: masterFD, data: data)
    }

    public func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        var eof: UInt8 = 0x04
        try SKProcessPTYSupport.writeAll(fd: masterFD, data: Data(bytes: &eof, count: 1))
    }

    public func wait() async throws -> SKProcessResult {
        if let finishedError { throw finishedError }
        if let finishedResult { return finishedResult }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func isRunning() -> Bool {
        !isFinished
    }

    public func terminate() async {
        guard !isFinished else { return }
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
    }

    public func resize(rows: Int, cols: Int) async throws {
        var window = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let ioctlResult = ioctl(masterFD, UInt(TIOCSWINSZ), &window)
        if ioctlResult != 0 {
            throw SKProcessRunError.ptyFailed("TIOCSWINSZ failed with errno \(errno)")
        }
    }

    private func handleRead(_ data: Data) {
        guard !data.isEmpty else { return }
        state.appendStdout(data)
        outputContinuation?.yield(data)
    }

    private func handleTimeout() {
        guard !isFinished else { return }
        isFinished = true
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        readSource.cancel()
        let remaining = SKProcessPTYSupport.drainFD(masterFD)
        state.appendStdout(remaining)
        timer.cancel()
        outputContinuation?.finish()

        let error = SKProcessRunError.timedOut(
            timeoutMs: timeoutMs,
            stdoutData: state.stdoutData,
            stderrData: Data(),
            truncated: state.truncated
        )
        finishedError = error
        for waiter in waiters { waiter.resume(throwing: error) }
        waiters.removeAll()
    }

    private func handleExit(status: Int32) {
        guard !isFinished else { return }
        isFinished = true
        readSource.cancel()
        let remaining = SKProcessPTYSupport.drainFD(masterFD)
        state.appendStdout(remaining)
        timer.cancel()
        outputContinuation?.finish()

        let code = SKProcessPTYSupport.exitCode(from: status)
        let result = SKProcessResult(
            stdoutData: state.stdoutData,
            stderrData: Data(),
            exitCode: code,
            timedOut: false,
            truncated: state.truncated,
            fullOutputPath: state.fullOutputPath
        )

        if throwOnNonZeroExit, code != 0 {
            let error = SKProcessRunError.nonZeroExit(
                exitCode: code,
                stdoutData: state.stdoutData,
                stderrData: Data()
            )
            finishedError = error
            for waiter in waiters { waiter.resume(throwing: error) }
        } else {
            finishedResult = result
            for waiter in waiters { waiter.resume(returning: result) }
        }
        waiters.removeAll()
    }
}
