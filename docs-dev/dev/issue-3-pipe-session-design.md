# 设计说明：SKProcessPipeSession

- 关联需求：`docs-dev/features/issue-3-non-pty-pipe-session.md`

## 方案摘要
- 新增 `SKProcessPipeSession`（actor）承载非 PTY 双向长连接通信。
- 使用 `Process + Pipe`，分别维护 `stdout/stderr` 两路 `AsyncStream<Data>`。
- 保持与 `SKProcessPayload` 一致的 executable/cwd/environment/timeout 配置解析流程。

## 生命周期
1. `init(payload)` 启动子进程并设置三路 pipe。
2. 通过 `readabilityHandler` 持续读取 stdout/stderr，写入状态缓存并向 stream 发射。
3. `send(_:)` 写 stdin；`closeStdin()` 关闭 stdin 写端。
4. `wait()` 等待结束并返回 `SKProcessResult`（可选抛 `nonZeroExit`）。
5. timeout 时抛 `timedOut`，并使用进程树终止策略回收进程。

## 错误模型
- 新增 `SKProcessRunError.pipeFailed(String)`，用于 stdin 写入/关闭失败、会话状态错误。

## 验证
- 新增 `SKProcessPipeSessionTests` 覆盖：
  - 1000 行 JSON line 往返
  - stdout/stderr 分离
  - timeout
  - `throwOnNonZeroExit`

