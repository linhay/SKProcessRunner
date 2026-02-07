import Foundation
import XCTest
@testable import SKProcessRunner

final class SKProcessPTYSessionTests: XCTestCase {
    func testPTYSessionEcho() async throws {
#if os(macOS)
        let payload = SKProcessPayload.executableURL(URL(fileURLWithPath: "/bin/sh"))
            .arguments(["-c", "read line; echo $line"])
            .timeoutMs(2_000)
            .maxOutputBytes(64 * 1024)
            .pty(.init(rows: 24, cols: 80))
        let session = try SKProcessPTYSession(payload)

        let outputTask = Task { () -> Data in
            let stream = await session.output
            var data = Data()
            for await chunk in stream {
                data.append(chunk)
            }
            return data
        }

        try await session.resize(rows: 40, cols: 100)
        try await session.send(Data("hello\n".utf8))
        try await session.close()

        let result = try await session.wait()
        let outputData = await outputTask.value

        let output = String(decoding: outputData, as: UTF8.self)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(output.contains("hello"))

        let running = await session.isRunning()
        XCTAssertFalse(running)
        XCTAssertGreaterThan(session.pid, 0)
#else
        throw XCTSkip("SKProcessPTYSession is only supported on macOS in tests.")
#endif
    }
}
