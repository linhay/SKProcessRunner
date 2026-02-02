import Foundation

public enum SKProcessRunner {}

public extension SKProcessRunner {
    struct Configuration: Sendable, Equatable {
        public var cwd: URL?
        public var environment: [String: String]
        public var timeoutMs: Int
        public var maxOutputBytes: Int

        public init(
            cwd: URL? = nil,
            environment: [String: String] = [:],
            timeoutMs: Int = 12_000,
            maxOutputBytes: Int = 64 * 1024
        ) {
            self.cwd = cwd
            self.environment = environment
            self.timeoutMs = timeoutMs
            self.maxOutputBytes = maxOutputBytes
        }
    }

    struct Result: Sendable, Equatable {
        public let stdoutData: Data
        public let stderrData: Data
        public let exitCode: Int
        public let timedOut: Bool
        public let truncated: Bool

        public var stdout: String { String(data: stdoutData, encoding: .utf8) ?? "" }
        public var stderr: String { String(data: stderrData, encoding: .utf8) ?? "" }

        public init(stdoutData: Data, stderrData: Data, exitCode: Int, timedOut: Bool, truncated: Bool) {
            self.stdoutData = stdoutData
            self.stderrData = stderrData
            self.exitCode = exitCode
            self.timedOut = timedOut
            self.truncated = truncated
        }

        public init(stdout: String, stderr: String, exitCode: Int, timedOut: Bool, truncated: Bool) {
            self.init(
                stdoutData: Data(stdout.utf8),
                stderrData: Data(stderr.utf8),
                exitCode: exitCode,
                timedOut: timedOut,
                truncated: truncated
            )
        }
    }

    enum RunError: Error, Sendable, Equatable, LocalizedError {
        case executableNotFound(String)
        case invalidExecutable(String)
        case nonZeroExit(exitCode: Int, stdoutData: Data, stderrData: Data)
        case timedOut(timeoutMs: Int, stdoutData: Data, stderrData: Data, truncated: Bool)

        public var errorDescription: String? {
            switch self {
            case .executableNotFound(let name):
                return "Executable not found on PATH: \(name)"
            case .invalidExecutable(let value):
                return "Invalid executable: \(value)"
            case .nonZeroExit(let code, let stdoutData, let stderrData):
                let out = String(data: stdoutData, encoding: .utf8) ?? ""
                let err = String(data: stderrData, encoding: .utf8) ?? ""
                let msg = err.isEmpty ? out : err
                return "Process exited with status \(code).\n\(msg)"
            case .timedOut(let timeoutMs, let stdoutData, let stderrData, _):
                let seconds = Double(timeoutMs) / 1000.0
                let out = String(data: stdoutData, encoding: .utf8) ?? ""
                let err = String(data: stderrData, encoding: .utf8) ?? ""
                let combined = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
                return "Timed out after \(Int(seconds))s.\n\(combined)"
            }
        }
    }
}

public extension SKProcessRunner {
    static func resolveExecutable(
        _ value: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RunError.invalidExecutable(value) }

        if trimmed.contains("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        if let url = resolveExecutableInPath(named: trimmed, environment: environment) {
            return url
        }
        throw RunError.executableNotFound(trimmed)
    }

    static func resolveExecutableInPath(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let pathValue = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }
}

public extension SKProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String] = [],
        configuration: Configuration = .init()
    ) async throws -> Result {
        try await run(
            executableURL: executableURL,
            arguments: arguments,
            stdinData: nil,
            configuration: configuration,
            onStdout: nil,
            onStderr: nil,
            throwOnNonZeroExit: false
        )
    }

    static func run(
        executableURL: URL,
        arguments: [String] = [],
        configuration: Configuration = .init(),
        throwOnNonZeroExit: Bool
    ) async throws -> Result {
        try await run(
            executableURL: executableURL,
            arguments: arguments,
            stdinData: nil,
            configuration: configuration,
            onStdout: nil,
            onStderr: nil,
            throwOnNonZeroExit: throwOnNonZeroExit
        )
    }

    static func run(
        executableURL: URL,
        arguments: [String] = [],
        stdinData: Data?,
        configuration: Configuration = .init(),
        onStdout: (@Sendable (Data) -> Void)?,
        onStderr: (@Sendable (Data) -> Void)?,
        throwOnNonZeroExit: Bool
    ) async throws -> Result {
        let timeoutMs = max(1_000, min(configuration.timeoutMs, 30 * 60 * 1000))
        let maxOutputBytes = max(8 * 1024, min(configuration.maxOutputBytes, 2 * 1024 * 1024))

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
            let state = RunnerState(maxOutputBytes: maxOutputBytes)

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

                process.terminate()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                state.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                state.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                timer.cancel()

                continuation.resume(throwing: RunError.timedOut(
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
                let result = Result(
                    stdoutData: state.stdoutData,
                    stderrData: state.stderrData,
                    exitCode: code,
                    timedOut: false,
                    truncated: state.truncated
                )

                if throwOnNonZeroExit, code != 0 {
                    continuation.resume(throwing: RunError.nonZeroExit(
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

public extension SKProcessRunner {
    static func runSync(
        executableURL: URL,
        arguments: [String] = [],
        stdinData: Data? = nil,
        configuration: Configuration = .init(),
        onStdout: ((Data) -> Void)? = nil,
        onStderr: ((Data) -> Void)? = nil,
        throwOnNonZeroExit: Bool
    ) throws -> Result {
        let timeoutMs = max(1_000, min(configuration.timeoutMs, 30 * 60 * 1000))
        let maxOutputBytes = max(8 * 1024, min(configuration.maxOutputBytes, 2 * 1024 * 1024))

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

        let state = RunnerState(maxOutputBytes: maxOutputBytes)
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
        var finishedResult: Result?
        var finishedError: Error?

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(timeoutMs))
        timer.setEventHandler {
            guard state.finishIfNeeded() else { return }

            process.terminate()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            state.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            state.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            timer.cancel()

            finishedError = RunError.timedOut(
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
            let result = Result(
                stdoutData: state.stdoutData,
                stderrData: state.stderrData,
                exitCode: code,
                timedOut: false,
                truncated: state.truncated
            )

            if throwOnNonZeroExit, code != 0 {
                finishedError = RunError.nonZeroExit(
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

private final class RunnerState: @unchecked Sendable {
    private let lock = NSLock()
    private let maxOutputBytes: Int
    private var isFinished = false

    private(set) var stdoutData = Data()
    private(set) var stderrData = Data()
    private(set) var truncated = false

    init(maxOutputBytes: Int) {
        self.maxOutputBytes = maxOutputBytes
    }

    func appendStdout(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        appendCapped(data, to: &stdoutData)
    }

    func appendStderr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        appendCapped(data, to: &stderrData)
    }

    func finishIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isFinished { return false }
        isFinished = true
        return true
    }

    private func appendCapped(_ chunk: Data, to buffer: inout Data) {
        guard !chunk.isEmpty else { return }
        let remaining = max(0, maxOutputBytes - buffer.count)
        if remaining == 0 { truncated = true; return }
        if chunk.count <= remaining {
            buffer.append(chunk)
        } else {
            buffer.append(chunk.prefix(remaining))
            truncated = true
        }
    }
}
