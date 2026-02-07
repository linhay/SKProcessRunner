import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public extension SKProcessRunner {
    static func runPTY(_ payload: SKProcessPayload) async throws -> SKProcessResult {
        try await runPTY(payload, onStdout: nil)
    }

    static func runPTY(
        _ payload: SKProcessPayload,
        onStdout: (@Sendable (Data) -> Void)?
    ) async throws -> SKProcessResult {
        let (resolved, configuration, baseEnv) = try SKProcessEnvironmentResolver.resolveExecutableAndConfiguration(payload)
        let pty = payload.pty ?? .init()
        return try await runPTYInternal(
            executableURL: resolved,
            arguments: payload.arguments,
            stdinData: payload.stdinData,
            configuration: configuration,
            pty: pty,
            onStdout: onStdout,
            throwOnNonZeroExit: payload.throwOnNonZeroExit,
            baseEnvironment: baseEnv
        )
    }

    static func runPTYSync(_ payload: SKProcessPayload) throws -> SKProcessResult {
        try runPTYSync(payload, onStdout: nil)
    }

    static func runPTYSync(
        _ payload: SKProcessPayload,
        onStdout: ((Data) -> Void)?
    ) throws -> SKProcessResult {
        let (resolved, configuration, baseEnv) = try SKProcessEnvironmentResolver.resolveExecutableAndConfiguration(payload)
        let pty = payload.pty ?? .init()
        return try runPTYSynchronous(
            executableURL: resolved,
            arguments: payload.arguments,
            stdinData: payload.stdinData,
            configuration: configuration,
            pty: pty,
            onStdout: onStdout,
            throwOnNonZeroExit: payload.throwOnNonZeroExit,
            baseEnvironment: baseEnv
        )
    }

    private static func runPTYInternal(
        executableURL: URL,
        arguments: [String],
        stdinData: Data?,
        configuration: SKProcessConfiguration,
        pty: SKProcessPTYConfiguration,
        onStdout: (@Sendable (Data) -> Void)?,
        throwOnNonZeroExit: Bool,
        baseEnvironment: [String: String]
    ) async throws -> SKProcessResult {
        let timeoutMs = max(1_000, min(configuration.timeoutMs, 30 * 60 * 1000))
        let maxOutputBytes = max(8 * 1024, min(configuration.maxOutputBytes, 2 * 1024 * 1024))

        let (pid, masterFD) = try SKProcessPTYSupport.spawnPTYProcess(
            executableURL: executableURL,
            arguments: arguments,
            configuration: configuration,
            pty: pty,
            baseEnvironment: baseEnvironment
        )

        if let stdinData {
            DispatchQueue.global(qos: .utility).async {
                _ = stdinData.withUnsafeBytes { ptr in
                    guard let base = ptr.baseAddress else { return }
                    _ = write(masterFD, base, ptr.count)
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let state = SKProcessRunnerState(maxOutputBytes: maxOutputBytes)
            let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)

            let readSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .utility))
            readSource.setEventHandler {
                let data = masterHandle.availableData
                guard !data.isEmpty else { return }
                state.appendStdout(data)
                onStdout?(data)
            }
            readSource.resume()

            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(timeoutMs))
            timer.setEventHandler {
                guard state.finishIfNeeded() else { return }

                kill(-pid, SIGTERM)
                kill(pid, SIGTERM)
                readSource.cancel()
                let remaining = SKProcessPTYSupport.drainFD(masterFD)
                state.appendStdout(remaining)
                timer.cancel()

                continuation.resume(throwing: SKProcessRunError.timedOut(
                    timeoutMs: timeoutMs,
                    stdoutData: state.stdoutData,
                    stderrData: Data(),
                    truncated: state.truncated
                ))
            }
            timer.resume()

            DispatchQueue.global(qos: .utility).async {
                let status = SKProcessPTYSupport.waitForExit(pid: pid)

                guard state.finishIfNeeded() else { return }

                readSource.cancel()
                let remaining = SKProcessPTYSupport.drainFD(masterFD)
                state.appendStdout(remaining)
                timer.cancel()

                let code = SKProcessPTYSupport.exitCode(from: status)
                let result = SKProcessResult(
                    stdoutData: state.stdoutData,
                    stderrData: Data(),
                    exitCode: code,
                    timedOut: false,
                    truncated: state.truncated
                )

                if throwOnNonZeroExit, code != 0 {
                    continuation.resume(throwing: SKProcessRunError.nonZeroExit(
                        exitCode: code,
                        stdoutData: state.stdoutData,
                        stderrData: Data()
                    ))
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private static func runPTYSynchronous(
        executableURL: URL,
        arguments: [String],
        stdinData: Data?,
        configuration: SKProcessConfiguration,
        pty: SKProcessPTYConfiguration,
        onStdout: ((Data) -> Void)?,
        throwOnNonZeroExit: Bool,
        baseEnvironment: [String: String]
    ) throws -> SKProcessResult {
        let timeoutMs = max(1_000, min(configuration.timeoutMs, 30 * 60 * 1000))
        let maxOutputBytes = max(8 * 1024, min(configuration.maxOutputBytes, 2 * 1024 * 1024))

        let (pid, masterFD) = try SKProcessPTYSupport.spawnPTYProcess(
            executableURL: executableURL,
            arguments: arguments,
            configuration: configuration,
            pty: pty,
            baseEnvironment: baseEnvironment
        )

        if let stdinData {
            _ = stdinData.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                _ = write(masterFD, base, ptr.count)
            }
        }

        let state = SKProcessRunnerState(maxOutputBytes: maxOutputBytes)
        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)

        let readSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .utility))
        readSource.setEventHandler {
            let data = masterHandle.availableData
            guard !data.isEmpty else { return }
            state.appendStdout(data)
            onStdout?(data)
        }
        readSource.resume()

        let semaphore = DispatchSemaphore(value: 0)
        var finishedResult: SKProcessResult?
        var finishedError: Error?

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(timeoutMs))
        timer.setEventHandler {
            guard state.finishIfNeeded() else { return }

            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
            readSource.cancel()
            let remaining = SKProcessPTYSupport.drainFD(masterFD)
            state.appendStdout(remaining)
            timer.cancel()

            finishedError = SKProcessRunError.timedOut(
                timeoutMs: timeoutMs,
                stdoutData: state.stdoutData,
                stderrData: Data(),
                truncated: state.truncated
            )
            semaphore.signal()
        }
        timer.resume()

        DispatchQueue.global(qos: .utility).async {
            let status = SKProcessPTYSupport.waitForExit(pid: pid)

            guard state.finishIfNeeded() else { return }

            readSource.cancel()
            let remaining = SKProcessPTYSupport.drainFD(masterFD)
            state.appendStdout(remaining)
            timer.cancel()

            let code = SKProcessPTYSupport.exitCode(from: status)
            let result = SKProcessResult(
                stdoutData: state.stdoutData,
                stderrData: Data(),
                exitCode: code,
                timedOut: false,
                truncated: state.truncated
            )

            if throwOnNonZeroExit, code != 0 {
                finishedError = SKProcessRunError.nonZeroExit(
                    exitCode: code,
                    stdoutData: state.stdoutData,
                    stderrData: Data()
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
