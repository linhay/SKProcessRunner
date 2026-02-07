import Foundation

public struct SKProcessConfiguration: Sendable, Equatable {
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

    public init(
        cwd: URL? = nil,
        environment: SKProcessEnvironment,
        timeoutMs: Int = 12_000,
        maxOutputBytes: Int = 64 * 1024
    ) {
        self.init(
            cwd: cwd,
            environment: environment.values,
            timeoutMs: timeoutMs,
            maxOutputBytes: maxOutputBytes
        )
    }
}
