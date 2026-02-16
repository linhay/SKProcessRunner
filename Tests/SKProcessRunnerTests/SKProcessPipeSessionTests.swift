import Foundation
import XCTest
@testable import SKProcessRunner

#if os(macOS)
final class SKProcessPipeSessionTests: XCTestCase {
    func testPipeSessionRoundTrip1000JSONLines() async throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "while IFS= read -r line; do printf '%s\\n' \"$line\"; done"])
            .timeoutMs(10_000)

        let session = try SKProcessPipeSession(payload)
        let stdoutTask = Task { () -> Data in
            let stream = await session.stdout
            var output = Data()
            for await chunk in stream {
                output.append(chunk)
            }
            return output
        }

        let lines = (0..<1000).map { #"{"id":\#($0),"op":"ping"}"# }
        for line in lines {
            try await session.send(Data((line + "\n").utf8))
        }
        try await session.closeStdin()

        let result = try await session.wait()
        let stdoutData = await stdoutTask.value

        XCTAssertEqual(result.exitCode, 0)
        let received = String(decoding: stdoutData, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(received.count, 1000)
        XCTAssertEqual(received.first, lines.first)
        XCTAssertEqual(received.last, lines.last)
    }

    func testPipeSessionSeparatesStdoutAndStderr() async throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "echo out; echo err 1>&2"])
            .timeoutMs(3_000)

        let session = try SKProcessPipeSession(payload)
        let stdoutTask = Task { () -> Data in
            let stream = await session.stdout
            var data = Data()
            for await chunk in stream { data.append(chunk) }
            return data
        }
        let stderrTask = Task { () -> Data in
            let stream = await session.stderr
            var data = Data()
            for await chunk in stream { data.append(chunk) }
            return data
        }

        let result = try await session.wait()
        let out = String(decoding: await stdoutTask.value, as: UTF8.self)
        let err = String(decoding: await stderrTask.value, as: UTF8.self)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(out.contains("out"))
        XCTAssertFalse(out.contains("err"))
        XCTAssertTrue(err.contains("err"))
    }

    func testPipeSessionTimeoutThrowsTimedOut() async throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "sleep 30"])
            .timeoutMs(1_000)

        let session = try SKProcessPipeSession(payload)
        let started = Date()
        do {
            _ = try await session.wait()
            XCTFail("Expected timedOut")
        } catch SKProcessRunError.timedOut {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 5)
        }
    }

    func testPipeSessionThrowOnNonZeroExit() async throws {
        let payload = SKProcessPayload.command("/bin/sh")
            .arguments(["-c", "echo boom 1>&2; exit 7"])
            .throwOnNonZeroExit()

        let session = try SKProcessPipeSession(payload)
        do {
            _ = try await session.wait()
            XCTFail("Expected nonZeroExit")
        } catch let SKProcessRunError.nonZeroExit(exitCode, _, stderrData) {
            XCTAssertEqual(exitCode, 7)
            XCTAssertTrue(String(decoding: stderrData, as: UTF8.self).contains("boom"))
        }
    }

    func testPipeSessionLifecycleStressDoesNotCrash() async throws {
        for i in 0..<100 {
            let payload = SKProcessPayload.command("/bin/sh")
                .arguments(["-c", "echo run-\(i); sleep 0.01"])
                .timeoutMs(3_000)

            let session = try SKProcessPipeSession(payload)
            let outputTask = Task { () -> String in
                let stream = await session.stdout
                var data = Data()
                for await chunk in stream { data.append(chunk) }
                return String(decoding: data, as: UTF8.self)
            }

            let result = try await session.wait()
            let output = await outputTask.value
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(output.contains("run-\(i)"))
        }
    }
}
#else
final class SKProcessPipeSessionTests: XCTestCase {
    func testSkippedOnNonMacOS() throws {
        throw XCTSkip("SKProcessPipeSession tests are only supported on macOS.")
    }
}
#endif
