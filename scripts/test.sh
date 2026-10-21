#!/bin/bash
# 运行单元测试。只装了 Command Line Tools（没有 Xcode）时，SwiftPM 找不到测试框架，这里补上框架路径。
# 用法：scripts/test.sh [swift test 的其他参数，如 --filter Xxx]
set -euo pipefail
cd "$(dirname "$0")/.."
FW="$(xcode-select -p)/Library/Developer/Frameworks"
EXTRA=()
if [ -d "$FW/Testing.framework" ] && ! xcrun --find xctest >/dev/null 2>&1; then
  EXTRA=(-Xswiftc -F"$FW" -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW"
         -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib")
fi
exec swift test "${EXTRA[@]+"${EXTRA[@]}"}" "$@"
