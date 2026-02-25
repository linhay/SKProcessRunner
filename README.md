# SKProcessRunner

Small, dependency-light Swift wrapper around `Foundation.Process` with optional PTY support.

Designed to be shared by:
- `Decision` (Codex CLI runner)
- `SKIntelligence` (`shell` tool)
- `swift-git` (custom process runner)

## Features
- Resolve executables via `$PATH`
- Run commands with `cwd` and `env` overrides
- Capture `stdout` and `stderr`
- Stream output while running
- Timeout and output size caps (with truncation flag)
- Optional PTY execution for TTY-required commands

## Requirements
- Swift 5.9+ (SwiftPM package)
- Foundation

PTY support is implemented for Darwin and Glibc. `SKProcessPTYSession` is only covered by tests on macOS.

## Platform Support

| API | macOS | iOS |
|---|---|---|
| `run` / `runSync` | Supported | Supported |
| `runPTY` / `runPTYSync` | Supported | Supported (platform capability may vary) |
| `SKProcessPTYSession` | Supported | Not supported |
| `SKProcessPipeSession` | Supported | Not supported (compile-time unavailable) |

## Installation (SwiftPM)

Add to your `Package.swift` dependencies:

```swift
.package(path: "../SKProcessRunner")
```

Then add the product to your target:

```swift
.product(name: "SKProcessRunner", package: "SKProcessRunner")
```

## Quick Start

Simple async run:

```swift
import SKProcessRunner

let payload = SKProcessPayload.command("ls")
    .argument("-la")
    .cwd(URL(fileURLWithPath: "/tmp"))

let result = try await SKProcessRunner.run(payload)
print(result.stdout)
```

Synchronous run:

```swift
let payload = SKProcessPayload.command("uname")
    .argument("-a")

let result = try SKProcessRunner.runSync(payload)
print(result.stdout)
```

## Streaming Output

You can stream output while the process runs:

```swift
let payload = SKProcessPayload.command("ping")
    .arguments(["-c", "3", "127.0.0.1"])

let result = try await SKProcessRunner.run(
    payload,
    onStdout: { chunk in
        print(String(decoding: chunk, as: UTF8.self), terminator: "")
    },
    onStderr: { chunk in
        print(String(decoding: chunk, as: UTF8.self), terminator: "")
    }
)
print("exit:", result.exitCode)
```

## PTY Execution

PTY mode merges stdout and stderr (both come through `stdoutData`).

```swift
let payload = SKProcessPayload.executableURL(URL(fileURLWithPath: "/usr/bin/env"))
    .arguments(["bash", "-lc", "ls --color=auto"])
    .pty(.init(rows: 30, cols: 120))

let result = try await SKProcessRunner.runPTY(payload)
print(result.stdout)
```

Synchronous PTY:

```swift
let result = try SKProcessRunner.runPTYSync(payload)
```

## SKProcessPTYSession (Interactive)

`SKProcessPTYSession` gives a stream-like interface for interactive programs.

```swift
let payload = SKProcessPayload.executableURL(URL(fileURLWithPath: "/bin/sh"))
    .arguments(["-c", "read line; echo $line"])
    .pty(.init(rows: 24, cols: 80))

let session = try SKProcessPTYSession(payload)

Task {
    for await chunk in session.output {
        print(String(decoding: chunk, as: UTF8.self), terminator: "")
    }
}

try await session.send(Data("hello\n".utf8))
try await session.close()
let result = try await session.wait()
print("pid:", session.pid, "running:", await session.isRunning(), "exit:", result.exitCode)
```

## SKProcessPipeSession (Non-PTY Interactive)

`SKProcessPipeSession` provides long-lived bidirectional stdio communication without PTY semantics.
This API is available on macOS and compile-time unavailable on iOS.

```swift
let payload = SKProcessPayload.command("/bin/sh")
    .arguments(["-c", "while IFS= read -r line; do printf '%s\\n' \"$line\"; done"])
    .timeoutMs(10_000)

let session = try SKProcessPipeSession(payload)

Task {
    let stream = await session.stdout
    for await chunk in stream {
        print("stdout:", String(decoding: chunk, as: UTF8.self), terminator: "")
    }
}

try await session.send(Data("{\"op\":\"ping\"}\n".utf8))
try await session.closeStdin()
let result = try await session.wait()
print("pid:", session.pid, "exit:", result.exitCode)
```

## SKProcessPayload Builder

`SKProcessPayload` is a value type with fluent builder methods:

```swift
let payload = SKProcessPayload.command("git")
    .arguments(["status", "--porcelain"])
    .cwd(URL(fileURLWithPath: "/path/to/repo"))
    .environment(.current().merging(["LANG": "C"]))
    .timeoutMs(5_000)
    .terminationGracePeriodMs(300)
    .maxOutputBytes(256 * 1024)
    .spoolFullOutput()
    .throwOnNonZeroExit()
```

Key fields:
- `executable`: `.path(String)` or `.url(URL)`
- `arguments`: `[String]`
- `stdinData`: `Data?` (set via `stdin(_:)`)
- `cwd`: `URL?`
- `environment`: `SKProcessEnvironment?`
- `useUserShellEnvironment`: `Bool`
- `timeoutMs`: `Int` (clamped to 1s...30m)
- `terminationGracePeriodMs`: `Int` (clamped to 0...10s)
- `maxOutputBytes`: `Int` (clamped to 8 KB...2 MB)
- `spoolFullOutput`: `Bool` (optional full-log spooling)
- `fullOutputDirectory`: `URL?` (defaults to system temp directory)
- `throwOnNonZeroExit`: `Bool`
- `pty`: `SKProcessPTYConfiguration?`

## SKProcessEnvironment and PATH Resolution

By default, commands resolve against the current process environment:

```swift
let payload = SKProcessPayload.command("node")
```

If you need the user shell environment (e.g., PATH updates from shell init files):

```swift
let payload = SKProcessPayload.command("node")
    .useUserShellEnvironment(true, mode: .loginInteractive)
```

You can also load the shell environment directly:

```swift
let env = SKProcessEnvironment.userShell(mode: .loginInteractive)
```

## SKProcessResult

`SKProcessResult` includes:
- `stdoutData` / `stderrData`
- `stdout` / `stderr` (UTF-8 best-effort)
- `exitCode`
- `timedOut`
- `truncated`
- `fullOutputPath` (`String?`)

If output exceeds `maxOutputBytes`, `truncated` is set and data is capped.
If `.spoolFullOutput()` is enabled and truncation occurs, `fullOutputPath` points to a temp file containing full merged process output.
If truncation does not occur, temp file is cleaned up and `fullOutputPath` is `nil`.

## Errors

`SKProcessRunError`:
- `executableNotFound`
- `invalidExecutable`
- `ptyFailed`
- `pipeFailed`
- `nonZeroExit` (includes stdout/stderr data)
- `timedOut` (includes stdout/stderr data + `truncated`)

Use `.throwOnNonZeroExit()` to convert non-zero exits into errors.

## Notes and Behavior

- `timeoutMs` and `maxOutputBytes` are clamped to safe minimums/maximums.
- On timeout (non-PTY), the runner uses process-tree escalation: `SIGTERM` then `SIGKILL` after `terminationGracePeriodMs`.
- In PTY mode, stderr is merged into stdout.
- When `useUserShellEnvironment` is enabled, the base environment is loaded once and then merged with any payload overrides.
- SKProcessExecutable resolution respects overrides in `payload.environment` when resolving `.path(...)`.

## License

See `LICENSE` if present in the repository root.
