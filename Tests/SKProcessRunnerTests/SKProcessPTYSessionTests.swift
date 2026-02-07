import Foundation
import XCTest
@testable import SKProcessRunner

final class SKPTestTerminalScreen {
    private let rows: Int
    private let cols: Int
    private var buffer: [[Character]]
    private var row: Int = 0
    private var col: Int = 0
    private var savedRow: Int = 0
    private var savedCol: Int = 0
    private var state: SKPTestTerminalState = .normal
    private var csiParams: [Int] = []
    private var csiCurrent = ""
    private var csiPrivate = false
    private var oscPendingEsc = false

    init(rows: Int, cols: Int) {
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        self.buffer = Array(
            repeating: Array(repeating: " ", count: self.cols),
            count: self.rows
        )
    }

    func feed(_ data: Data) {
        for byte in data {
            process(byte)
        }
    }

    func renderedText() -> String {
        buffer.map { String($0) }.joined(separator: "\n")
    }

    private func process(_ byte: UInt8) {
        switch state {
        case .normal:
            handleNormal(byte)
        case .escape:
            handleEscape(byte)
        case .csi:
            handleCsi(byte)
        case .osc:
            handleOsc(byte)
        }
    }

    private func handleNormal(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            state = .escape
        case 0x0D:
            col = 0
        case 0x0A:
            row = min(row + 1, rows - 1)
        case 0x08:
            col = max(col - 1, 0)
        case 0x09:
            let nextTab = ((col / 8) + 1) * 8
            col = min(nextTab, cols - 1)
        default:
            if byte >= 0x20 && byte != 0x7F {
                let scalar = UnicodeScalar(byte)
                buffer[row][col] = Character(scalar)
                col += 1
                if col >= cols {
                    col = 0
                    row = min(row + 1, rows - 1)
                }
            }
        }
    }

    private func handleEscape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "["):
            state = .csi
            csiParams = []
            csiCurrent = ""
            csiPrivate = false
        case UInt8(ascii: "]"):
            state = .osc
            oscPendingEsc = false
        case UInt8(ascii: "7"):
            savedRow = row
            savedCol = col
            state = .normal
        case UInt8(ascii: "8"):
            row = min(max(savedRow, 0), rows - 1)
            col = min(max(savedCol, 0), cols - 1)
            state = .normal
        default:
            state = .normal
        }
    }

    private func handleOsc(_ byte: UInt8) {
        if oscPendingEsc {
            oscPendingEsc = false
            if byte == UInt8(ascii: "\\") {
                state = .normal
                return
            }
        }
        if byte == 0x07 {
            state = .normal
            return
        }
        if byte == 0x1B {
            oscPendingEsc = true
        }
    }

    private func handleCsi(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "?"), UInt8(ascii: ">"):
            csiPrivate = true
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            csiCurrent.append(Character(UnicodeScalar(byte)))
        case UInt8(ascii: ";"):
            finalizeCsiParam()
        default:
            finalizeCsiParam()
            applyCsi(final: byte)
            state = .normal
        }
    }

    private func finalizeCsiParam() {
        if csiCurrent.isEmpty {
            csiParams.append(0)
        } else {
            csiParams.append(Int(csiCurrent) ?? 0)
            csiCurrent = ""
        }
    }

    private func applyCsi(final: UInt8) {
        let params = csiParams.isEmpty ? [0] : csiParams
        switch final {
        case UInt8(ascii: "A"):
            let n = params[0] == 0 ? 1 : params[0]
            row = max(row - n, 0)
        case UInt8(ascii: "B"):
            let n = params[0] == 0 ? 1 : params[0]
            row = min(row + n, rows - 1)
        case UInt8(ascii: "C"):
            let n = params[0] == 0 ? 1 : params[0]
            col = min(col + n, cols - 1)
        case UInt8(ascii: "D"):
            let n = params[0] == 0 ? 1 : params[0]
            col = max(col - n, 0)
        case UInt8(ascii: "G"):
            let n = params[0] == 0 ? 1 : params[0]
            col = min(max(n - 1, 0), cols - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            let r = params.count >= 1 ? params[0] : 1
            let c = params.count >= 2 ? params[1] : 1
            row = min(max(r - 1, 0), rows - 1)
            col = min(max(c - 1, 0), cols - 1)
        case UInt8(ascii: "J"):
            let mode = params[0]
            if mode == 2 || mode == 3 {
                clearScreen()
            }
        case UInt8(ascii: "K"):
            let mode = params[0]
            if mode == 0 || mode == 2 {
                clearLine()
            }
        case UInt8(ascii: "m"):
            break
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            if csiPrivate, params.contains(1049) {
                clearScreen()
            }
        default:
            break
        }
    }

    private func clearScreen() {
        for r in 0..<rows {
            for c in 0..<cols {
                buffer[r][c] = " "
            }
        }
        row = 0
        col = 0
    }

    private func clearLine() {
        for c in col..<cols {
            buffer[row][c] = " "
        }
    }
}

enum SKPTestTerminalState {
    case normal
    case escape
    case csi
    case osc
}

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

    func testPTYSessionCodex() async throws {
#if os(macOS)
        let whichPayload = SKProcessPayload.executableURL(URL(fileURLWithPath: "/usr/bin/which"))
            .arguments(["codex"])
            .timeoutMs(1_000)
            .maxOutputBytes(8 * 1024)
        do {
            _ = try SKProcessRunner.runSync(whichPayload)
        } catch {
            throw XCTSkip("Codex CLI not found in PATH.")
        }

        let env = SKProcessEnvironment.current()
            .merging(["TERM": "xterm-256color", "COLORTERM": "truecolor"])
        let payload = SKProcessPayload.executableURL(URL(fileURLWithPath: "/usr/bin/env"))
            .arguments([
                "codex",
                "-c", "model=\"\"",
                "-c", "model_reasoning_effort=medium",
                "-c", "mcp_servers.figma.enabled=false",
                "-c", "mcp_servers.uiagent.enabled=false"
            ])
            .environment(env)
            .timeoutMs(30_000)
            .maxOutputBytes(256 * 1024)
            .pty(.init(rows: 24, cols: 80))
        let session = try SKProcessPTYSession(payload)

        let stream = await session.output
        var output = Data()
        let screen = SKPTestTerminalScreen(rows: 24, cols: 80)
        var hasModelList = false
        var sentExit = false
        var sentModelAttempts = 0
        var lastModelSend = Date.distantPast
        var sawModelDisabledMessage = false
        var sawReadyModel = false
        var sawPrompt = false
        let start = Date()
        let deadline = Date().addingTimeInterval(45)
        var handledCursorQueryCount = 0

        for await chunk in stream {
            output.append(chunk)
            screen.feed(chunk)
            let current = String(decoding: output, as: UTF8.self)
            let clean = stripANSI(current)
            let screenText = screen.renderedText()
            if handledCursorQueryCount < 3 {
                if outputContainsCursorPositionQuery(output) {
                    handledCursorQueryCount += 1
                    let response = "\u{1B}[24;80R"
                    do {
                        try await session.send(Data(response.utf8))
                    } catch {
                        let message = String(describing: error)
                        if !message.contains("errno 5") {
                            throw error
                        }
                    }
                }
            }
            if clean.contains("Model selection is disabled until startup completes.") {
                sawModelDisabledMessage = true
            }

            let modelReady: Bool = {
                let lower = clean.lowercased()
                if let range = lower.range(of: "model:") {
                    let tail = lower[range.upperBound...]
                    return !tail.contains("loading")
                }
                return false
            }()
            if modelReady { sawReadyModel = true }
            if clean.contains("›") {
                sawPrompt = true
            }

            if (sawReadyModel || (sawModelDisabledMessage && modelReady) || Date().timeIntervalSince(start) > 3.0)
                && (sawPrompt || Date().timeIntervalSince(start) > 3.0) {
                if sentModelAttempts < 6, Date().timeIntervalSince(lastModelSend) > 2.0 {
                    sentModelAttempts += 1
                    lastModelSend = Date()
                    sawPrompt = false
                    do {
                        print("Codex /model send attempt \(sentModelAttempts)")
                        let clearAndModel = "\u{15}/model\r"
                        try await session.send(Data(clearAndModel.utf8))
                    } catch {
                        let message = String(describing: error)
                        if !message.contains("errno 5") {
                            throw error
                        }
                    }
                }
            }
            if !hasModelList {
                if clean.contains("Select Model and Effort") || screenText.contains("Select Model and Effort") {
                    hasModelList = true
                } else if clean.contains("1. gpt-") || clean.contains("2. gpt-") {
                    hasModelList = true
                } else if clean.contains("1. o1") || clean.contains("2. o1") {
                    hasModelList = true
                } else if screenText.contains("1. gpt-") || screenText.contains("2. gpt-") {
                    hasModelList = true
                }
            }
            if hasModelList, !sentExit {
                sentExit = true
                do {
                    try await session.send(Data("/exit\r".utf8))
                } catch {
                    let message = String(describing: error)
                    if message.contains("errno 5") {
                        // PTY can close quickly after listing models; ignore EIO.
                    } else {
                        throw error
                    }
                }
            }
            if !hasModelList, Date() >= deadline {
                await session.terminate()
                break
            }
        }

        var finalOutput = output
        var didTimeout = false
        do {
            _ = try await session.wait()
        } catch let SKProcessRunError.timedOut(_, stdoutData, _, _) {
            finalOutput = stdoutData
            didTimeout = true
        }
        let outputString = String(decoding: finalOutput, as: UTF8.self)
        let cleanOutput = stripANSI(outputString)
        let screenText = screen.renderedText()
        let combinedText = "\(cleanOutput)\n\(screenText)"

        let sample = String(combinedText.prefix(2000))
        print("Codex /model output (combined prefix):\n\(sample)")
        let attachment = XCTAttachment(string: sample)
        attachment.name = "Codex /model output (combined prefix)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let requiredModels = [
            "gpt-5.2-codex",
            "gpt-5.1-codex-max",
            "gpt-5.2",
            "gpt-5.1-codex-mini"
        ]
        let hasModelListFinal = combinedText.contains("Select Model and Effort")
            || combinedText.contains("1. gpt-")
            || combinedText.contains("2. gpt-")

        XCTAssertTrue(hasModelListFinal, "Expected /model list output. Output: \(combinedText.prefix(2000))")

        let missing = requiredModels.filter { !combinedText.contains($0) }
        XCTAssertTrue(missing.isEmpty, "Missing models: \(missing.joined(separator: ", ")). Output: \(combinedText.prefix(2000))")
        XCTAssertFalse(finalOutput.isEmpty)
        _ = didTimeout
#else
        throw XCTSkip("SKProcessPTYSession is only supported on macOS in tests.")
#endif
    }

    private func outputContainsCursorPositionQuery(_ data: Data) -> Bool {
        let bytes = [UInt8](data.suffix(4096))
        if bytes.count < 4 { return false }
        let pattern: [UInt8] = [0x1b, 0x5b, 0x36, 0x6e] // ESC [ 6 n
        for i in 0...(bytes.count - pattern.count) {
            if bytes[i] == pattern[0],
               bytes[i + 1] == pattern[1],
               bytes[i + 2] == pattern[2],
               bytes[i + 3] == pattern[3] {
                return true
            }
        }
        return false
    }

    private func stripANSI(_ input: String) -> String {
        var output = ""
        var iterator = input.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                guard let next = iterator.next() else { break }
                if next == "[" {
                    // CSI: skip until byte in @-~
                    while let c = iterator.next() {
                        let v = c.value
                        if v >= 0x40 && v <= 0x7E { break }
                    }
                } else if next == "]" {
                    // OSC: skip until BEL or ESC \
                    var prevWasEsc = false
                    while let c = iterator.next() {
                        if prevWasEsc, c == "\\" { break }
                        if c == "\u{07}" { break }
                        prevWasEsc = (c == "\u{1B}")
                    }
                }
                continue
            }
            output.unicodeScalars.append(scalar)
        }
        return output
    }
}
