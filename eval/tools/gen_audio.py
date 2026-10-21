#!/usr/bin/env python3
"""一次性生成音频 fixtures：用 macOS `say` 合成 10 段双通道 wav（左=对方/系统音频，右=我/麦克风）。
生成后冻结，不得再运行或修改（见 eval/README.md）。参考文本就是脚本原文。
步骤：1) 逐句合成并测时长 → 2) 用真实时长重排对话时间线并重写这 10 个 dialogs/*.json → 3) 混音成 wav。
"""
import array, json, os, random, re, subprocess, sys, tempfile, wave, math
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_dialogs as G

AUDIO = os.path.join(HERE, "..", "audio")
CJK = re.compile(r"[一-鿿]")
RATE = 16000

def voice_for(text):
    return "Tingting" if CJK.search(text) else "Samantha"

def render(text, speaker, tmp):
    key = re.sub(r"\W+", "_", text)[:40]
    aiff = os.path.join(tmp, f"{speaker}_{abs(hash(text))}.aiff"); wavp = aiff.replace(".aiff", ".wav")
    wpm = "175" if speaker == "对方" else "195"
    subprocess.run(["say", "-v", voice_for(text), "-r", wpm, "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wavp], check=True)
    w = wave.open(wavp, "rb"); n = w.getnframes(); data = array.array("h"); data.frombytes(w.readframes(n)); w.close()
    return data

def trim(data, thr=300):
    """去掉首尾静音，使 say 的时长接近真实说话时长"""
    a, b = 0, len(data)
    while a < b and abs(data[a]) < thr: a += 1
    while b > a and abs(data[b - 1]) < thr: b -= 1
    pad = int(0.05 * RATE)
    return data[max(0, a - pad): min(len(data), b + pad)]

def main():
    plan = json.load(open(os.path.join(HERE, "audio_plan.json")))
    tmp = tempfile.mkdtemp()
    clips, durs = {}, {}
    # 1) 合成每个唯一的 (说话人, 文本)；回声事件用“对方”的合成
    for did, p in plan.items():
        for e in p["events"]:
            sp = "对方" if e["kind"] == "echo" else e["speaker"]
            k = (sp, e["text"])
            if k not in clips: clips[k] = trim(render(e["text"], sp, tmp))
            durs[f'{did}|{e["speaker"]}|{e["text"]}'] = round(len(clips[k]) / RATE, 3)
    json.dump(durs, open(os.path.join(HERE, "audio_durations.json"), "w"), ensure_ascii=False, indent=1)
    # 2) 用真实时长重排时间线，重写这 10 个对话
    subprocess.run([sys.executable, os.path.join(HERE, "gen_dialogs.py"), "audio"], check=True)
    plan = json.load(open(os.path.join(HERE, "audio_plan.json")))
    # 3) 混音
    manifest = {}
    rnd = random.Random(20261016)
    for did, p in plan.items():
        total = max(e["end"] for e in p["events"]) + 2.0
        n = int(total * RATE)
        ch = {"对方": array.array("h", [0]) * n, "我": array.array("h", [0]) * n}
        def put(buf, data, start, gain=1.0):
            i0 = int(start * RATE)
            for i, v in enumerate(data):
                j = i0 + i
                if j >= n: break
                s = buf[j] + int(v * gain)
                buf[j] = max(-32768, min(32767, s))
        for e in p["events"]:
            if e["kind"] == "echo":
                put(ch["我"], clips[("对方", e["text"])], e["start"], 0.35)
            else:
                put(ch[e["speaker"]], clips[(e["speaker"], e["text"])], e["start"])
        if p["audio"]["noise"]:    # 麦克风通道里的键盘敲击声：每簇 2~4 秒，簇内每 0.12~0.35 秒一次，每次 30~50 毫秒
            t = rnd.uniform(0.5, 1.5)
            while t < total - 1:
                for _ in range(rnd.randint(6, 12)):
                    t += rnd.uniform(0.12, 0.35)
                    L = int(rnd.uniform(0.03, 0.05) * RATE)
                    burst = array.array("h", [int(9000 * rnd.uniform(-1, 1) * math.exp(-4.0 * k / L)) for k in range(L)])
                    put(ch["我"], burst, t)
                t += rnd.uniform(2.0, 5.0)
        out = os.path.join(AUDIO, did + ".wav")
        w = wave.open(out, "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(RATE)
        inter = array.array("h", [0]) * (2 * n)
        inter[0::2] = ch["对方"]; inter[1::2] = ch["我"]
        w.writeframes(inter.tobytes()); w.close()
        ref = {"对方": "".join(e["text"] for e in p["events"] if e["speaker"] == "对方" and e["kind"] == "speech"),
               "我": "".join(e["text"] for e in p["events"] if e["speaker"] == "我" and e["kind"] == "speech")}
        manifest[did] = {"file": did + ".wav", "left": "对方", "right": "我", "sample_rate": RATE,
                         "duration": round(total, 2), "mic_noise": p["audio"]["noise"], "echo": p["audio"]["echo"],
                         "reference": ref}
    json.dump(manifest, open(os.path.join(AUDIO, "manifest.json"), "w"), ensure_ascii=False, indent=1)
    print(len(manifest), "wav written;", sum(os.path.getsize(os.path.join(AUDIO, m["file"])) for m in manifest.values()) // 1024, "KB")

main()
