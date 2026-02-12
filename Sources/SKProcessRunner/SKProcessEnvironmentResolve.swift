import Foundation

enum SKProcessEnvironmentResolver {
    static func loadBaseEnvironment(
        useUserShellEnvironment: Bool,
        userShellPath: String?,
        userShellMode: SKProcessShellMode,
        userShellTimeoutMs: Int
    ) -> [String: String] {
        if useUserShellEnvironment {
            let loaded = SKProcessRunner.loadUserShellEnvironmentSync(
                environment: ProcessInfo.processInfo.environment,
                shellPath: userShellPath,
                mode: userShellMode,
                timeoutMs: userShellTimeoutMs
            )
            return loaded.isEmpty ? ProcessInfo.processInfo.environment : loaded
        }
        return ProcessInfo.processInfo.environment
    }

    static func mergeConfiguration(
        _ configuration: SKProcessConfiguration,
        baseEnvironment: [String: String]
    ) -> SKProcessConfiguration {
        var merged = baseEnvironment
        if !configuration.environment.isEmpty {
            for (k, v) in configuration.environment { merged[k] = v }
        }
        return SKProcessConfiguration(
            cwd: configuration.cwd,
            environment: merged,
            timeoutMs: configuration.timeoutMs,
            maxOutputBytes: configuration.maxOutputBytes,
            terminationGracePeriodMs: configuration.terminationGracePeriodMs,
            spoolFullOutput: configuration.spoolFullOutput,
            fullOutputDirectory: configuration.fullOutputDirectory
        )
    }

    static func resolveExecutableAndConfiguration(
        _ payload: SKProcessPayload
    ) throws -> (URL, SKProcessConfiguration, [String: String]) {
        let baseEnv = loadBaseEnvironment(
            useUserShellEnvironment: payload.useUserShellEnvironment,
            userShellPath: payload.userShellPath,
            userShellMode: payload.userShellMode,
            userShellTimeoutMs: payload.userShellTimeoutMs
        )

        let resolved: URL
        switch payload.executable {
        case .path(let value):
            var env = baseEnv
            if let overrides = payload.environment?.values {
                for (k, v) in overrides { env[k] = v }
            }
            resolved = try SKProcessRunner.resolveExecutable(value, environment: env)
        case .url(let url):
            resolved = url
        }

        var configuration = SKProcessConfiguration(
            cwd: payload.cwd,
            environment: payload.environment?.values ?? [:],
            timeoutMs: payload.timeoutMs,
            maxOutputBytes: payload.maxOutputBytes,
            terminationGracePeriodMs: payload.terminationGracePeriodMs,
            spoolFullOutput: payload.spoolFullOutput,
            fullOutputDirectory: payload.fullOutputDirectory
        )

        let merged = mergeConfiguration(configuration, baseEnvironment: baseEnv)
        configuration = merged

        return (resolved, configuration, baseEnv)
    }
}
