import Foundation

public extension SKProcessRunner {
    static func resolveExecutable(
        _ value: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SKProcessRunError.invalidExecutable(value) }

        if trimmed.contains("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        if let url = resolveExecutableInPath(named: trimmed, environment: environment) {
            return url
        }
        throw SKProcessRunError.executableNotFound(trimmed)
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
