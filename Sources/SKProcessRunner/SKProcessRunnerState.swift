import Foundation

final class SKProcessRunnerState: @unchecked Sendable {
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
