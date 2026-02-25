import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if os(macOS)
enum SKProcessTreeTerminator {
    static func terminateProcessTree(rootPID: Int32, gracePeriodMs: Int) {
        guard rootPID > 0 else { return }
        let descendants = descendantPIDs(rootPID: rootPID)
        let targets = Array(Set([rootPID] + descendants)).filter { $0 > 0 }
        guard !targets.isEmpty else { return }

        signal(SIGTERM, to: targets)
        waitForExit(pids: targets, timeoutMs: max(0, gracePeriodMs))

        let survivors = targets.filter(isAlive)
        if !survivors.isEmpty {
            signal(SIGKILL, to: survivors)
        }
    }

    private static func descendantPIDs(rootPID: Int32) -> [Int32] {
        let childrenByParent = processSnapshotChildrenMap()
        var result: [Int32] = []
        var queue: [Int32] = [rootPID]
        var visited = Set<Int32>([rootPID])

        while let current = queue.popLast() {
            guard let children = childrenByParent[current] else { continue }
            for child in children where !visited.contains(child) {
                visited.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    private static func processSnapshotChildrenMap() -> [Int32: [Int32]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return [:]
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var map: [Int32: [Int32]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1])
            else { continue }
            map[ppid, default: []].append(pid)
        }
        return map
    }

    private static func signal(_ signal: Int32, to pids: [Int32]) {
        for pid in pids {
            _ = kill(pid, signal)
        }
    }

    private static func waitForExit(pids: [Int32], timeoutMs: Int) {
        guard timeoutMs > 0 else { return }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if pids.allSatisfy({ !isAlive($0) }) { return }
            usleep(20_000)
        }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
#else
enum SKProcessTreeTerminator {
    static func terminateProcessTree(rootPID: Int32, gracePeriodMs: Int) {
        guard rootPID > 0 else { return }
        _ = kill(rootPID, SIGTERM)
        waitForExit(pid: rootPID, timeoutMs: max(0, gracePeriodMs))
        if isAlive(rootPID) {
            _ = kill(rootPID, SIGKILL)
        }
    }

    private static func waitForExit(pid: Int32, timeoutMs: Int) {
        guard timeoutMs > 0 else { return }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if !isAlive(pid) { return }
            usleep(20_000)
        }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
#endif
