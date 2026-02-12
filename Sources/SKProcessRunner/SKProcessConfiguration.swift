import Foundation

public struct SKProcessConfiguration: Sendable, Equatable {
    public var cwd: URL?
    public var environment: [String: String]
    public var timeoutMs: Int
    public var maxOutputBytes: Int
    public var terminationGracePeriodMs: Int
    public var spoolFullOutput: Bool
    public var fullOutputDirectory: URL?

    public init(
        cwd: URL? = nil,
        environment: [String: String] = [:],
        timeoutMs: Int = 12_000,
        maxOutputBytes: Int = 64 * 1024,
        terminationGracePeriodMs: Int = 300,
        spoolFullOutput: Bool = false,
        fullOutputDirectory: URL? = nil
    ) {
        self.cwd = cwd
        self.environment = environment
        self.timeoutMs = timeoutMs
        self.maxOutputBytes = maxOutputBytes
        self.terminationGracePeriodMs = terminationGracePeriodMs
        self.spoolFullOutput = spoolFullOutput
        self.fullOutputDirectory = fullOutputDirectory
    }

    public init(
        cwd: URL? = nil,
        environment: SKProcessEnvironment,
        timeoutMs: Int = 12_000,
        maxOutputBytes: Int = 64 * 1024,
        terminationGracePeriodMs: Int = 300,
        spoolFullOutput: Bool = false,
        fullOutputDirectory: URL? = nil
    ) {
        self.init(
            cwd: cwd,
            environment: environment.values,
            timeoutMs: timeoutMs,
            maxOutputBytes: maxOutputBytes,
            terminationGracePeriodMs: terminationGracePeriodMs,
            spoolFullOutput: spoolFullOutput,
            fullOutputDirectory: fullOutputDirectory
        )
    }
}
