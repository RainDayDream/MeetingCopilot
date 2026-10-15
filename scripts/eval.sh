#!/bin/bash
# 一条命令跑完评测：触发（文本回放）、ASR（wav 回放）、上下文，可选回答质量。
# 输出 eval/results/latest.json 和一张表格。不调用 build.sh、不签名、不触发任何系统权限弹窗。
#
# 环境变量：
#   EVAL_ASR=0          跳过 ASR（首次运行会下载约 460MB 的 Whisper small 模型到 eval/.cache）
#   EVAL_ASR_MODEL=xxx  ASR 评测使用的模型（默认 small，与产品默认一致）
#   EVAL_QUALITY=1      运行回答质量评测（需 EVAL_LLM_BASE_URL / EVAL_LLM_MODEL / EVAL_LLM_KEY 和 claude CLI）
set -euo pipefail
cd "$(dirname "$0")/.."

# 1) 冻结校验：数据集、评分标准、评测代码被改动则拒绝运行
if ! shasum -a 256 -c eval/FROZEN.sha256 --quiet; then
  echo "评测数据集/评分逻辑与冻结记录不一致，拒绝运行（见 eval/README.md）。" >&2
  exit 2
fi

# 2) 编译并运行全部测试（单元测试 + 评测）
rm -rf eval/results/.partial
mkdir -p eval/results
swift build
scripts/test.sh

# 3) 可选：回答质量
if [ "${EVAL_QUALITY:-0}" = "1" ]; then
  python3 scripts/eval_quality.py || echo "[quality] 失败，已跳过" >&2
fi

# 4) 汇总 + 表格
python3 scripts/eval_report.py
