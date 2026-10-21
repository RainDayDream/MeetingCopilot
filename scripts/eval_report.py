#!/usr/bin/env python3
"""汇总评测结果：合并 eval/results/.partial/*.json → eval/results/latest.json，并打印人类可读的表格。
只做汇总与排版，所有指标都是 Swift 评测测试里算出来的。目标值来自 eval/thresholds.json（未确认时仅作参考）。"""
import datetime, glob, json, os, subprocess, sys, unicodedata

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PART = os.path.join(ROOT, "eval", "results", ".partial")
OUT = os.path.join(ROOT, "eval", "results", "latest.json")

def load(name):
    p = os.path.join(PART, name + ".json")
    return json.load(open(p)) if os.path.exists(p) else None

def git(*a):
    try: return subprocess.run(["git", "-C", ROOT, *a], capture_output=True, text=True).stdout.strip()
    except Exception: return ""

def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)

def pad(s, n):
    return s + " " * max(0, n - width(s))

def fmt(v, kind="rate"):
    if v is None: return "-"
    if isinstance(v, bool): return str(v)
    if isinstance(v, int): return str(v)
    if kind == "rate": return f"{v*100:.1f}%"
    if kind == "sec": return f"{v:.2f}s"
    return f"{v:.2f}"

def main():
    trig, ctx, asr, qual = load("trigger"), load("context"), load("asr"), load("quality")
    if trig is None or ctx is None:
        print("缺少触发/上下文结果，评测未成功运行"); sys.exit(1)
    dirty = bool(git("status", "--porcelain"))
    result = {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "git": {"commit": git("rev-parse", "--short", "HEAD"), "branch": git("rev-parse", "--abbrev-ref", "HEAD"), "dirty": dirty},
        "dataset": {"dialogs": len(trig["per_dialog"]), "expected_turns": trig["should_answer"] + trig["non_questions"],
                    "should_answer": trig["should_answer"], "non_questions": trig["non_questions"]},
        "trigger": {k: v for k, v in trig.items() if k != "per_dialog"},
        "trigger_per_dialog": trig["per_dialog"],
        "asr": asr or {"status": "not_run"},
        "context": ctx,
        "quality": qual or {"status": "skipped", "reason": "未启用（EVAL_QUALITY=1 且设置 API 环境变量时才运行）"},
    }
    json.dump(result, open(OUT, "w"), ensure_ascii=False, indent=1)

    th = json.load(open(os.path.join(ROOT, "eval", "thresholds.json")))
    confirmed = th.get("confirmed", False)
    flat = {}
    for k, v in trig.items(): flat["trigger." + k] = v
    for k, v in ctx.items(): flat["context." + k] = v
    if asr and asr.get("status") == "ok":
        for k, v in asr.items(): flat["asr." + k] = v

    rows = [
        ("触发", None, None),
        ("抢答率（问题没说完就触发）", "trigger.premature_rate", "rate"),
        ("漏答率（该答没触发）", "trigger.miss_rate", "rate"),
        ("误答率（不该答却触发调用）", "trigger.false_answer_rate", "rate"),
        ("问题说完→触发 延迟 P50", "trigger.latency_p50_s", "sec"),
        ("问题说完→触发 延迟 P95", "trigger.latency_p95_s", "sec"),
        ("重复触发次数", "trigger.duplicate_triggers", "int"),
        ("游离触发次数", "trigger.stray_triggers", "int"),
        ("ASR（本地 Whisper）", None, None),
        ("中文 CER", "asr.cer_zh", "rate"),
        ("英文 WER", "asr.wer_en", "rate"),
        ("中英混杂 CER", "asr.cer_mixed", "rate"),
        ("“我”通道幻觉句数（10 段合计）", "asr.mic_hallucination_lines", "int"),
        ("外放回声被记为“我”的比例", "asr.echo_leak_rate", "rate"),
        ("单段识别耗时 P50（参考）", "asr.transcribe_latency_p50_s", "sec"),
        ("上下文", None, None),
        ("相邻请求前缀稳定率", "context.prefix_stability", "rate"),
        ("平均提示词字数（系统+用户）", "context.avg_prompt_chars", "num"),
        ("当前这一轮被完整标出", "context.current_question_marked", "rate"),
    ]
    lines = []
    ds = result["dataset"]
    lines.append(f"评测基线  commit {result['git']['commit']}{'*' if dirty else ''}  分支 {result['git']['branch']}   "
                 f"对话 {ds['dialogs']} 段 / 标注轮次 {ds['expected_turns']}（应答 {ds['should_answer']}，不应答 {ds['non_questions']}）")
    lines.append("目标值" + ("已确认" if confirmed else "【建议值，尚未确认】"))
    lines.append("")
    lines.append(pad("指标", 36) + pad("当前", 12) + pad("目标", 12) + "状态")
    lines.append("-" * 70)
    for name, key, kind in rows:
        if key is None:
            lines.append(""); lines.append("■ " + name); continue
        v = flat.get(key)
        t = th["metrics"].get(key)
        target, status = "-", ""
        if t:
            if "max" in t: target = "≤ " + fmt(t["max"], kind if kind != "int" else "int")
            if "min" in t: target = "≥ " + fmt(t["min"], kind)
            if v is not None and not isinstance(v, str):
                ok = (v <= t["max"]) if "max" in t else (v >= t["min"])
                status = "达标" if ok else "未达标"
        lines.append(pad(name, 36) + pad(fmt(v, kind) if v is not None else "-", 12) + pad(target, 12) + status)
    if not asr or asr.get("status") != "ok":
        lines.append("  （ASR 未运行：" + (asr or {}).get("reason", "无结果") + "）")
    lines.append("")
    lines.append("■ 触发按类别（抢答 / 漏答 / 误答 / 重复，样本数）")
    for c, v in sorted(trig["by_category"].items()):
        n = v["should_answer"] + v["non_questions"]
        lines.append("  " + pad(c, 16) + f"抢答 {v['premature']}/{v['should_answer']}  漏答 {v['miss']}/{v['should_answer']}  "
                     f"误答 {v['false_answer']}/{v['non_questions']}  重复 {v['duplicate_triggers']}   (标注 {n})")
    sw = trig.get("sensitivity_sweep", {})
    if sw:
        lines.append("")
        lines.append("■ 自动回答灵敏度对比（参考）")
        for s, label in (("0", "灵敏"), ("2", "稳妥")):
            if s in sw:
                v = sw[s]
                lines.append(f"  {label}: 抢答 {fmt(v.get('premature_rate'))}  漏答 {fmt(v.get('miss_rate'))}  误答 {fmt(v.get('false_answer_rate'))}  P95 {fmt(v.get('latency_p95_s'), 'sec')}")
    if ctx.get("current_question_unmarked"):
        lines.append("")
        lines.append("当前轮未被完整标出的标注：" + "、".join(ctx["current_question_unmarked"]))
    q = result["quality"]
    lines.append("")
    lines.append("■ 回答质量：" + (f"平均 {q['mean_all']:.2f}/5（{q['model']}）" if q.get("status") == "ok" else "跳过 —— " + q.get("reason", "")))
    lines.append("")
    lines.append("完整结果：eval/results/latest.json")
    print("\n".join(lines))

main()
