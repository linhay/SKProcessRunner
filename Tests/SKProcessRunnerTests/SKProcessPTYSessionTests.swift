import Foundation
import XCTest
@testable import SKProcessRunner

final class SKPTestTerminalScreen {
    private let rows: Int
    private let cols: Int
    private var buffer: [[Character]]
    private var row: Int = 0
    private var col: Int = 0
    private var scrollTop: Int = 0
    private var scrollBottom: Int
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
        self.scrollBottom = self.rows - 1
        self.buffer = Array(
            repeating: Array(repeating: " ", count: self.cols),
            count: self.rows
        )
    }

    func feed(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        for scalar in text.unicodeScalars {
            process(scalar)
        }
    }

    func renderedText() -> String {
        buffer.map { String($0) }.joined(separator: "\n")
    }

    private func process(_ scalar: UnicodeScalar) {
        switch state {
        case .normal:
            handleNormal(scalar)
        case .escape:
            handleEscape(scalar)
        case .csi:
            handleCsi(scalar)
        case .osc:
            handleOsc(scalar)
        }
    }

    private func handleNormal(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x1B:
            state = .escape
        case 0x0D:
            col = 0
        case 0x0A:
            if row == scrollBottom {
                scrollUp(1)
            } else {
                row = min(row + 1, rows - 1)
            }
            col = 0
        case 0x08:
            col = max(col - 1, 0)
        case 0x09:
            let nextTab = ((col / 8) + 1) * 8
            col = min(nextTab, cols - 1)
        default:
            if scalar.value >= 0x20 && scalar.value != 0x7F {
                buffer[row][col] = Character(scalar)
                col += 1
                if col >= cols {
                    col = 0
                    row = min(row + 1, rows - 1)
                }
            }
        }
    }

    private func handleEscape(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x5B: // [
            state = .csi
            csiParams = []
            csiCurrent = ""
            csiPrivate = false
        case 0x5D: // ]
            state = .osc
            oscPendingEsc = false
        case 0x37: // 7
            savedRow = row
            savedCol = col
            state = .normal
        case 0x38: // 8
            row = min(max(savedRow, 0), rows - 1)
            col = min(max(savedCol, 0), cols - 1)
            state = .normal
        default:
            state = .normal
        }
    }

    private func handleOsc(_ scalar: UnicodeScalar) {
        if oscPendingEsc {
            oscPendingEsc = false
            if scalar.value == 0x5C { // \
                state = .normal
                return
            }
        }
        if scalar.value == 0x07 {
            state = .normal
            return
        }
        if scalar.value == 0x1B {
            oscPendingEsc = true
        }
    }

    private func handleCsi(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x3F, 0x3E: // ? >
            csiPrivate = true
        case 0x30...0x39:
            csiCurrent.append(Character(scalar))
        case 0x3B: // ;
            finalizeCsiParam()
        default:
            finalizeCsiParam()
            applyCsi(final: scalar.value)
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

    private func applyCsi(final: UInt32) {
        let params = csiParams.isEmpty ? [0] : csiParams
        switch final {
        case 0x41: // A
            let n = params[0] == 0 ? 1 : params[0]
            row = max(row - n, 0)
        case 0x42: // B
            let n = params[0] == 0 ? 1 : params[0]
            row = min(row + n, rows - 1)
        case 0x43: // C
            let n = params[0] == 0 ? 1 : params[0]
            col = min(col + n, cols - 1)
        case 0x44: // D
            let n = params[0] == 0 ? 1 : params[0]
            col = max(col - n, 0)
        case 0x47: // G
            let n = params[0] == 0 ? 1 : params[0]
            col = min(max(n - 1, 0), cols - 1)
        case 0x48, 0x66: // H f
            let r = params.count >= 1 ? params[0] : 1
            let c = params.count >= 2 ? params[1] : 1
            row = min(max(r - 1, 0), rows - 1)
            col = min(max(c - 1, 0), cols - 1)
        case 0x4A: // J
            let mode = params[0]
            if mode == 0 {
                clearFromCursor()
            } else if mode == 1 {
                clearToCursor()
            } else if mode == 2 || mode == 3 {
                clearScreen()
            }
        case 0x4B: // K
            let mode = params[0]
            if mode == 0 {
                clearLine()
            } else if mode == 1 {
                clearLineToCursor()
            } else if mode == 2 {
                clearLineAll()
            }
        case 0x6D: // m
            break
        case 0x73: // s
            savedRow = row
            savedCol = col
        case 0x75: // u
            row = min(max(savedRow, 0), rows - 1)
            col = min(max(savedCol, 0), cols - 1)
        case 0x50: // P
            let n = params[0] == 0 ? 1 : params[0]
            deleteChars(n)
        case 0x58: // X
            let n = params[0] == 0 ? 1 : params[0]
            eraseChars(n)
        case 0x40: // @
            let n = params[0] == 0 ? 1 : params[0]
            insertChars(n)
        case 0x4C: // L
            let n = params[0] == 0 ? 1 : params[0]
            insertLines(n)
        case 0x4D: // M
            let n = params[0] == 0 ? 1 : params[0]
            deleteLines(n)
        case 0x53: // S
            let n = params[0] == 0 ? 1 : params[0]
            scrollUp(n)
        case 0x54: // T
            let n = params[0] == 0 ? 1 : params[0]
            scrollDown(n)
        case 0x72: // r
            let top = params.count >= 1 ? params[0] : 1
            let bottom = params.count >= 2 ? params[1] : rows
            scrollTop = min(max(top - 1, 0), rows - 1)
            scrollBottom = min(max(bottom - 1, scrollTop), rows - 1)
            row = scrollTop
            col = 0
        case 0x68, 0x6C: // h l
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

    private func clearLineToCursor() {
        guard row >= 0 && row < rows else { return }
        for c in 0...min(col, cols - 1) {
            buffer[row][c] = " "
        }
    }

    private func clearLineAll() {
        guard row >= 0 && row < rows else { return }
        for c in 0..<cols {
            buffer[row][c] = " "
        }
    }

    private func clearFromCursor() {
        clearLine()
        if row + 1 <= rows - 1 {
            for r in (row + 1)..<rows {
                for c in 0..<cols {
                    buffer[r][c] = " "
                }
            }
        }
    }

    private func clearToCursor() {
        if row > 0 {
            for r in 0..<row {
                for c in 0..<cols {
                    buffer[r][c] = " "
                }
            }
        }
        clearLineToCursor()
    }

    private func deleteChars(_ n: Int) {
        guard row >= 0 && row < rows else { return }
        let count = min(max(n, 0), cols - col)
        if count == 0 { return }
        for c in col..<(cols - count) {
            buffer[row][c] = buffer[row][c + count]
        }
        for c in (cols - count)..<cols {
            buffer[row][c] = " "
        }
    }

    private func eraseChars(_ n: Int) {
        guard row >= 0 && row < rows else { return }
        let count = min(max(n, 0), cols - col)
        if count == 0 { return }
        for c in col..<(col + count) {
            buffer[row][c] = " "
        }
    }

    private func insertChars(_ n: Int) {
        guard row >= 0 && row < rows else { return }
        let count = min(max(n, 0), cols - col)
        if count == 0 { return }
        for c in stride(from: cols - 1, through: col + count, by: -1) {
            buffer[row][c] = buffer[row][c - count]
        }
        for c in col..<(col + count) {
            buffer[row][c] = " "
        }
    }

    private func insertLines(_ n: Int) {
        let count = min(max(n, 0), scrollBottom - row + 1)
        if count == 0 { return }
        for r in stride(from: scrollBottom, through: row + count, by: -1) {
            buffer[r] = buffer[r - count]
        }
        for r in row..<(row + count) {
            buffer[r] = Array(repeating: " ", count: cols)
        }
    }

    private func deleteLines(_ n: Int) {
        let count = min(max(n, 0), scrollBottom - row + 1)
        if count == 0 { return }
        for r in row...(scrollBottom - count) {
            buffer[r] = buffer[r + count]
        }
        for r in (scrollBottom - count + 1)...scrollBottom {
            buffer[r] = Array(repeating: " ", count: cols)
        }
    }

    private func scrollUp(_ n: Int) {
        let count = min(max(n, 0), scrollBottom - scrollTop + 1)
        if count == 0 { return }
        for r in scrollTop...(scrollBottom - count) {
            buffer[r] = buffer[r + count]
        }
        for r in (scrollBottom - count + 1)...scrollBottom {
            buffer[r] = Array(repeating: " ", count: cols)
        }
    }

    private func scrollDown(_ n: Int) {
        let count = min(max(n, 0), scrollBottom - scrollTop + 1)
        if count == 0 { return }
        for r in stride(from: scrollBottom, through: scrollTop + count, by: -1) {
            buffer[r] = buffer[r - count]
        }
        for r in scrollTop..<(scrollTop + count) {
            buffer[r] = Array(repeating: " ", count: cols)
        }
    }
}

enum SKPTestTerminalState {
    case normal
    case escape
    case csi
    case osc
}

final class SKPTestFlag {
    private let lock = NSLock()
    private var value = false

    func setTrue() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    func isTrue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
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
        guard let codexURL = SKProcessRunner.resolveExecutableInUserShellSync(named: "codex") else {
            throw XCTSkip("Codex CLI not found in user shell PATH.")
        }

        let env = SKProcessEnvironment
            .current()
            .merging(.userShell())
            .merging([
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8"
            ])
        let cwd = resolveTestCWD(env: env)
        let payload = SKProcessPayload.executableURL(codexURL)
            .arguments([
                "-c", "model=\"\"",
                "-c", "model_reasoning_effort=medium",
                "-c", "mcp_servers.figma.enabled=false",
                "-c", "mcp_servers.uiagent.enabled=false"
            ])
            .cwd(cwd)
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
        var sentModel = false
        let hasModelListFlag = SKPTestFlag()
        var retryTask: Task<Void, Never>? = nil
        var sawModelDisabledMessage = false
        var sawReadyModel = false
        var sawPrompt = false
        let start = Date()
        let deadline = Date().addingTimeInterval(45)
        var handledCursorQueryCount = 0
        var lastScreenText = ""
        var lastScreenChange = Date()

        for await chunk in stream {
            output.append(chunk)
            screen.feed(chunk)
            let current = String(decoding: output, as: UTF8.self)
            let clean = stripANSI(current)
            let screenText = screen.renderedText()
            if screenText != lastScreenText {
                lastScreenText = screenText
                lastScreenChange = Date()
            }
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

            if !sentModel,
               (sawReadyModel || (sawModelDisabledMessage && modelReady) || Date().timeIntervalSince(start) > 5.0),
               sawPrompt,
               (Date().timeIntervalSince(lastScreenChange) >= 0.8 || Date().timeIntervalSince(start) > 5.0) {
                sentModel = true
                sawPrompt = false
                do {
                    print("Codex /model send")
                    let clearAndModel = "\u{15}/model\r"
                    try await session.send(Data(clearAndModel.utf8))
                } catch {
                    let message = String(describing: error)
                    if !message.contains("errno 5") {
                        throw error
                    }
                }
                retryTask?.cancel()
                retryTask = Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if hasModelListFlag.isTrue() { return }
                    do {
                        print("Codex /model retry")
                        let clearAndModel = "\u{15}/model\r"
                        try await session.send(Data(clearAndModel.utf8))
                    } catch {
                        let message = String(describing: error)
                        if !message.contains("errno 5") {
                            return
                        }
                    }
                }
            }
            if !hasModelList {
                if clean.contains("Select Model and Effort") || screenText.contains("Select Model and Effort") {
                    hasModelList = true
                    hasModelListFlag.setTrue()
                } else if clean.contains("1. gpt-") || clean.contains("2. gpt-") {
                    hasModelList = true
                    hasModelListFlag.setTrue()
                } else if clean.contains("1. o1") || clean.contains("2. o1") {
                    hasModelList = true
                    hasModelListFlag.setTrue()
                } else if screenText.contains("1. gpt-") || screenText.contains("2. gpt-") {
                    hasModelList = true
                    hasModelListFlag.setTrue()
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

        retryTask?.cancel()
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

        let sample = String(screenText.prefix(2000))
        print("Codex /model output (screen prefix):\n\(sample)")
        let attachment = XCTAttachment(string: sample)
        attachment.name = "Codex /model output (screen prefix)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let combined = cleanOutput + "\n" + screenText
        let hasModelListFinal = combined.contains("Select Model and Effort")
            || combined.contains("1. gpt-")
            || combined.contains("2. gpt-")

        let normalizedOutput = normalizeCodexOutput(cleanOutput)
        XCTAssertTrue(hasModelListFinal, "Expected /model list output. Output: \(normalizedOutput.prefix(2000))")

        let requiredModels = [
            "gpt-5.2-codex",
            "gpt-5.1-codex-max",
            "gpt-5.2",
            "gpt-5.1-codex-mini"
        ]
        let missing = requiredModels.filter { !combined.contains($0) }
        XCTAssertTrue(missing.isEmpty, "Missing models: \(missing.joined(separator: ", ")). Output: \(normalizedOutput.prefix(2000))")

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

    private func normalizeCodexOutput(_ input: String) -> String {
        var text = input
        let markers = [
            "Select Model and Effort",
            "Select Reasoning Level",
            "Press enter",
            "Tip:"
        ]
        for marker in markers {
            text = text.replacingOccurrences(of: marker, with: "\n" + marker)
        }
        text = replaceRegex(text, pattern: "(?<!\\n)(?<=\\s)(\\d+)\\.", replacement: "\n$1.")
        text = replaceRegex(text, pattern: "\\.(gpt-)", replacement: ". $1")
        return text
    }

    private func replaceRegex(_ input: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
    }

    private func resolveTestCWD(env: SKProcessEnvironment) -> URL? {
        let values = env.values
        if let srcRoot = values["SRCROOT"], !srcRoot.isEmpty {
            return URL(fileURLWithPath: srcRoot)
        }
        if let projectDir = values["PROJECT_DIR"], !projectDir.isEmpty {
            return URL(fileURLWithPath: projectDir)
        }
        if let pwd = values["PWD"], !pwd.isEmpty {
            return URL(fileURLWithPath: pwd)
        }
        let current = FileManager.default.currentDirectoryPath
        if !current.isEmpty {
            return URL(fileURLWithPath: current)
        }
        return nil
    }
}
