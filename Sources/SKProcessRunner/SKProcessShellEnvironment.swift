import Foundation

public enum SKProcessShellMode: Sendable, Equatable {
    case login
    case loginInteractive
}

// MARK: - User Shell PATH Resolution

public extension SKProcessRunner {
    static func loadUserShellPATHSync(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellPath: String? = nil,
        mode: SKProcessShellMode = .loginInteractive,
        timeoutMs: Int = 1_500
    ) -> String? {
        let shell = (shellPath ?? environment["SHELL"] ?? "/bin/zsh").trimmingCharacters(in: .whitespacesAndNewlines)
        let shellURL = URL(fileURLWithPath: shell)
        let flags: [String]
        switch mode {
        case .login:
            flags = ["-lc"]
        case .loginInteractive:
            flags = ["-lic"]
        }

        // Use markers to tolerate noisy shell init output.
        let marker = "__SKPROCESSRUNNER_PATH__"
        let command = "printf '\(marker)%s\(marker)' \"$PATH\""
        let args = flags + [command]

        let config = SKProcessConfiguration(
            cwd: nil,
            environment: [:],
            timeoutMs: timeoutMs,
            maxOutputBytes: 128 * 1024
        )
        let payload = SKProcessPayload.executableURL(shellURL)
            .arguments(args)
            .cwd(config.cwd)
            .environment(SKProcessEnvironment(config.environment))
            .timeoutMs(config.timeoutMs)
            .maxOutputBytes(config.maxOutputBytes)

        guard let result = try? runSync(payload)
        else { return nil }

        guard let output = String(data: result.stdoutData, encoding: .utf8), !output.isEmpty else { return nil }
        guard let first = output.range(of: marker), let second = output.range(of: marker, range: first.upperBound..<output.endIndex)
        else { return nil }
        let value = String(output[first.upperBound..<second.lowerBound])
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func loadUserShellEnvironmentSync(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellPath: String? = nil,
        mode: SKProcessShellMode = .loginInteractive,
        timeoutMs: Int = 2_000
    ) -> [String: String] {
        let shell = (shellPath ?? environment["SHELL"] ?? "/bin/zsh").trimmingCharacters(in: .whitespacesAndNewlines)
        let shellURL = URL(fileURLWithPath: shell)
        let flags: [String]
        switch mode {
        case .login:
            flags = ["-lc"]
        case .loginInteractive:
            flags = ["-lic"]
        }

        // `env -0` is robust even if values contain spaces.
        let command = "env -0"
        let args = flags + [command]

        let config = SKProcessConfiguration(
            cwd: nil,
            environment: [:],
            timeoutMs: timeoutMs,
            maxOutputBytes: 512 * 1024
        )
        let payload = SKProcessPayload.executableURL(shellURL)
            .arguments(args)
            .cwd(config.cwd)
            .environment(SKProcessEnvironment(config.environment))
            .timeoutMs(config.timeoutMs)
            .maxOutputBytes(config.maxOutputBytes)

        guard let result = try? runSync(payload)
        else { return [:] }

        return parseNullSeparatedEnvironment(result.stdoutData)
    }

    static func resolveExecutableInUserShellSync(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellPath: String? = nil,
        mode: SKProcessShellMode = .loginInteractive,
        timeoutMs: Int = 1_500
    ) -> URL? {
        guard isSafeCommandName(name) else { return nil }

        let shell = (shellPath ?? environment["SHELL"] ?? "/bin/zsh").trimmingCharacters(in: .whitespacesAndNewlines)
        let shellURL = URL(fileURLWithPath: shell)
        let flags: [String]
        switch mode {
        case .login:
            flags = ["-lc"]
        case .loginInteractive:
            flags = ["-lic"]
        }

        // Use the user's login shell to resolve binaries that are added by shell init files
        // (e.g. npm/bun/Homebrew PATH entries).
        let command = "command -v \(name)"
        let args = flags + [command]

        let config = SKProcessConfiguration(
            cwd: nil,
            environment: [:],
            timeoutMs: timeoutMs,
            maxOutputBytes: 16 * 1024
        )
        let payload = SKProcessPayload.executableURL(shellURL)
            .arguments(args)
            .cwd(config.cwd)
            .environment(SKProcessEnvironment(config.environment))
            .timeoutMs(config.timeoutMs)
            .maxOutputBytes(config.maxOutputBytes)

        guard let result = try? runSync(payload)
        else { return nil }

        let resolved = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return nil }

        let url = URL(fileURLWithPath: resolved).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    static func resolveExecutableInUserShell(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellPath: String? = nil,
        mode: SKProcessShellMode = .loginInteractive,
        timeoutMs: Int = 1_500
    ) async -> URL? {
        guard isSafeCommandName(name) else { return nil }

        let shell = (shellPath ?? environment["SHELL"] ?? "/bin/zsh").trimmingCharacters(in: .whitespacesAndNewlines)
        let shellURL = URL(fileURLWithPath: shell)
        let flags: [String]
        switch mode {
        case .login:
            flags = ["-lc"]
        case .loginInteractive:
            flags = ["-lic"]
        }

        let command = "command -v \(name)"
        let args = flags + [command]

        let config = SKProcessConfiguration(
            cwd: nil,
            environment: [:],
            timeoutMs: timeoutMs,
            maxOutputBytes: 16 * 1024
        )
        let payload = SKProcessPayload.executableURL(shellURL)
            .arguments(args)
            .cwd(config.cwd)
            .environment(SKProcessEnvironment(config.environment))
            .timeoutMs(config.timeoutMs)
            .maxOutputBytes(config.maxOutputBytes)

        guard let result = try? await run(payload)
        else { return nil }

        let resolved = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return nil }

        let url = URL(fileURLWithPath: resolved).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    private static func isSafeCommandName(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("/") else { return false }
        for scalar in value.unicodeScalars {
            if scalar == "." || scalar == "_" || scalar == "-" { continue }
            if ("0"..."9").contains(scalar) { continue }
            if ("A"..."Z").contains(scalar) { continue }
            if ("a"..."z").contains(scalar) { continue }
            return false
        }
        return true
    }

    private static func parseNullSeparatedEnvironment(_ data: Data) -> [String: String] {
        guard !data.isEmpty else { return [:] }
        var out: [String: String] = [:]

        var start = data.startIndex
        while start < data.endIndex {
            guard let end = data[start...].firstIndex(of: 0) else { break }
            if end > start {
                let slice = data[start..<end]
                if let entry = String(data: slice, encoding: .utf8),
                   let eq = entry.firstIndex(of: "=")
                {
                    let key = String(entry[..<eq])
                    let value = String(entry[entry.index(after: eq)...])
                    if !key.isEmpty {
                        out[key] = value
                    }
                }
            }
            start = data.index(after: end)
        }

        return out
    }
}
