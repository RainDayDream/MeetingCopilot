#!/usr/bin/env python3
"""回答质量评测（可选，默认关闭）。EVAL_QUALITY=1 且提供 API 配置时才由 scripts/eval.sh 调用。

流程：读取 .partial/quality_prompts.json（由 EvalQualityPromptsTests 生成的 10 个固定问题的提示词）
 → 用被测的 OpenAI 兼容接口生成回答 → 用独立的 `claude -p` 按 eval/rubric.md 打分 → 写 .partial/quality.json

环境变量：EVAL_LLM_BASE_URL（如 https://api.deepseek.com/v1）、EVAL_LLM_MODEL、EVAL_LLM_KEY。Key 只从环境变量读取，不写入任何文件。
"""
import json, os, subprocess, sys, urllib.request

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PART = os.path.join(ROOT, "eval", "results", ".partial")
DIMS = ["relevance", "usability", "conciseness", "consistency", "honesty"]

def skip(reason):
    json.dump({"status": "skipped", "reason": reason}, open(os.path.join(PART, "quality.json"), "w"), ensure_ascii=False)
    print("[quality] skipped:", reason)
    sys.exit(0)

def chat(base, model, key, system, user):
    req = urllib.request.Request(base.rstrip("/") + "/chat/completions", method="POST",
        data=json.dumps({"model": model, "temperature": 0, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["choices"][0]["message"]["content"]

def judge(rubric, case, answer):
    prompt = (rubric + "\n\n---\n【对话记录与面试官当前问题】\n" + case["user"] +
              "\n\n【面试官当前这一轮的问题】\n" + case["question"] + "\n\n【待评分的回答建议】\n" + answer +
              "\n\n请只输出一行 JSON。")
    out = subprocess.run(["claude", "-p"], input=prompt, capture_output=True, text=True, timeout=300).stdout
    s, e = out.find("{"), out.rfind("}")
    return json.loads(out[s:e + 1])

def main():
    base, model, key = (os.environ.get(k) for k in ("EVAL_LLM_BASE_URL", "EVAL_LLM_MODEL", "EVAL_LLM_KEY"))
    if not (base and model and key): skip("未设置 EVAL_LLM_BASE_URL / EVAL_LLM_MODEL / EVAL_LLM_KEY")
    cases = json.load(open(os.path.join(PART, "quality_prompts.json")))
    rubric = open(os.path.join(ROOT, "eval", "rubric.md")).read()
    res, tot = [], {d: 0 for d in DIMS}
    for c in cases:
        ans = chat(base, model, key, c["system"], c["user"])
        sc = judge(rubric, c, ans)
        res.append({"id": c["id"], "answer": ans, "scores": sc})
        for d in DIMS: tot[d] += sc.get(d, 0)
    n = len(res)
    out = {"status": "ok", "model": model, "cases": res, "mean": {d: tot[d] / n for d in DIMS}}
    out["mean_all"] = sum(out["mean"].values()) / len(DIMS)
    json.dump(out, open(os.path.join(PART, "quality.json"), "w"), ensure_ascii=False, indent=1)
    print("[quality] mean", round(out["mean_all"], 2))

main()
