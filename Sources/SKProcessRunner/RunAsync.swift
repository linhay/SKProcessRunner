import Foundation

public extension SKProcessRunner {
    static func run(_ payload: SKProcessPayload) async throws -> SKProcessResult {
        try await run(payload, onStdout: nil, onStderr: nil)
    }

    static func run(
        _ payload: SKProcessPayload,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?
    ) async throws -> SKProcessResult {
        let (resolved, configuration, _) = try SKProcessEnvironmentResolver.resolveExecutableAndConfiguration(payload)
        return try await runResolved(
            executableURL: resolved,
            arguments: payload.arguments,
            stdinData: payload.stdinData,
            configuration: configuration,
            onStdout: onStdout,
            onStderr: onStderr,
            throwOnNonZeroExit: payload.throwOnNonZeroExit
        )
    }

    private static func runResolved(
        executableURL: URL,
        arguments: [String],
        stdinData: Data?,
        configuration: SKProcessConfiguration,
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?,
        throwOnNonZeroExit: Bool
    ) async throws -> SKProcessResult {
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

        let inputPipe: Pipe?
        if stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            inputPipe = nil
        }

        try process.run()

        if let stdinData, let inputPipe {
            DispatchQueue.global(qos: .utility).async {
                do {
                    try inputPipe.fileHandleForWriting.write(contentsOf: stdinData)
                    try inputPipe.fileHandleForWriting.close()
                } catch {
                    // Best-effort: process may have already exited.
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
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

                continuation.resume(throwing: SKProcessRunError.timedOut(
                    timeoutMs: timeoutMs,
                    stdoutData: state.stdoutData,
                    stderrData: state.stderrData,
                    truncated: state.truncated
                ))
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
                    continuation.resume(throwing: SKProcessRunError.nonZeroExit(
                        exitCode: code,
                        stdoutData: state.stdoutData,
                        stderrData: state.stderrData
                    ))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}
