# SKProcessRunner

Small, dependency-light Swift wrapper around `Foundation.Process`:

- Resolve executables via `$PATH`
- Run commands with `cwd` / `env`
- Capture `stdout`/`stderr`
- Timeout + output size cap (truncation)

This package is intended to be shared by:
- `Decision` (Codex CLI runner)
- `SKIntelligence` (`shell` tool)
- `swift-git` (custom process runner)

