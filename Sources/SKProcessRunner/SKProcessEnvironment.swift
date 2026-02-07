import Foundation

public struct SKProcessEnvironment: Sendable, Equatable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public static func current() -> SKProcessEnvironment {
        SKProcessEnvironment(ProcessInfo.processInfo.environment)
    }

    public static func userShell(
        shellPath: String? = nil,
        mode: SKProcessShellMode = .loginInteractive,
        timeoutMs: Int = 2_000
    ) -> SKProcessEnvironment {
        let loaded = SKProcessRunner.loadUserShellEnvironmentSync(
            environment: ProcessInfo.processInfo.environment,
            shellPath: shellPath,
            mode: mode,
            timeoutMs: timeoutMs
        )
        return SKProcessEnvironment(loaded.isEmpty ? ProcessInfo.processInfo.environment : loaded)
    }

    public func merging(_ overrides: [String: String]) -> SKProcessEnvironment {
        var merged = values
        for (k, v) in overrides { merged[k] = v }
        return SKProcessEnvironment(merged)
    }

    public func merged(with other: SKProcessEnvironment) -> SKProcessEnvironment {
        merging(other.values)
    }
}
