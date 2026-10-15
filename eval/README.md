# eval/ —— 评测数据集与说明

> **数据集已冻结。后续迭代不得修改 `eval/dialogs/`、`eval/audio/`、`eval/rubric.md`、`eval/quality/`，
> 也不得修改评测代码（`scripts/eval*.{sh,py}`、`Tests/MeetingCopilotCoreTests/` 里的 `Eval*.swift`、`Support/`）。**
> `scripts/eval.sh` 每次运行前用 `eval/FROZEN.sha256` 校验这些文件，不一致就拒绝运行。
> 认为评测本身有错时，不要改它，写进 `STATUS.md` 的「需人工确认」，由人决定是否重新冻结。
> 目标值 `eval/thresholds.json` 不在冻结范围内，但只有用户确认后才能把 `confirmed` 置为 true。

## 内容

| 路径 | 说明 |
|---|---|
| `dialogs/*.json` | 59 段标注好的对话脚本（80 个对方发言轮次，其中 60 个应回答、20 个不应回答） |
| `audio/*.wav` + `audio/manifest.json` | 其中 10 段用 macOS `say` 合成的双通道 wav（左 = 对方/系统音频，右 = 我/麦克风），参考文本就是脚本原文 |
| `rubric.md`、`quality/cases.json` | 回答质量评分标准和 10 个固定问题（可选评测，默认关闭） |
| `thresholds.json` | 各指标的目标值（建议值，待确认） |
| `tools/gen_dialogs.py`、`tools/gen_audio.py` | 一次性生成脚本（已运行，结果冻结，**不要再运行**） |
| `results/` | 评测输出：`latest.json`（每次覆盖，不入库）、`baseline.json`（基线，入库） |

## 对话脚本格式

```json
{
 "id": "think_pause_03", "category": "think_pause", "lang": "zh|en|mixed", "description": "...",
 "events": [ {"speaker": "对方|我", "text": "...", "start": 1.0, "end": 3.87, "kind": "speech|echo"} ],
 "expected": [ {"id": "q1", "should_answer": true, "turn_start": 1.0, "question_end": 10.176,
                "question_text": "...", "reply_start": 12.676, "window_end": 12.676, "note": "..."} ]
}
```

- `events` 的每一项是 VAD 切句后的一**段**（同一说话人相邻两段间隔 ≥ 0.8 秒，否则会被合并成一段）。`kind=echo` 表示外放回声（对方的话在“我”通道 0.3 秒后重复出现）。
- `expected` 的每一项是对方的一**轮**话：`should_answer` 该轮是否应触发回答；`question_end` 是这一轮**真正说完**的时刻（不应回答的轮次表示该轮说完的时刻）；`reply_start` 是我开始回应的时刻。
- `window_end`：该标注的归属窗口 `[turn_start, window_end]`，窗口互不重叠。应回答的轮次 = `reply_start`（我开口之后再触发已经没有意义）；不应回答的轮次 = `max(reply_start, question_end) + 8 秒`（我开口后一段时间内再触发也算误答）。

### 覆盖的类别（12 类）
思考型停顿（`think_pause`）、连珠多问（`multi_question`）、半截追问（`half_followup`）、没有疑问词的指令式提问（`imperative`）、寒暄和陈述（`chitchat`，不应回答）、我方插话/抢答（`me_interrupt`，不应回答）、对方说到一半我插“嗯”（`backchannel`）、外放回声（`echo`）、中英混杂（`mixed_lang`）、英文提问（`english`）、多句长技术题（`long_technical`）、完整面试片段（`full_interview`，多轮混合）。

## 指标定义

### 触发（文本事件回放，虚拟时间，确定性）
每段对话按下面的**识别时序模型**回放给 `TurnDetector`，得到自动触发的时刻，再与标注对齐：

| 时序参数（取自产品代码，固定） | 值 |
|---|---|
| 说完后 VAD 定稿延迟 | 0.8 s |
| 识别耗时（Whisper small，假设值；实测值见结果里的 `asr.transcribe_latency_*` 供核对） | 0.7 s |
| 临时结果间隔 | 2.0 s（内容为定稿文本按已说时长截取的前缀） |
| 最短语音（丢弃更短的段） | 对方 0.3 s，我 0.6 s |

对齐规则（每个标注窗口内）：

| 指标 | 定义 |
|---|---|
| **抢答率** | 应回答的轮次中，在 `question_end` 之前就有触发的比例 |
| **漏答率** | 应回答的轮次中，`question_end` 及之后到窗口结束都没有触发的比例 |
| **误答率** | 不应回答的轮次中，窗口内有触发的比例（触发层面：只要调用了模型就算，产品里“模型返回（无需回答）后隐藏”的补救不在此评测范围，但调用的费用已经产生） |
| **延迟 P50/P95** | `question_end` 之后第一次触发的时刻 − `question_end`（只统计有准时触发的轮次） |
| **重复触发** | 窗口内多于 1 次的触发数之和 |
| **游离触发** | 不在任何窗口内的触发数 |

外放回声类（`echo`）假设回声**被识别**（最坏情况）；回声在真实音频里是否被识别由 ASR 评测的 `echo_leak_rate` 单独度量。

### ASR（wav 回放，经过 `WhisperStream`，模型 Whisper small，语言自动检测）
| 指标 | 定义 |
|---|---|
| 中文 CER / 英文 WER / 中英混杂 CER | 对方通道的识别结果与脚本原文的字（词）错误率；归一化：小写、去标点和空格 |
| “我”通道幻觉句数 | 我通道的定稿句里，既不像我说的话也不像对方的话的句数（10 段合计，其中 3 段注入了键盘敲击声）。“像”的判断：字符二元组重合 ≥ 50% |
| 回声泄漏率 | 外放回声段（右声道是左声道 35% 音量、延迟 0.3 s 的副本）里，对方每一段话出现在“我”通道识别结果里的比例（目前只有 1 段回声音频，样本很小） |
| 单段识别耗时 | 对方每一段单独识别的耗时 P50/P95（参考，用于核对时序模型里的 0.7 s） |

### 上下文
| 指标 | 定义 |
|---|---|
| 相邻请求前缀稳定率 | 同一段对话里相邻两次触发，上一次“整场对话”部分是否是下一次请求的前缀（服务端前缀缓存能否命中的必要条件）；第一次请求时对话为空，下一次请求必然不满足 |
| 平均提示词字数 | 系统提示词 + 用户消息的字数 |
| 当前这一轮被完整标出 | 触发后的提示词里，`【当前这一轮】` 块是否包含该轮对方说的每一段（只统计准时触发的轮次） |

### 回答质量（可选，默认关闭）
`EVAL_QUALITY=1` 且设置 `EVAL_LLM_BASE_URL`、`EVAL_LLM_MODEL`、`EVAL_LLM_KEY`（Key 只从环境变量读取）时，对 10 个固定问题组装产品提示词，用被测模型生成回答，再用独立的 `claude -p` 按 `rubric.md` 打 5 个维度的分。

## 已知局限（评测没有覆盖的）
- 触发评测用脚本里的**正确文本**回放，不含识别错误；识别错误对触发的影响只能通过 ASR 评测间接看到。
- 时序模型是固定的假设值，真实机器上的识别耗时会不同；真实 VAD、真实麦克风、外放回声的实际被识别程度都需要真实会议验证。
- 合成语音（`say`）比真实面试官更干净、语速更均匀；没有口音、插话重叠、背景噪声（除了注入的键盘声）。
- 回声音频只有 1 段，回声泄漏率不具统计意义。
- “应回答/不应回答”和 `question_end` 是人工设计的标注，对“开放式陈述是否算提问”这类边界情况有主观性。

## 运行

```bash
scripts/eval.sh                  # 完整评测（首次会下载约 460MB 的 Whisper small 模型到 eval/.cache）
EVAL_ASR=0 scripts/eval.sh       # 跳过 ASR，只跑触发和上下文（几秒）
scripts/test.sh                  # 只跑单元测试
```
