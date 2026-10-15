# LOG.md —— 迭代日志

按时间顺序记录每次迭代做了什么、指标怎么变。最新的在最上面。指标来自 `scripts/eval.sh`（定义见 `eval/README.md`）。

## 2026-10-16　评测基础设施搭建（分支 auto-iter，本阶段不改产品行为）

**提交**
1. `f4f7bc7` 开发中版本基线（把未提交的改动提交为基线）。
2. `53b26f9` 自检隔离：`--selftest*` 下不写设置、不读写钥匙串、不注册快捷键。
   - 发现：此前自检通过 `open` 启动沙盒 App 运行，会把 mock 的 Base URL/模型、会议背景、关截图、开自动回答写进用户真实的 settings.json —— 这很可能就是“每次更新后 Base URL 和模型要重配”的真正原因（见 program.md §7-17）。
3. `4b0e310` 重构：拆出 `MeetingCopilotCore`（`TurnDetector`、`ContextBuilder`、`TurnSplitter`、`TranscriptOps`、转写），加测试 target；**行为不变**。
4. 评测数据集、评测测试、`scripts/eval.sh`、`ISSUES.md`、`STATUS.md`、`LOG.md`、`CLAUDE.md`。

**重构等价性证明**（同一场景 `--selftest-context`：3 个带问号的问题 + 我立刻开口 + 半句后补完 + 自动回答开着时手动触发）
- 用重构前提交（53b26f9）和重构后代码各编译一个未签名二进制，对同一个 mock 服务器跑同一场景，记录每个请求的**完整消息体 md5**：5 个请求逐一相同
  `48b9e0c7…`、`b5b8dab8…`、`65593cd8…`、`3f78cc18…`、`aa913595…`。
- 请求数 5；用户消息字数 [249, 415, 537, 642, 584]；相邻前缀 [无, 断开, 一致, 一致, 一致]；触发延迟 ≈ [0.5, 0.5, 0.5, 0.5, 0.1] s；“我立刻开口”不触发、“手动触发”只有 1 次调用 —— 与重构前一致。
- 同一场景在虚拟时间里回放的单元测试 `EquivalenceTests` 复现上述全部数字，纳入 `scripts/test.sh`。

**测试环境说明**：本机只有 Command Line Tools，没有 XCTest；测试用 Swift Testing，`scripts/test.sh` 自动补框架路径。

**基线指标**：见 STATUS.md 与 `eval/results/baseline.json`。

**发现但本阶段不处理的问题**：ISS-014（切换接口类型丢失 Base URL/模型、旧 API Key 未保存；此前文档误称已实现）、ISS-015（用户真实设置里可能有早期自检残留）。
