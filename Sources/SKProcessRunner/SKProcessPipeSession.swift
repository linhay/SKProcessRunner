import Foundation

public actor SKProcessPipeSession {
    public let stdout: AsyncStream<Data>
    public let stderr: AsyncStream<Data>
    public nonisolated let pid: pid_t

    private let throwOnNonZeroExit: Bool
    private let timeoutMs: Int
    private let terminationGracePeriodMs: Int

    private let state: SKProcessRunnerState
    private let process: Process
    private let stdoutReadHandle: FileHandle
    private let stderrReadHandle: FileHandle
    private let stdinWriteHandle: FileHandle
    private let stdoutReadSource: DispatchSourceRead
    private let stderrReadSource: DispatchSourceRead
    private let timer: DispatchSourceTimer
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stderrContinuation: AsyncStream<Data>.Continuation?
    private var waiters: [CheckedContinuation<SKProcessResult, Error>] = []

    private var isStdinClosed = false
    private var isFinished = false
    private var finishedResult: SKProcessResult?
    private var finishedError: Error?

    public init(_ payload: SKProcessPayload) throws {
        let (resolved, configuration, _) = try SKProcessEnvironmentResolver.resolveExecutableAndConfiguration(payload)
        let timeoutMs = max(1_000, min(configuration.timeoutMs, 30 * 60 * 1000))
        let maxOutputBytes = max(8 * 1024, min(configuration.maxOutputBytes, 2 * 1024 * 1024))
        let terminationGracePeriodMs = max(0, min(configuration.terminationGracePeriodMs, 10_000))

        let process = Process()
        process.executableURL = resolved
        process.arguments = payload.arguments
        process.currentDirectoryURL = configuration.cwd
        process.environment = configuration.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()

        self.pid = process.processIdentifier
        self.throwOnNonZeroExit = payload.throwOnNonZeroExit
        self.timeoutMs = timeoutMs
        self.terminationGracePeriodMs = terminationGracePeriodMs
        self.state = SKProcessRunnerState(
            maxOutputBytes: maxOutputBytes,
            spoolFullOutput: configuration.spoolFullOutput,
            fullOutputDirectory: configuration.fullOutputDirectory
        )
        self.process = process
        self.stdoutReadHandle = stdoutPipe.fileHandleForReading
        self.stderrReadHandle = stderrPipe.fileHandleForReading
        self.stdinWriteHandle = stdinPipe.fileHandleForWriting

        var stdoutCont: AsyncStream<Data>.Continuation?
        self.stdout = AsyncStream<Data> { continuation in
            stdoutCont = continuation
        }
        self.stdoutContinuation = stdoutCont

        var stderrCont: AsyncStream<Data>.Continuation?
        self.stderr = AsyncStream<Data> { continuation in
            stderrCont = continuation
        }
        self.stderrContinuation = stderrCont

        let stdoutFD = stdoutReadHandle.fileDescriptor
        let stderrFD = stderrReadHandle.fileDescriptor
        self.stdoutReadSource = DispatchSource.makeReadSource(fileDescriptor: stdoutFD, queue: .global(qos: .utility))
        self.stderrReadSource = DispatchSource.makeReadSource(fileDescriptor: stderrFD, queue: .global(qos: .utility))
        self.timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

        stdoutReadSource.setEventHandler { [stdoutReadHandle] in
            let data = stdoutReadHandle.availableData
            guard !data.isEmpty else { return }
            Task { await self.handleStdoutRead(data) }
        }
        stderrReadSource.setEventHandler { [stderrReadHandle] in
            let data = stderrReadHandle.availableData
            guard !data.isEmpty else { return }
            Task { await self.handleStderrRead(data) }
        }
        stdoutReadSource.resume()
        stderrReadSource.resume()

        timer.schedule(deadline: .now() + .milliseconds(timeoutMs))
        timer.setEventHandler {
            Task { await self.handleTimeout() }
        }
        timer.resume()

        process.terminationHandler = { _ in
            self.timer.cancel()
            Task { await self.handleExit() }
        }
    }

    public func send(_ data: Data) async throws {
        guard !isFinished else {
            throw SKProcessRunError.pipeFailed("process already finished")
        }
        guard !isStdinClosed else {
            throw SKProcessRunError.pipeFailed("stdin is closed")
        }
        do {
            try stdinWriteHandle.write(contentsOf: data)
        } catch {
            throw SKProcessRunError.pipeFailed("failed to write stdin: \(error.localizedDescription)")
        }
    }

    public func closeStdin() async throws {
        guard !isStdinClosed else { return }
        isStdinClosed = true
        do {
            try stdinWriteHandle.close()
        } catch {
            throw SKProcessRunError.pipeFailed("failed to close stdin: \(error.localizedDescription)")
        }
    }

    public func wait() async throws -> SKProcessResult {
        if let finishedError { throw finishedError }
        if let finishedResult { return finishedResult }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func terminate() async {
        guard !isFinished else { return }
        SKProcessTreeTerminator.terminateProcessTree(
            rootPID: pid,
            gracePeriodMs: terminationGracePeriodMs
        )
    }

    private func handleStdoutRead(_ data: Data) {
        guard !isFinished else { return }
        guard !data.isEmpty else { return }
        state.appendStdout(data)
        stdoutContinuation?.yield(data)
    }

    private func handleStderrRead(_ data: Data) {
        guard !isFinished else { return }
        guard !data.isEmpty else { return }
        state.appendStderr(data)
        stderrContinuation?.yield(data)
    }

    private func handleTimeout() {
        guard !isFinished else { return }
        isFinished = true

        SKProcessTreeTerminator.terminateProcessTree(
            rootPID: pid,
            gracePeriodMs: terminationGracePeriodMs
        )
        finishIO()

        let error = SKProcessRunError.timedOut(
            timeoutMs: timeoutMs,
            stdoutData: state.stdoutData,
            stderrData: state.stderrData,
            truncated: state.truncated
        )
        finishedError = error
        for waiter in waiters { waiter.resume(throwing: error) }
        waiters.removeAll()
    }

    private func handleExit() {
        guard !isFinished else { return }
        isFinished = true
        finishIO()

        let code = Int(process.terminationStatus)
        let result = SKProcessResult(
            stdoutData: state.stdoutData,
            stderrData: state.stderrData,
            exitCode: code,
            timedOut: false,
            truncated: state.truncated,
            fullOutputPath: state.fullOutputPath
        )

        if throwOnNonZeroExit, code != 0 {
            let error = SKProcessRunError.nonZeroExit(
                exitCode: code,
                stdoutData: state.stdoutData,
                stderrData: state.stderrData
            )
            finishedError = error
            for waiter in waiters { waiter.resume(throwing: error) }
        } else {
            finishedResult = result
            for waiter in waiters { waiter.resume(returning: result) }
        }
        waiters.removeAll()
    }

    private func finishIO() {
        stdoutReadSource.cancel()
        stderrReadSource.cancel()
        state.appendStdout(stdoutReadHandle.readDataToEndOfFile())
        state.appendStderr(stderrReadHandle.readDataToEndOfFile())

        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        try? stdinWriteHandle.close()
    }
}
