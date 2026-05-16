import Foundation

public enum SKProcessRunError: Error, Sendable, Equatable, LocalizedError {
    case executableNotFound(String)
    case invalidExecutable(String)
    case ptyFailed(String)
    case nonZeroExit(exitCode: Int, stdoutData: Data, stderrData: Data)
    case timedOut(timeoutMs: Int, stdoutData: Data, stderrData: Data, truncated: Bool)

    public static func unsupportedPlatform(_ message: String) -> SKProcessRunError {
        .invalidExecutable("Unsupported platform: \(message)")
    }

    public static func pipeFailed(_ message: String) -> SKProcessRunError {
        .ptyFailed("Pipe session failed: \(message)")
    }

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "Executable not found on PATH: \(name)"
        case .invalidExecutable(let value):
            return "Invalid executable: \(value)"
        case .ptyFailed(let message):
            return "PTY setup failed: \(message)"
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
