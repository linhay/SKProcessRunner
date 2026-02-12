import Foundation

public enum SKProcessExecutable: Sendable, Equatable {
    case path(String)
    case url(URL)
}

public struct SKProcessPayload: Sendable, Equatable {
    public var executable: SKProcessExecutable
    public var arguments: [String]
    public var stdinData: Data?
    public var cwd: URL?
    public var environment: SKProcessEnvironment?
    public var useUserShellEnvironment: Bool
    public var userShellPath: String?
    public var userShellMode: SKProcessShellMode
    public var userShellTimeoutMs: Int
    public var timeoutMs: Int
    public var maxOutputBytes: Int
    public var terminationGracePeriodMs: Int
    public var spoolFullOutput: Bool
    public var fullOutputDirectory: URL?
    public var throwOnNonZeroExit: Bool
    public var pty: SKProcessPTYConfiguration?

    public init(
        executable: SKProcessExecutable,
        arguments: [String] = [],
        stdinData: Data? = nil,
        cwd: URL? = nil,
        environment: SKProcessEnvironment? = nil,
        useUserShellEnvironment: Bool = false,
        userShellPath: String? = nil,
        userShellMode: SKProcessShellMode = .loginInteractive,
        userShellTimeoutMs: Int = 2_000,
        timeoutMs: Int = 12_000,
        maxOutputBytes: Int = 64 * 1024,
        terminationGracePeriodMs: Int = 300,
        spoolFullOutput: Bool = false,
        fullOutputDirectory: URL? = nil,
        throwOnNonZeroExit: Bool = false,
        pty: SKProcessPTYConfiguration? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdinData = stdinData
        self.cwd = cwd
        self.environment = environment
        self.useUserShellEnvironment = useUserShellEnvironment
        self.userShellPath = userShellPath
        self.userShellMode = userShellMode
        self.userShellTimeoutMs = userShellTimeoutMs
        self.timeoutMs = timeoutMs
        self.maxOutputBytes = maxOutputBytes
        self.terminationGracePeriodMs = terminationGracePeriodMs
        self.spoolFullOutput = spoolFullOutput
        self.fullOutputDirectory = fullOutputDirectory
        self.throwOnNonZeroExit = throwOnNonZeroExit
        self.pty = pty
    }
}

public extension SKProcessPayload {
    static func command(_ executable: String) -> Self {
        .init(executable: .path(executable))
    }

    static func executableURL(_ url: URL) -> Self {
        .init(executable: .url(url))
    }

    func arguments(_ value: [String]) -> Self {
        var copy = self
        copy.arguments = value
        return copy
    }

    func argument(_ value: String) -> Self {
        var copy = self
        copy.arguments.append(value)
        return copy
    }

    func stdin(_ data: Data?) -> Self {
        var copy = self
        copy.stdinData = data
        return copy
    }

    func stdin(_ string: String) -> Self {
        stdin(Data(string.utf8))
    }

    func cwd(_ value: URL?) -> Self {
        var copy = self
        copy.cwd = value
        return copy
    }

    func environment(_ value: SKProcessEnvironment?) -> Self {
        var copy = self
        copy.environment = value
        return copy
    }

    func useUserShellEnvironment(
        _ enabled: Bool = true,
        shellPath: String? = nil,
        mode: SKProcessShellMode = .loginInteractive,
        timeoutMs: Int = 2_000
    ) -> Self {
        var copy = self
        copy.useUserShellEnvironment = enabled
        copy.userShellPath = shellPath
        copy.userShellMode = mode
        copy.userShellTimeoutMs = timeoutMs
        return copy
    }

    func timeoutMs(_ value: Int) -> Self {
        var copy = self
        copy.timeoutMs = value
        return copy
    }

    func maxOutputBytes(_ value: Int) -> Self {
        var copy = self
        copy.maxOutputBytes = value
        return copy
    }

    func terminationGracePeriodMs(_ value: Int) -> Self {
        var copy = self
        copy.terminationGracePeriodMs = value
        return copy
    }

    func spoolFullOutput(_ enabled: Bool = true, directory: URL? = nil) -> Self {
        var copy = self
        copy.spoolFullOutput = enabled
        copy.fullOutputDirectory = directory
        return copy
    }

    func throwOnNonZeroExit(_ value: Bool = true) -> Self {
        var copy = self
        copy.throwOnNonZeroExit = value
        return copy
    }

    func pty(_ value: SKProcessPTYConfiguration) -> Self {
        var copy = self
        copy.pty = value
        return copy
    }
}
