# CLAUDE.md —— 在本仓库工作的规则

先读 [program.md](program.md)（背景、架构、问题记录；尤其 §4.3 自动回答、§7 问题表、§9 验证、§10.1 待决设计），再读 [ISSUES.md](ISSUES.md)（待解决问题与验收阈值）、[STATUS.md](STATUS.md)（当前指标与下一步）、[LOG.md](LOG.md)（迭代日志）。

## 代码结构
- `Sources/MeetingCopilotCore/`：与 UI、设置、系统权限无关的核心逻辑（转写 `Transcriber.swift`、对话记录 `Transcript.swift`、轮次切分 `TurnSplitter.swift`、自动触发判断 `TurnDetector.swift`、上下文组装 `ContextBuilder.swift`）。**触发和上下文的改进都发生在这里**，可在命令行测试和评测。
- `Sources/MeetingCopilot/`：App（SwiftUI、截图/音频捕获、LLM 客户端、设置、快捷键），通过 Core 的公开接口使用上面的逻辑。
- `Tests/MeetingCopilotCoreTests/`：单元测试、等价性测试、评测（`Eval*Tests.swift`、`Support/`）。
- `eval/`：评测数据集与说明（已冻结，见 `eval/README.md`）。

## 命令

| 目的 | 命令 |
|---|---|
| 编译（不签名、不打包） | `swift build` |
| 单元测试 | `scripts/test.sh`（只装了 Command Line Tools 时自动补测试框架路径；等价于 `swift test`） |
| 完整评测 → `eval/results/latest.json` + 表格 | `scripts/eval.sh` |
| 快速评测（跳过 ASR，几秒） | `EVAL_ASR=0 scripts/eval.sh` |
| 回答质量评测（可选） | `EVAL_QUALITY=1 EVAL_LLM_BASE_URL=… EVAL_LLM_MODEL=… EVAL_LLM_KEY=… scripts/eval.sh` |

测试框架是 Swift Testing（`import Testing`），本机只有 Command Line Tools，没有 XCTest。App 自检入口 `--selftest-*` 见 program.md §9；自检运行时不会写设置、不会读写钥匙串、不会注册快捷键（`RuntimeFlags.isolated`），必须用未签名的 `.build/…/MeetingCopilot` 二进制并设置 `CFFIXED_USER_HOME=<临时目录>` 运行，**不要用 `open` 启动沙盒 App 跑自检**。

## 硬性规则
- 不得修改 `eval/dialogs`、`eval/audio`、`eval/rubric.md`、阈值、`scripts/eval.sh` 的评分逻辑。认为评测有错时，写进 `STATUS.md` 的「需人工确认」。
- 不得 `git push`、改写历史、发布 Release、运行 `build.sh` / `create-signing-cert.sh`、操作钥匙串或 TCC 权限。
- 遵守只读和安全边界（program.md §3、§4.4）：不申请辅助功能权限，不保存音频和截图。
- 任何文件不得出现个人信息（用户名、姓名、邮箱、本机路径、密钥）。提交只用仓库本地的 noreply 身份。
- 新增设置字段必须同步加入 `Settings` 的 `CodingKeys` 和 `init(from:)`（见 program.md §7-15）。
- 需要真实会议、真实麦克风、真实按键才能验证的，标为「需人工验证」，不得声称已解决。
- program.md 按它开头的维护规则整理改写，不要在末尾堆叠内容。

## 工作约定
- 分支 `auto-iter` 上迭代；每个独立改动单独提交；提交信息用中文，说明改了什么、指标怎么变。
- 改触发/上下文逻辑前后各跑一次 `scripts/eval.sh`，把指标变化写进 LOG.md，更新 STATUS.md。
- 重构必须证明行为不变（等价性测试 `EquivalenceTests` 与重构前后真实请求体 md5 对比）。
