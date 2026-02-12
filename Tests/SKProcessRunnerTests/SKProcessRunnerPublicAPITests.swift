import Foundation
import XCTest
@testable import SKProcessRunner
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if os(macOS)
final class SKProcessRunnerPublicAPITests: XCTestCase {
    func testResolveExecutableWithPath() throws {
        let url = try SKProcessRunner.resolveExecutable("/bin/echo")
        XCTAssertEqual(url.path, "/bin/echo")
    }

    func testResolveExecutableInvalid() {
        XCTAssertThrowsError(try SKProcessRunner.resolveExecutable("  ")) { error in
            guard case SKProcessRunError.invalidExecutable = error else {
                XCTFail("Expected invalidExecutable, got: \(error)")
                return
            }
        }
    }

    func testResolveExecutableInPath() {
        let env = ["PATH": "/bin:/usr/bin"]
        let url = SKProcessRunner.resolveExecutableInPath(named: "ls", environment: env)
        XCTAssertNotNil(url)
    }

    func testLoadUserShellPATHSync() {
        let value = SKProcessRunner.loadUserShellPATHSync()
        XCTAssertNotNil(value)
        XCTAssertFalse(value?.isEmpty ?? true)
    }

    func testLoadUserShellEnvironmentSync() {
        let env = SKProcessRunner.loadUserShellEnvironmentSync()
        XCTAssertFalse(env.isEmpty)
        XCTAssertNotNil(env["PATH"])
    }

    func testResolveExecutableInUserShellSync() throws {
        try withSKProcessTempDir("shell-sync") { temp in
            let binDir = temp.url.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            let cmd = binDir.appendingPathComponent("skp_test_cmd")
            try SKProcessTestFS.makeExecutable(at: cmd, contents: "#!/bin/sh\necho ok\n")

            let shim = temp.url.appendingPathComponent("shim")
            try SKProcessShellShim.make(at: shim, binDir: binDir)

            let url = SKProcessRunner.resolveExecutableInUserShellSync(
                named: "skp_test_cmd",
                shellPath: shim.path,
                mode: .login,
                timeoutMs: 1_000
            )
            XCTAssertEqual(url?.path, cmd.path)
        }
    }

    func testResolveExecutableInUserShellAsync() async throws {
        try await withSKProcessTempDir("shell-async") { temp in
            let binDir = temp.url.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            let cmd = binDir.appendingPathComponent("skp_test_cmd")
            try SKProcessTestFS.makeExecutable(at: cmd, contents: "#!/bin/sh\necho ok\n")

            let shim = temp.url.appendingPathComponent("shim")
            try SKProcessShellShim.make(at: shim, binDir: binDir)

            let url = await SKProcessRunner.resolveExecutableInUserShell(
                named: "skp_test_cmd",
                shellPath: shim.path,
                mode: .login,
                timeoutMs: 1_000
            )
            XCTAssertEqual(url?.path, cmd.path)
        }
    }

    func testRunAsyncCapturesStdoutStderr() async throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "echo out; echo err 1>&2"])

        let stdout = SKProcessLockedString()
        let stderr = SKProcessLockedString()
        let result = try await SKProcessRunner.run(
            payload,
            onStdout: { data in stdout.append(data) },
            onStderr: { data in stderr.append(data) }
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("out"))
        XCTAssertTrue(result.stderr.contains("err"))
        XCTAssertTrue(stdout.string().contains("out"))
        XCTAssertTrue(stderr.string().contains("err"))
    }

    func testRunSyncCapturesStdoutStderr() throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "echo out; echo err 1>&2"])

        let result = try SKProcessRunner.runSync(
            payload,
            onStdout: { _ in },
            onStderr: { _ in }
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("out"))
        XCTAssertTrue(result.stderr.contains("err"))
    }

    func testRunAsyncWithStdin() async throws {
        let payload = SKProcessPayload.command("/bin/cat")
            .stdin("hello")

        let result = try await SKProcessRunner.run(payload)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello")
    }

    func testRunSyncWithStdin() throws {
        let payload = SKProcessPayload.command("/bin/cat")
            .stdin("hello")

        let result = try SKProcessRunner.runSync(payload)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello")
    }

    func testRunAsyncThrowsOnNonZeroExit() async {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "exit 2"])
            .throwOnNonZeroExit()

        do {
            _ = try await SKProcessRunner.run(payload)
            XCTFail("Expected nonZeroExit error")
        } catch let SKProcessRunError.nonZeroExit(exitCode, _, _) {
            XCTAssertEqual(exitCode, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunSyncThrowsOnNonZeroExit() {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "exit 3"])
            .throwOnNonZeroExit()

        do {
            _ = try SKProcessRunner.runSync(payload)
            XCTFail("Expected nonZeroExit error")
        } catch let SKProcessRunError.nonZeroExit(exitCode, _, _) {
            XCTAssertEqual(exitCode, 3)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunAsyncTimeout() async {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "sleep 2"])
            .timeoutMs(1_000)

        do {
            _ = try await SKProcessRunner.run(payload)
            XCTFail("Expected timedOut error")
        } catch let SKProcessRunError.timedOut(timeoutMs, _, _, _) {
            XCTAssertEqual(timeoutMs, 1_000)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunSyncTimeout() {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "sleep 2"])
            .timeoutMs(1_000)

        do {
            _ = try SKProcessRunner.runSync(payload)
            XCTFail("Expected timedOut error")
        } catch let SKProcessRunError.timedOut(timeoutMs, _, _, _) {
            XCTAssertEqual(timeoutMs, 1_000)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunSyncTimeoutTerminatesChildProcessTree() throws {
        try withSKProcessTempDir("timeout-tree-sync") { temp in
            let pidFile = temp.url.appendingPathComponent("child.pid")
            let command = "sh -c 'trap \"\" TERM; sleep 30' & child=$!; echo $child > '\(pidFile.path)'; wait $child"

            let payload = SKProcessPayload.command("/bin/sh")
                .arguments(["-c", command])
                .timeoutMs(1_000)

            let startedAt = Date()
            do {
                _ = try SKProcessRunner.runSync(payload)
                XCTFail("Expected timedOut error")
            } catch SKProcessRunError.timedOut {
                // expected
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            XCTAssertLessThan(elapsed, 5, "Timeout path should return quickly without waiting for orphan descendants")

            let childPID = try waitAndReadPID(from: pidFile)
            defer { _ = kill(childPID, SIGKILL) }

            usleep(300_000)
            XCTAssertFalse(isProcessAlive(childPID), "Expected child process to be terminated after timeout")
        }
    }

    func testRunAsyncTimeoutTerminatesChildProcessTree() async throws {
        try await withSKProcessTempDir("timeout-tree-async") { temp in
            let pidFile = temp.url.appendingPathComponent("child.pid")
            let command = "sh -c 'trap \"\" TERM; sleep 30' & child=$!; echo $child > '\(pidFile.path)'; wait $child"

            let payload = SKProcessPayload.command("/bin/sh")
                .arguments(["-c", command])
                .timeoutMs(1_000)

            let startedAt = Date()
            do {
                _ = try await SKProcessRunner.run(payload)
                XCTFail("Expected timedOut error")
            } catch SKProcessRunError.timedOut {
                // expected
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            XCTAssertLessThan(elapsed, 5, "Async timeout path should return quickly without waiting for orphan descendants")

            let childPID = try waitAndReadPID(from: pidFile)
            defer { _ = kill(childPID, SIGKILL) }

            usleep(300_000)
            XCTAssertFalse(isProcessAlive(childPID), "Expected child process to be terminated after async timeout")
        }
    }

    func testRunAsyncOutputTruncation() async throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "yes a | head -c 10000"])
            .maxOutputBytes(8 * 1024)

        let result = try await SKProcessRunner.run(payload)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.stdoutData.count, 8 * 1024)
    }

    func testRunSyncOutputTruncation() throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "yes a | head -c 10000"])
            .maxOutputBytes(8 * 1024)

        let result = try SKProcessRunner.runSync(payload)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.stdoutData.count, 8 * 1024)
    }

    func testRunSyncOutputSpoolReturnsPathWhenTruncated() throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "yes a | head -c 10000"])
            .maxOutputBytes(8 * 1024)
            .spoolFullOutput()

        let result = try SKProcessRunner.runSync(payload)
        XCTAssertTrue(result.truncated)
        XCTAssertNotNil(result.fullOutputPath)

        guard let fullOutputPath = result.fullOutputPath else { return XCTFail("Expected full output path") }
        defer { try? FileManager.default.removeItem(atPath: fullOutputPath) }

        let fullData = try Data(contentsOf: URL(fileURLWithPath: fullOutputPath))
        XCTAssertGreaterThan(fullData.count, result.stdoutData.count)
    }

    func testRunSyncOutputSpoolDoesNotReturnPathWhenNotTruncated() throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "echo hello"])
            .maxOutputBytes(8 * 1024)
            .spoolFullOutput()

        let result = try SKProcessRunner.runSync(payload)
        XCTAssertFalse(result.truncated)
        XCTAssertNil(result.fullOutputPath)
    }

    func testRunSyncOutputSpoolWriteFailureFallsBackGracefully() throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "yes a | head -c 10000"])
            .maxOutputBytes(8 * 1024)
            .spoolFullOutput(directory: URL(fileURLWithPath: "/dev/null"))

        let result = try SKProcessRunner.runSync(payload)
        XCTAssertTrue(result.truncated)
        XCTAssertNil(result.fullOutputPath)
    }

    func testRunPTYAsyncMergesOutput() async throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "echo out; echo err 1>&2"])
            .pty(.init())

        let result = try await SKProcessRunner.runPTY(payload)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("out"))
        XCTAssertTrue(result.stdout.contains("err"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testRunPTYSyncMergesOutput() throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "echo out; echo err 1>&2"])
            .pty(.init())

        let result = try SKProcessRunner.runPTYSync(payload)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("out"))
        XCTAssertTrue(result.stdout.contains("err"))
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testRunPTYAsyncTimeout() async {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "sleep 2"])
            .timeoutMs(1_000)
            .pty(.init())

        do {
            _ = try await SKProcessRunner.runPTY(payload)
            XCTFail("Expected timedOut error")
        } catch let SKProcessRunError.timedOut(timeoutMs, _, _, _) {
            XCTAssertEqual(timeoutMs, 1_000)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunPTYSyncTimeout() {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "sleep 2"])
            .timeoutMs(1_000)
            .pty(.init())

        do {
            _ = try SKProcessRunner.runPTYSync(payload)
            XCTFail("Expected timedOut error")
        } catch let SKProcessRunError.timedOut(timeoutMs, _, _, _) {
            XCTAssertEqual(timeoutMs, 1_000)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunPTYAsyncNonZeroExit() async {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "exit 7"])
            .throwOnNonZeroExit()
            .pty(.init())

        do {
            _ = try await SKProcessRunner.runPTY(payload)
            XCTFail("Expected nonZeroExit error")
        } catch let SKProcessRunError.nonZeroExit(exitCode, _, _) {
            XCTAssertEqual(exitCode, 7)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunPTYSyncNonZeroExit() {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "exit 9"])
            .throwOnNonZeroExit()
            .pty(.init())

        do {
            _ = try SKProcessRunner.runPTYSync(payload)
            XCTFail("Expected nonZeroExit error")
        } catch let SKProcessRunError.nonZeroExit(exitCode, _, _) {
            XCTAssertEqual(exitCode, 9)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPayloadBuilderMutations() {
        let payload = SKProcessPayload.command("/bin/echo")
            .argument("hello")
            .arguments(["world"])
            .cwd(URL(fileURLWithPath: "/tmp"))
            .environment(.current())
            .useUserShellEnvironment(true)
            .timeoutMs(2_500)
            .maxOutputBytes(128 * 1024)
            .terminationGracePeriodMs(750)
            .throwOnNonZeroExit()
            .pty(.init(rows: 10, cols: 20))

        XCTAssertEqual(payload.arguments, ["world"])
        XCTAssertEqual(payload.cwd?.path, "/tmp")
        XCTAssertNotNil(payload.environment)
        XCTAssertTrue(payload.useUserShellEnvironment)
        XCTAssertEqual(payload.timeoutMs, 2_500)
        XCTAssertEqual(payload.maxOutputBytes, 128 * 1024)
        XCTAssertEqual(payload.terminationGracePeriodMs, 750)
        XCTAssertTrue(payload.throwOnNonZeroExit)
        XCTAssertEqual(payload.pty?.rows, 10)
        XCTAssertEqual(payload.pty?.cols, 20)
    }

    func testEnvironmentMerge() {
        let base = SKProcessEnvironment(["A": "1"])
        let merged = base.merging(["B": "2"])
        XCTAssertEqual(merged.values["A"], "1")
        XCTAssertEqual(merged.values["B"], "2")
    }

    func testResultConvenienceInit() {
        let result = SKProcessResult(stdout: "out", stderr: "err", exitCode: 1, timedOut: false, truncated: false)
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.exitCode, 1)
    }

    private func waitAndReadPID(from fileURL: URL, timeoutMs: Int = 1_500) throws -> pid_t {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let text = try? String(contentsOf: fileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(text),
               pid > 0 {
                return pid
            }
            usleep(20_000)
        }
        throw XCTSkip("PID file was not produced in time: \(fileURL.path)")
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
#else
final class SKProcessRunnerPublicAPITests: XCTestCase {
    func testSkippedOnNonMacOS() throws {
        throw XCTSkip("SKProcessRunner public API tests are only supported on macOS.")
    }
}
#endif
