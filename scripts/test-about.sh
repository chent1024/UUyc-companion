#!/bin/zsh
# 不启动 UUDisplay 主程序；在独立 AppKit 测试进程中检查关于渲染与 Debug 编号。
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CODEX_TASK_DATA_DIR:?请设置任务目录 CODEX_TASK_DATA_DIR}"
[[ -d "$CODEX_TASK_DATA_DIR" ]] || { echo '任务目录不可用' >&2; exit 1; }
mkdir -p "$CODEX_TASK_DATA_DIR/UUyc-companion/tests"
TEST_DIR="$(mktemp -d "$CODEX_TASK_DATA_DIR/UUyc-companion/tests/about.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/UUDisplay/Config.swift Sources/UUDisplay/AboutWindow.swift \
  Sources/UUDisplay/DebugLabels.swift tests/about-main.swift -o "$TEST_DIR/about-tests"
"$TEST_DIR/about-tests" "$TEST_DIR" "${1:-$TEST_DIR/about.png}" "$PWD/Assets/AppIcon/AppIcon.icns"
