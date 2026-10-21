#!/usr/bin/env python3
"""一次性生成评测对话脚本 eval/dialogs/*.json 和音频合成计划。生成后冻结，不得再运行或修改（见 eval/README.md）。

每个 JSON：events 是 VAD 切句后的“段”（同一说话人相邻两段间隔 >= 0.8 秒，否则会被切成同一段）；
expected 是每个“对方的一轮话”的标注：该轮是否应该回答、问题真正说完的时刻 question_end。
时间单位：秒，相对对话开始。
"""
import json, os, re, sys

OUT = os.path.join(os.path.dirname(__file__), "..", "dialogs")
PLAN = os.path.join(os.path.dirname(__file__), "audio_plan.json")
CJK = re.compile(r"[一-鿿]")
LAT = re.compile(r"[A-Za-z0-9']+")

def est_dur(text):
    """估计朗读时长（秒）：中文约 4.2 字/秒，英文约 2.7 词/秒，加 0.25 秒起止余量"""
    return len(CJK.findall(text)) / 4.2 + len(LAT.findall(text)) / 2.7 + 0.25

class Dialog:
    def __init__(self, id, cat, lang, desc, audio=None, durfn=None):
        self.id, self.cat, self.lang, self.desc = id, cat, lang, desc
        self.audio = audio          # None 或 {"noise": bool, "echo": bool}
        self.durfn = durfn or est_dur
        self.t = 0.0
        self.events, self.expected = [], []

    def seg(self, speaker, text, pause=0.0, kind="speech"):
        start = round(self.t + pause, 3)
        end = round(start + self.durfn(text, speaker), 3)
        self.events.append({"speaker": speaker, "text": text, "start": start, "end": end, "kind": kind})
        self.t = end
        return start, end

    def seg_at(self, speaker, text, start, kind="speech", advance=False):
        end = round(start + self.durfn(text, speaker), 3)
        self.events.append({"speaker": speaker, "text": text, "start": round(start, 3), "end": end, "kind": kind})
        if advance: self.t = max(self.t, end)
        return round(start, 3), end

    def ask(self, segments, should=True, note="", pause=1.0, echo=False):
        """对方的一轮话。segments: [(text, 段前停顿秒)]，第一段的停顿用 pause。"""
        first, last_end, texts = None, None, []
        for i, (text, p) in enumerate(segments):
            s, e = self.seg("对方", text, pause if i == 0 else p)
            if echo:   # 外放回声：同样的话在“我”通道 0.3 秒后重复出现
                self.seg_at("我", text, s + 0.3, kind="echo")
            first = s if first is None else first
            last_end = e
            texts.append(text)
        self.cur = {"should_answer": should, "turn_start": first, "question_end": last_end,
                    "question_text": "".join(texts), "reply_start": None, "note": note}
        self.expected.append(self.cur)

    def reply(self, text, pause=2.5):
        s, e = self.seg("我", text, pause)
        if self.cur["reply_start"] is None: self.cur["reply_start"] = s

    def me_at(self, text, offset_from_qend):
        """我在问题说完之后（可为负：问题说完之前）offset 秒开口"""
        s = self.cur["question_end"] + offset_from_qend
        s, e = self.seg_at("我", text, s, advance=True)
        self.cur["reply_start"] = s

    def finish(self):
        self.events.sort(key=lambda e: (e["start"], e["speaker"]))
        # 同一说话人（含回声通道）相邻段间隔必须 >= 0.8s，否则会被 VAD 合并成一段
        for sp in ("对方", "我"):
            ev = [e for e in self.events if e["speaker"] == sp]
            for a, b in zip(ev, ev[1:]):
                if b["start"] - a["end"] < 0.8 - 1e-9 and a["kind"] == b["kind"]:
                    raise SystemExit(f"{self.id}: {sp} 相邻段间隔 {b['start']-a['end']:.2f}s < 0.8s: {a['text']} / {b['text']}")
        # 标注窗口：[turn_start, window_end]，互不重叠
        ex = self.expected
        for i, x in enumerate(ex):
            nxt = ex[i + 1]["turn_start"] - 0.01 if i + 1 < len(ex) else float("inf")
            if x["should_answer"]:
                # 应回答：触发必须赶在我开口之前才有意义
                we = max(x["reply_start"], x["question_end"]) if x["reply_start"] is not None else x["question_end"] + 8.0
            else:
                # 不应回答：我开口之后的一段时间内再触发也算误答
                we = max(x["reply_start"] or 0.0, x["question_end"]) + 8.0
            x["window_end"] = round(min(we, nxt), 3)
            for k in ("turn_start", "question_end"): x[k] = round(x[k], 3)
            x["id"] = f"q{i+1}"
        return {"id": self.id, "category": self.cat, "lang": self.lang, "description": self.desc,
                "audio": self.audio, "events": self.events, "expected": ex}

DIALOGS = []
def add(d): DIALOGS.append(d)

def dlg(id, cat, lang, desc, audio=None):
    return Dialog(id, cat, lang, desc, audio, durfn=DURFN.get("fn"))
DURFN = {}

# ---------------------------------------------------------------- 1. 思考型停顿
tp = [
 ("think_pause_01", "zh", "我们先来看看你的项目，嗯……我想问的是", 2.0, "你在这个项目里遇到的最大技术挑战是什么？"),
 ("think_pause_02", "zh", "关于你简历上的这个推荐系统，呃，", 1.2, "你们的召回是怎么做的？"),
 ("think_pause_03", "zh", "这个方案我有点好奇，那个……", 3.2, "为什么没有选择用向量检索？"),
 ("think_pause_04", "zh", "所以在高并发的场景下，嗯，让我想想", 2.6, "你们是怎么保证数据一致性的？"),
 ("think_pause_05", "en", "Let me think... so what I wanted to ask is", 2.2, "how did you handle the latency requirements?"),
 ("think_pause_06", "zh", "好，那我想了解一下，就是……", 1.6, "你在团队里具体承担了什么角色？"),
]
# ---------------------------------------------------------------- 2. 连珠多问
mq = [
 ("multi_question_01", "zh", [("你们团队有多少人？", 0), ("另外你们的迭代周期是怎样的？", 1.0)]),
 ("multi_question_02", "zh", [("你为什么选择这家公司？", 0), ("以及你对未来三年的规划是什么？", 1.2)]),
 ("multi_question_03", "zh", [("这个项目的指标提升了多少？", 0), ("是怎么衡量的？", 1.0), ("有没有做过 A/B 实验？", 1.1)]),
 ("multi_question_04", "en", [("What was your role in the project?", 0), ("And how big was the team?", 1.0)]),
 ("multi_question_05", "zh", [("请介绍一下你的实习经历。", 0), ("重点说说你负责的模块。", 1.3)]),
 ("multi_question_06", "zh", [("你更喜欢前端还是后端？", 0), ("为什么？", 0.9)]),
]
# ---------------------------------------------------------------- 3. 半截追问（先有一问一答）
hf = [
 ("half_followup_01", "zh", "你们的推荐系统用的是什么架构？", "我们用的是双塔召回加精排的两阶段架构，召回层用向量检索，精排用深度模型。", [("那这个方案的", 0), ("延迟是怎么优化的？", 1.6)]),
 ("half_followup_02", "zh", "你为什么选择用 Redis 做缓存？", "主要是读多写少，Redis 的延迟低，而且数据结构丰富，用起来比较方便。", [("所以你刚才说的那个，", 0), ("为什么不用本地缓存？", 1.4)]),
 ("half_followup_03", "zh", "这个项目的数据规模有多大？", "日志每天大概两个 T，样本量在十亿级别。", [("嗯，那如果", 0), ("数据量再大十倍呢？", 1.8)]),
 ("half_followup_04", "en", "Which message queue did you use?", "We used Kafka because of its throughput and the ecosystem around it.", [("So when you said you used Kafka,", 0), ("why not Pulsar?", 1.5)]),
 ("half_followup_05", "zh", "你们是怎么评估模型效果的？", "离线看 AUC 和召回率，线上做 A/B 实验看点击率和停留时长。", [("那你刚才提到的那个指标，", 0), ("具体是怎么算出来的？", 2.2)]),
]
# ---------------------------------------------------------------- 4. 无疑问词的指令式提问
im = [
 ("imperative_01", "zh", "讲讲你的项目。"),
 ("imperative_02", "zh", "说一下你的优势。"),
 ("imperative_03", "zh", "请你介绍一下自己。"),
 ("imperative_04", "en", "Walk me through your resume."),
 ("imperative_05", "en", "Tell me about a time you led a team."),
 ("imperative_06", "zh", "给我们讲讲你对分布式事务的理解。"),
]
# ---------------------------------------------------------------- 5. 寒暄和陈述（不应回答）
cc = [
 ("chitchat_01", "zh", "好的，我们开始吧。", "好的，谢谢。"),
 ("chitchat_02", "zh", "嗯，你的简历我看过了，整体不错。", None),
 ("chitchat_03", "zh", "不错，这个想法挺有意思的。", "谢谢您。"),
 ("chitchat_04", "zh", "好，那我们进入下一个环节。", None),
 ("chitchat_05", "en", "Thanks for joining us today, we will get started in a moment.", "Thank you, happy to be here."),
 ("chitchat_06", "en", "OK, that makes sense, thank you for the explanation.", None),
 ("chitchat_07", "zh", "好的，我记一下，你继续。", None),
]
# ---------------------------------------------------------------- 6. 我方插话/抢答
mi = [
 ("me_interrupt_01", "zh", "你能介绍一下这个项目的整体架构吗？", "好的，这个项目整体分为接入层、服务层和数据层三层。", 0.2, "我在问题说完后 0.2 秒内就开始回答"),
 ("me_interrupt_02", "zh", None, "对，我来说一下这个问题，瓶颈主要在数据库的写入。", None, "我在问题说到一半时插话"),
 ("me_interrupt_03", "zh", "你说说这个方案的缺点。", "这个我了解，主要有三点，第一是成本，第二是复杂度。", 0.6, "我在问题说完后 0.6 秒抢答"),
 ("me_interrupt_04", "zh", "你平时是怎么保证代码质量的？", "这个我比较熟悉，我们团队有严格的代码评审和单元测试。", 0.4, "我在问题说完后 0.4 秒抢答"),
 ("me_interrupt_05", "en", "Could you walk me through the architecture?", "Sure, so the architecture has three layers, the gateway, the services and the storage.", 0.3, "我在问题说完后 0.3 秒开始回答"),
]
# ---------------------------------------------------------------- 7. 对方说到一半我插“嗯”
bc = [
 ("backchannel_01", "zh", [("我想了解一下，你在这个项目里", 0), ("具体负责的是哪一个模块？", 1.4)], "嗯"),
 ("backchannel_02", "zh", [("你刚才提到用了图神经网络。", 0), ("那它相比传统的协同过滤优势在哪里？", 1.2)], "对。"),
 ("backchannel_03", "en", [("You mentioned you used Redis.", 0), ("How did you handle cache invalidation?", 1.3)], "Right."),
 ("backchannel_04", "zh", [("这个问题比较开放。", 0), ("你觉得推荐系统最难的地方是什么？", 1.0)], "好的"),
]
# ---------------------------------------------------------------- 8. 外放回声
ec = [
 ("echo_01", "zh", [("你能介绍一下你的项目吗？", 0)]),
 ("echo_02", "zh", [("请讲讲你最有成就感的一件事。", 0)]),
 ("echo_03", "zh", [("你在团队里遇到过冲突吗？", 0), ("是怎么处理的？", 1.1)]),
 ("echo_04", "en", [("What is the hardest bug you have ever fixed?", 0)]),
 ("echo_05", "zh", [("你是怎么理解 microservice 的？", 0)]),
]
# ---------------------------------------------------------------- 9. 中英混杂
ml = [
 ("mixed_01", "你在项目里用的 transformer 和 attention 机制是怎么 work 的？"),
 ("mixed_02", "这个 pipeline 里 latency 的瓶颈在哪里？"),
 ("mixed_03", "能不能讲讲你对 microservice 和 monolith 的 trade-off 的理解？"),
 ("mixed_04", "你们的 A/B test 是怎么设计的，metric 用的是 CTR 还是 retention？"),
 ("mixed_05", "说一下你对 CAP theorem 的理解。"),
]
# ---------------------------------------------------------------- 10. 英文提问
en = [
 ("english_01", "Could you tell me about a challenging project you worked on?"),
 ("english_02", "What is your biggest weakness?"),
 ("english_03", "Why do you want to join our company?"),
 ("english_04", "How would you design a rate limiter?"),
]
# ---------------------------------------------------------------- 11. 长技术题（多句、句间停顿）
lt = [
 ("long_technical_01", "zh", [("给定一个整数数组，找出其中和为目标值的两个数。", 0), ("要求时间复杂度低于 O(n²)。", 1.0), ("请你给出思路？", 1.1)]),
 ("long_technical_02", "zh", [("假设你要设计一个短链接服务。", 0), ("日活一千万，读写比是一百比一。", 1.9), ("你会怎么设计存储和缓存？", 1.0)]),
 ("long_technical_03", "en", [("Imagine you are building a chat service.", 0), ("It needs to support ten million concurrent users.", 1.2), ("How would you design the message delivery?", 1.6)]),
]

AUDIO_IDS = {"think_pause_01": {"noise": True, "echo": False}, "multi_question_01": {"noise": False, "echo": False},
             "imperative_01": {"noise": True, "echo": False}, "imperative_04": {"noise": False, "echo": False},
             "mixed_01": {"noise": True, "echo": False}, "mixed_03": {"noise": False, "echo": False},
             "english_01": {"noise": False, "echo": False}, "echo_01": {"noise": False, "echo": True},
             "me_interrupt_01": {"noise": False, "echo": False}, "backchannel_01": {"noise": False, "echo": False}}

def build_all(durfn):
    """durfn(text, speaker, dialog_id) -> 秒。音频对话用真实合成时长，其余用估计值。"""
    out = []
    def D(id, cat, lang, desc):
        return Dialog(id, cat, lang, desc, AUDIO_IDS.get(id), durfn=lambda t, sp, _i=id: durfn(t, sp, _i))
    for id, lang, setup, gap, q in tp:
        d = D(id, "think_pause", lang, "对方先说半句并停顿，再说出真正的问题；停顿期间不应触发")
        d.ask([(setup, 0), (q, gap)], note=f"停顿 {gap}s"); d.reply("好的，这个问题我来说一下，主要有几个方面。" if lang == "zh" else "Sure, let me explain that in a few points.")
        out.append(d)
    for id, lang, segs in mq:
        d = D(id, "multi_question", lang, "对方连珠式提出多个问题；应在最后一问说完后触发一次")
        d.ask(segs, note="连珠多问"); d.reply("好的，我一个一个来回答。" if lang == "zh" else "Sure, let me answer them one by one.")
        out.append(d)
    for id, lang, q1, a1, segs in hf:
        d = D(id, "half_followup", lang, "先有一问一答，随后对方说半截追问并停顿，再补完")
        d.ask([(q1, 0)]); d.reply(a1)
        d.ask(segs, pause=1.5, note="半截追问"); d.reply("这个问题我想一下，大致是这样的。" if lang == "zh" else "Let me think, roughly it works like this.")
        out.append(d)
    for id, lang, text in im:
        d = D(id, "imperative", lang, "没有疑问词/问号的指令式提问，应回答")
        d.ask([(text, 0)], note="指令式"); d.reply("好的，我先从整体说起。" if lang == "zh" else "Sure, let me start from the big picture.")
        out.append(d)
    for id, lang, text, my in cc:
        d = D(id, "chitchat", lang, "寒暄、陈述、过渡语，不需要回答")
        d.ask([(text, 0)], should=False, note="寒暄/陈述")
        if my: d.reply(my, pause=1.2)
        out.append(d)
    for id, lang, q, a, off, note in mi:
        d = D(id, "me_interrupt", lang, "我方在问题说完前后很快开口，不应再触发")
        if q is None:
            d.ask([("你们这个系统的瓶颈", 0), ("主要在哪里？", 1.0)], should=False, note=note)
            # 我在第二段说到一半时插话
            d.me_at(a, -0.6)
        else:
            d.ask([(q, 0)], should=False, note=note); d.me_at(a, off)
        out.append(d)
    for id, lang, segs, back in bc:
        d = D(id, "backchannel", lang, "对方的长问题说到一半，我插一句很短的附和；仍应在问题说完后触发")
        d.ask(segs, note="中途附和：" + back)
        mid = d.expected[-1]["turn_start"]
        first_end = [e for e in d.events if e["speaker"] == "对方"][0]["end"]
        d.seg_at("我", back, first_end + segs[1][1] / 2 - 0.1, kind="speech")
        d.reply("好的，我来回答这个问题。" if lang == "zh" else "Sure, let me answer that.")
        out.append(d)
    for id, lang, segs in ec:
        d = D(id, "echo", lang, "外放回声：对方的话在“我”通道 0.3 秒后重复出现；应回答，且回声不应被当成我在说话")
        d.ask(segs, echo=True, note="外放回声")
        d.reply("好的，我来回答。" if lang == "zh" else "Sure, let me answer.")
        out.append(d)
    for id, text in ml:
        d = D(id, "mixed_lang", "mixed", "中英混杂的提问")
        d.ask([(text, 0)], note="中英混杂"); d.reply("好的，我来解释一下。")
        out.append(d)
    for id, text in en:
        d = D(id, "english", "en", "英文提问")
        d.ask([(text, 0)], note="英文"); d.reply("Sure, let me explain.")
        out.append(d)
    for id, lang, segs in lt:
        d = D(id, "long_technical", lang, "多句长题，句间有停顿；应在全部说完后触发")
        d.ask(segs, note="长技术题"); d.reply("好的，我先想一下思路。" if lang == "zh" else "OK, let me think about the approach first.")
        out.append(d)
    # ---- 12. 完整面试（多轮）
    d = D("full_interview_01", "full_interview", "zh", "完整中文面试片段：寒暄、自我介绍、项目、追问、反问")
    d.ask([("好的，我们开始吧。", 0)], should=False, note="寒暄"); d.reply("好的，谢谢。", 1.0)
    d.ask([("请先做个自我介绍。", 0)], pause=1.5, note="指令式"); d.reply("我叫小明，硕士毕业，做了两年推荐系统方向的研究和工程。", 2.2)
    d.ask([("嗯，不错。", 0)], should=False, pause=1.5, note="评价"); d.reply("谢谢。", 1.0)
    d.ask([("你在这个项目里最大的挑战是什么？", 0)], pause=1.5, note="提问"); d.reply("最大的挑战是线上延迟，我们通过模型蒸馏和缓存把 P99 降到了五十毫秒。", 2.5)
    d.ask([("那你是怎么解决的，", 0), ("效果怎么样？", 1.5)], pause=1.5, note="半截追问"); d.reply("蒸馏之后精度只掉了不到百分之一，吞吐提升了三倍。", 2.5)
    d.ask([("你有什么想问我们的吗？", 0)], pause=1.5, note="反问"); d.reply("我想了解一下团队目前最想解决的问题是什么。", 2.5)
    d.ask([("好的，今天就到这里，谢谢你的时间。", 0)], should=False, pause=1.5, note="结束语")
    out.append(d)
    d = D("full_interview_02", "full_interview", "mixed", "完整中英混杂面试片段")
    d.ask([("Hi，欢迎你，我们先聊聊。", 0)], should=False, note="寒暄"); d.reply("Hi，谢谢。", 1.0)
    d.ask([("你能讲讲 transformer 在推荐里的应用吗？", 0)], pause=1.5, note="混杂提问"); d.reply("可以，transformer 主要用来建模用户的行为序列。", 2.5)
    d.ask([("那 attention 的 complexity 怎么优化？", 0)], pause=1.6, note="混杂追问"); d.reply("我们用了 linear attention 和 sparse pattern。", 2.5)
    d.ask([("嗯，这个思路挺有意思。", 0)], should=False, pause=1.5, note="评价"); d.reply("谢谢。", 1.0)
    d.ask([("再说一下你们怎么做 online serving。", 0)], pause=1.5, note="指令式"); d.reply("在线我们用 Triton 做 batch inference。", 2.5)
    d.ask([("好，我们进入下一个环节。", 0)], should=False, pause=1.5, note="过渡")
    out.append(d)
    d = D("full_interview_03", "full_interview", "en", "完整英文面试片段")
    d.ask([("Thanks for joining us today.", 0)], should=False, note="寒暄"); d.reply("Thank you, glad to be here.", 1.0)
    d.ask([("Tell me about yourself.", 0)], pause=1.5, note="指令式"); d.reply("I am a machine learning engineer with three years of experience in recommendation.", 2.5)
    d.ask([("Why did you choose that approach?", 0)], pause=1.5, note="提问"); d.reply("Mainly because of latency and the amount of data we had.", 2.5)
    d.ask([("OK, I see.", 0)], should=False, pause=1.5, note="附和"); d.reply("Yes.", 1.0)
    d.ask([("And how did you measure success?", 0)], pause=1.5, note="提问"); d.reply("We ran A/B tests and tracked click through rate.", 2.5)
    d.ask([("Do you have any questions for us?", 0)], pause=1.5, note="反问"); d.reply("Yes, what are the biggest challenges for the team right now?", 2.5)
    out.append(d)
    return out

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "estimate"
    if mode == "estimate":
        dialogs = build_all(lambda t, sp, i: est_dur(t))
    else:  # "audio": 读取已合成片段的真实时长
        durs = json.load(open(os.path.join(os.path.dirname(__file__), "audio_durations.json")))
        dialogs = build_all(lambda t, sp, i: durs[i + "|" + sp + "|" + t] if (i in AUDIO_IDS) else est_dur(t))
    os.makedirs(OUT, exist_ok=True)
    plan = {}
    for d in dialogs:
        j = d.finish()
        json.dump(j, open(os.path.join(OUT, d.id + ".json"), "w"), ensure_ascii=False, indent=1)
        if d.id in AUDIO_IDS:
            plan[d.id] = {"audio": AUDIO_IDS[d.id], "events": j["events"]}
    json.dump(plan, open(PLAN, "w"), ensure_ascii=False, indent=1)
    print(len(dialogs), "dialogs written")
