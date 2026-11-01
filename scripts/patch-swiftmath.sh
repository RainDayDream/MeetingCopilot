#!/bin/bash
# SwiftMath 1.7.3 生成的 Bundle.module 在 .app 根目录寻找资源包，但 macOS .app
# 只应把资源放在 Contents/Resources（放根目录会导致 codesign --strict 失败）。
# 这里在构建前把它改成优先从 Contents/Resources 读取；命令行/测试环境仍回退到 Bundle.module。
set -euo pipefail
cd "$(dirname "$0")/.."
FILE=".build/checkouts/SwiftMath/Sources/SwiftMath/MathRender/MTFont.swift"
[ -f "$FILE" ] || exit 0
chmod u+w "$FILE" 2>/dev/null || true
python3 - "$FILE" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
if "优先从 .app 的 Contents/Resources" in s:
    raise SystemExit(0)
old = '''    static var fontBundle:Bundle {
        // Uses bundle for class so that this can be access by the unit tests.
        Bundle(url: Bundle.module.url(forResource: "mathFonts", withExtension: "bundle")!)!
    }'''
new = '''    static var fontBundle:Bundle {
        // App 内资源必须在 Contents/Resources；命令行/测试环境再回退到 SwiftPM bundle。
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("SwiftMath_SwiftMath.bundle/mathFonts.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/SwiftMath_SwiftMath.bundle/mathFonts.bundle"),
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            if let b = Bundle(url: c) { return b }
        }
        return Bundle(url: Bundle.module.url(forResource: "mathFonts", withExtension: "bundle")!)!
    }'''
if old not in s:
    raise SystemExit("SwiftMath MTFont.swift: patch target not found")
p.write_text(s.replace(old, new))
PY
