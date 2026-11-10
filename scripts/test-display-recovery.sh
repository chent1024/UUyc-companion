#!/bin/zsh
# 离线验证：读取本机模式，不创建/禁用显示器；所有写入均在任务目录。
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CODEX_TASK_DATA_DIR:?请设置外置盘任务目录 CODEX_TASK_DATA_DIR}"
[[ -d "$CODEX_TASK_DATA_DIR" ]] || { echo '任务目录不可用' >&2; exit 1; }
mkdir -p "$CODEX_TASK_DATA_DIR/UUyc-companion/tests"
TEST_DIR="$(mktemp -d "$CODEX_TASK_DATA_DIR/UUyc-companion/tests/display-recovery.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export TMPDIR="$TEST_DIR"
scripts/test-connection.sh
swiftc Sources/UUDisplay/WorkWindowSession.swift tests/work-windows-main.swift -o "$TEST_DIR/window-tests"
"$TEST_DIR/window-tests"
swiftc Sources/UUDisplay/Config.swift Sources/UUDisplay/Log.swift \
  Sources/UUDisplay/DisplaySession.swift Sources/UUDisplay/PhysicalDisplays.swift Sources/UUDisplay/VirtualDisplayReadiness.swift \
  tests/display-session-main.swift -o "$TEST_DIR/display-tests"
"$TEST_DIR/display-tests" "$TEST_DIR"
swiftc Sources/UUDisplay/Config.swift Sources/UUDisplay/UUConnectionState.swift \
  Sources/UUDisplay/UUMonitor.swift Sources/UUDisplay/Coordinator.swift \
  tests/coordinator-main.swift -o "$TEST_DIR/coordinator-tests"
"$TEST_DIR/coordinator-tests" "$TEST_DIR/config"
