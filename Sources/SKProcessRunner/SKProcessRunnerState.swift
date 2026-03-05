import Foundation

final class SKProcessRunnerState: @unchecked Sendable {
    private let lock = NSLock()
    private let maxOutputBytes: Int
    private let spoolFullOutput: Bool
    private let fullOutputDirectory: URL?
    private var isFinished = false

    private(set) var stdoutData = Data()
    private(set) var stderrData = Data()
    private(set) var mergedData = Data()
    private(set) var truncated = false
    private(set) var fullOutputPath: String?

    private var spoolHandle: FileHandle?
    private var spoolFileURL: URL?
    private var spoolFailed = false

    init(maxOutputBytes: Int, spoolFullOutput: Bool = false, fullOutputDirectory: URL? = nil) {
        self.maxOutputBytes = maxOutputBytes
        self.spoolFullOutput = spoolFullOutput
        self.fullOutputDirectory = fullOutputDirectory
        setupSpoolIfNeeded()
    }

    func appendStdout(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        appendToSpool(data)
        appendCapped(data, to: &stdoutData)
        appendCapped(data, to: &mergedData)
    }

    func appendStderr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        appendToSpool(data)
        appendCapped(data, to: &stderrData)
        appendCapped(data, to: &mergedData)
    }

    func mergedDataSnapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return mergedData
    }

    func finishIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isFinished { return false }
        isFinished = true
        finalizeSpool()
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

    private func setupSpoolIfNeeded() {
        guard spoolFullOutput else { return }
        do {
            let directory = fullOutputDirectory ?? FileManager.default.temporaryDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let fileURL = directory.appendingPathComponent("skprocessrunner-\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                spoolFailed = true
                return
            }
            spoolFileURL = fileURL
            spoolHandle = try FileHandle(forWritingTo: fileURL)
        } catch {
            spoolFailed = true
            spoolHandle = nil
            spoolFileURL = nil
        }
    }

    private func appendToSpool(_ data: Data) {
        guard spoolFullOutput, !spoolFailed, !data.isEmpty else { return }
        guard let spoolHandle else { return }
        do {
            try spoolHandle.write(contentsOf: data)
        } catch {
            spoolFailed = true
            try? spoolHandle.close()
            self.spoolHandle = nil
            if let spoolFileURL {
                try? FileManager.default.removeItem(at: spoolFileURL)
            }
            self.spoolFileURL = nil
            self.fullOutputPath = nil
        }
    }

    private func finalizeSpool() {
        guard spoolFullOutput else { return }
        if let spoolHandle {
            try? spoolHandle.close()
            self.spoolHandle = nil
        }

        guard !spoolFailed, let spoolFileURL else {
            fullOutputPath = nil
            return
        }

        if truncated {
            fullOutputPath = spoolFileURL.path
        } else {
            try? FileManager.default.removeItem(at: spoolFileURL)
            fullOutputPath = nil
            self.spoolFileURL = nil
        }
    }
}
