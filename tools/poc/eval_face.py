#!/usr/bin/env python3
"""人臉特徵模型評估（O12）：量化有沒有傷到辨識力、分群門檻該設多少。

資料：LFW 的測試配對（500 組同一人、500 組不同人）。以中央裁切模擬 App 的
「偵測框 + 邊界」裁法，比較原始 PyTorch 模型與 App 內建的 ONNX 模型：
同一人／不同人的 cosine 分布，以及各門檻下的命中率與誤判率。

用法：
  python tools/poc/eval_face.py --face-dir dist/face --out face_report.md
"""
import argparse
import json
import os
from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch
from facenet_pytorch import InceptionResnetV1
from PIL import Image
from sklearn.datasets import fetch_lfw_pairs

SIZE = 160
THRESHOLDS = [0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7]


def crops(pairs, side):
    """pairs: [n, 2, H, W, 3]（0~255）→ [n*2, 3, 160, 160]，中央取 side×side 後縮放並正規化。"""
    n, _, h, w, _ = pairs.shape
    y0, x0 = (h - side) // 2, (w - side) // 2
    out = np.empty((n * 2, 3, SIZE, SIZE), np.float32)
    for i, img in enumerate(pairs.reshape(n * 2, h, w, 3)):
        face = Image.fromarray(img[y0:y0 + side, x0:x0 + side].astype(np.uint8))
        arr = np.asarray(face.resize((SIZE, SIZE), Image.BILINEAR), np.float32)
        out[i] = ((arr - 127.5) / 128).transpose(2, 0, 1)
    return out


def normalize(v):
    return v / np.linalg.norm(v, axis=1, keepdims=True)


def describe(name, emb, same):
    """emb: [n*2, d] 已正規化；same: [n] bool。回傳一列報告。"""
    cos = (emb[0::2] * emb[1::2]).sum(1)
    pos, neg = cos[same], cos[~same]
    best = max(THRESHOLDS + list(np.linspace(0.1, 0.8, 71)),
               key=lambda t: ((pos >= t).mean() + (neg < t).mean()) / 2)
    acc = ((pos >= best).mean() + (neg < best).mean()) / 2
    rates = "　".join(f"{t:.2f}: {100 * (pos >= t).mean():.0f}/{100 * (neg >= t).mean():.1f}"
                     for t in THRESHOLDS)
    q = lambda a, p: f"{np.percentile(a, p):.2f}"  # noqa: E731
    print(f"{name}: same p5/p50/p95 {q(pos, 5)}/{q(pos, 50)}/{q(pos, 95)}  "
          f"diff p50/p95/p99 {q(neg, 50)}/{q(neg, 95)}/{q(neg, 99)}  "
          f"best acc {100 * acc:.1f}% @ {best:.2f}", flush=True)
    return (f"| {name} | {q(pos, 5)} / {q(pos, 50)} / {q(pos, 95)} | "
            f"{q(neg, 50)} / {q(neg, 95)} / {q(neg, 99)} | {100 * acc:.1f}% @ {best:.2f} | {rates} |")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--face-dir", type=Path, default=Path("dist/face"))
    ap.add_argument("--out", type=Path, default=Path("face_report.md"))
    args = ap.parse_args()

    data = fetch_lfw_pairs(subset="test", funneled=True, resize=1.0, color=True,
                           slice_=(slice(0, 250), slice(0, 250)))
    pairs = data.pairs.astype(np.float32)
    if pairs.max() <= 1.5:
        pairs *= 255
    same = data.target.astype(bool)
    print(f"{len(same)} 組配對，影像 {pairs.shape[2]}×{pairs.shape[3]}", flush=True)

    model = InceptionResnetV1(pretrained="vggface2").eval()
    manifest = json.loads((args.face_dir / "face_manifest.json").read_text(encoding="utf-8"))
    sess = ort.InferenceSession(str(args.face_dir / "face"))

    rows = []
    # 邊長 120 接近「臉 + 少量邊界」，160 則帶到較多頭髮與背景。
    for side in (120, 140, 160):
        x = crops(pairs, side)
        with torch.no_grad():
            ref = np.concatenate([model(torch.from_numpy(x[i:i + 64])).numpy()
                                  for i in range(0, len(x), 64)])
        rows.append(describe(f"PyTorch fp32，裁切 {side}", normalize(ref), same))
        onnx = np.concatenate([sess.run(None, {"face": x[i:i + 1]})[0] for i in range(len(x))])
        rows.append(describe(f"App 模型 {manifest['version']}，裁切 {side}", normalize(onnx), same))

    report = "\n".join([
        "# 人臉特徵模型評估（LFW 測試配對）",
        "",
        "cosine 分布為各百分位數；「各門檻」為 命中率%／誤判率%（同一人被判為同一人／不同人被判為同一人）。",
        "",
        "| 模型 | 同一人 p5 / p50 / p95 | 不同人 p50 / p95 / p99 | 最佳準確率 | 各門檻 命中/誤判 |",
        "|---|---|---|---|---|",
        *rows, "",
    ])
    args.out.write_text(report, encoding="utf-8")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(report)
    print("\n===== REPORT =====\n" + report)


if __name__ == "__main__":
    main()
