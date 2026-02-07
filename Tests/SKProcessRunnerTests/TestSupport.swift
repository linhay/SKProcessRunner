import Foundation

final class SKProcessLockedString {
    private let lock = NSLock()
    private var value = ""

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        value += String(decoding: data, as: UTF8.self)
    }

    func string() -> String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

struct SKProcessTempDir {
    let url: URL

    init(_ name: String) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.url = base.appendingPathComponent("SKProcessRunnerTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct SKProcessTestFS {
    static func makeExecutable(at url: URL, contents: String) throws {
        try contents.data(using: .utf8)?.write(to: url)
        var attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        attributes[.posixPermissions] = 0o755
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
}

struct SKProcessShellShim {
    static func make(at url: URL, binDir: URL) throws {
        let script = """
        #!/bin/sh
        if [ \"$1\" = \"-lc\" ] || [ \"$1\" = \"-lic\" ]; then shift; fi
        PATH=\"\(binDir.path)\"
        export PATH
        exec /bin/sh -c \"$1\"
        """
        try SKProcessTestFS.makeExecutable(at: url, contents: script)
    }
}

func withSKProcessTempDir<T>(_ name: String, body: (SKProcessTempDir) throws -> T) throws -> T {
    let temp = try SKProcessTempDir(name)
    defer { temp.remove() }
    return try body(temp)
}

func withSKProcessTempDir<T>(_ name: String, body: (SKProcessTempDir) async throws -> T) async throws -> T {
    let temp = try SKProcessTempDir(name)
    defer { temp.remove() }
    return try await body(temp)
}
