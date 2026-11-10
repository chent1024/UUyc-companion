#!/bin/zsh
# 只操作本测试子进程的临时窗口；不启动 UUDisplay、不改变显示拓扑。
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CODEX_TASK_DATA_DIR:?请设置外置盘任务目录 CODEX_TASK_DATA_DIR}"
[[ -d "$CODEX_TASK_DATA_DIR" ]] || exit 1
mkdir -p "$CODEX_TASK_DATA_DIR/UUyc-companion/tests"
TEST_DIR="$(mktemp -d "$CODEX_TASK_DATA_DIR/UUyc-companion/tests/native-windows.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export TMPDIR="$TEST_DIR"
APP="$TEST_DIR/WindowFixture.app"
mkdir -p "$APP/Contents/MacOS"
swiftc Sources/UUDisplay/WorkWindowSession.swift Sources/UUDisplay/AccessibilityWindows.swift \
  tests/native-windows-main.swift -o "$APP/Contents/MacOS/window-fixture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.corndog.uudisplay.window-fixture</string>
<key>CFBundleExecutable</key><string>window-fixture</string>
<key>CFBundleName</key><string>WindowFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ "${1:-}" == "--capture-only" ]]; then
  "$APP/Contents/MacOS/window-fixture" --capture-only
else
  "$APP/Contents/MacOS/window-fixture" "$APP"
fi
