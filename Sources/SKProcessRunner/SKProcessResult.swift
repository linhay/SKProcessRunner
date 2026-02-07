import Foundation

public struct SKProcessResult: Sendable, Equatable {
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
