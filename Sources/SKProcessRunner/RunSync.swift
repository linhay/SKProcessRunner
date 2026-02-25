import Foundation

#if os(macOS)
public extension SKProcessRunner {
    static func runSync(_ payload: SKProcessPayload) throws -> SKProcessResult {
        try runSync(payload, onStdout: nil, onStderr: nil)
    }

    static func runSync(
        _ payload: SKProcessPayload,
        onStdout: ((Data) -> Void)?,
        onStderr: ((Data) -> Void)?
    ) throws -> SKProcessResult {
        let (resolved, configuration, _) = try SKProcessEnvironmentResolver.resolveExecutableAndConfiguration(payload)
        return try runSyncResolved(
            executableURL: resolved,
            arguments: payload.arguments,
            stdinData: payload.stdinData,
            configuration: configuration,
            onStdout: onStdout,
            onStderr: onStderr,
            throwOnNonZeroExit: payload.throwOnNonZeroExit
        )
    }

    private static func runSyncResolved(
        executableURL: URL,
        arguments: [String],
        stdinData: Data?,
        configuration: SKProcessConfiguration,
        onStdout: ((Data) -> Void)?,
        onStderr: ((Data) -> Void)?,
        throwOnNonZeroExit: Bool
    ) throws -> SKProcessResult {
        let timeoutMs = max(1_000, min(configuration.timeoutMs, 30 * 60 * 1000))
        let maxOutputBytes = max(8 * 1024, min(configuration.maxOutputBytes, 2 * 1024 * 1024))
        let terminationGracePeriodMs = max(0, min(configuration.terminationGracePeriodMs, 10_000))

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = configuration.cwd

        if !configuration.environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in configuration.environment { merged[k] = v }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = SKProcessRunnerState(
            maxOutputBytes: maxOutputBytes,
            spoolFullOutput: configuration.spoolFullOutput,
            fullOutputDirectory: configuration.fullOutputDirectory
        )
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            state.appendStdout(chunk)
            onStdout?(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            state.appendStderr(chunk)
            onStderr?(chunk)
        }

        if let stdinData {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            try process.run()
            try inputPipe.fileHandleForWriting.write(contentsOf: stdinData)
            try inputPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        let semaphore = DispatchSemaphore(value: 0)
        var finishedResult: SKProcessResult?
        var finishedError: Error?

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(timeoutMs))
        timer.setEventHandler {
            guard state.finishIfNeeded() else { return }

            SKProcessTreeTerminator.terminateProcessTree(
                rootPID: process.processIdentifier,
                gracePeriodMs: terminationGracePeriodMs
            )
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            state.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            state.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            timer.cancel()

            finishedError = SKProcessRunError.timedOut(
                timeoutMs: timeoutMs,
                stdoutData: state.stdoutData,
                stderrData: state.stderrData,
                truncated: state.truncated
            )
            semaphore.signal()
        }
        timer.resume()

        process.terminationHandler = { _ in
            guard state.finishIfNeeded() else { return }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            state.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            state.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            timer.cancel()

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
                finishedError = SKProcessRunError.nonZeroExit(
                    exitCode: code,
                    stdoutData: state.stdoutData,
                    stderrData: state.stderrData
                )
            } else {
                finishedResult = result
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .distantFuture)

        if let finishedError { throw finishedError }
        return finishedResult ?? .init(stdoutData: Data(), stderrData: Data(), exitCode: -1, timedOut: false, truncated: false)
    }
}
#else
public extension SKProcessRunner {
    static func runSync(_ payload: SKProcessPayload) throws -> SKProcessResult {
        throw SKProcessRunError.unsupportedPlatform("runSync is only available on macOS.")
    }

    static func runSync(
        _ payload: SKProcessPayload,
        onStdout: ((Data) -> Void)?,
        onStderr: ((Data) -> Void)?
    ) throws -> SKProcessResult {
        throw SKProcessRunError.unsupportedPlatform("runSync is only available on macOS.")
    }
}
#endif
