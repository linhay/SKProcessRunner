# Feature: 非 PTY 双向长连接会话（SKProcessPipeSession）

## 背景
- 当前库已有一次性执行 API 与 PTY 会话 API。
- JSON-RPC over stdio 需要基于 Pipe 的原始字节流，不适合 PTY。

## 验收场景（BDD）
1. Given 一个基于 `/bin/sh` 的行回显子进程
   When 使用 `SKProcessPipeSession` 持续 `send` 多行并 `closeStdin`
   Then 能从 `stdout` 连续收到对应输出，`wait()` 返回成功结果。

2. Given 子进程分别向 stdout/stderr 输出内容
   When 会话结束
   Then `SKProcessResult.stdoutData` 与 `stderrData` 保持分离。

3. Given 子进程超时
   When 达到 `timeoutMs`
   Then `wait()` 抛出 `timedOut`，并在合理时间内返回。

4. Given `throwOnNonZeroExit=true` 且子进程非 0 退出
   When 调用 `wait()`
   Then 抛出 `nonZeroExit` 并携带 stdout/stderr 数据。

5. Given 1000 行 JSON line 双向通信
   When 连续发送并读取
   Then 消息数量完整、顺序稳定、无 PTY 污染字符。

