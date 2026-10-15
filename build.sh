#!/bin/bash
# 构建并打包为沙盒化的 MeetingCopilot.app（ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/MeetingCopilot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/MeetingCopilot" "$APP/Contents/MacOS/"
# SwiftPM 依赖的资源包必须放进 .app，否则只能在构建目录里运行
mkdir -p "$APP/Contents/Resources"
cp -R "$(swift build -c release --show-bin-path)"/*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 用固定证书签名，权限（TCC）才能跨次构建保持。没有证书时退回 ad-hoc（每次构建都需重新授权）。
IDENTITY="MeetingCopilot Local Signing"
if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
  echo "提示：未找到签名证书，使用 ad-hoc 签名，重新构建后需重新授权。运行 ./create-signing-cert.sh 可创建固定证书。" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" --entitlements Resources/MeetingCopilot.entitlements "$APP"
echo "OK -> $PWD/$APP"
