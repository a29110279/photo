#!/usr/bin/env python3
"""C3 模型 PoC：比較多語 CLIP 模型在自己相簿上的中文提示詞效果。

全程在本機執行，相片不會上傳（僅首次需從 Hugging Face 下載模型權重）。

用法：
  python tools/poc/clip_poc.py --images ~/Pictures/sample --prompts tools/poc/prompts.txt
  # 有標註時可計算 Recall@K（labels.json: {"提示詞": ["檔名1.jpg", ...]}）
  python tools/poc/clip_poc.py --images DIR --prompts FILE --labels labels.json

輸出 poc_report.md：各模型每個提示詞的 Top-K 結果與分數分布（用來校準 App 的相關度門檻）。
"""
import argparse
import json
import time
from pathlib import Path

import torch
from PIL import Image
from transformers import AutoModel, AutoProcessor

DEFAULT_MODELS = [
    "OFA-Sys/chinese-clip-vit-base-patch16",
    "google/siglip-base-patch16-256-multilingual",
    "BAAI/AltCLIP",
]
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".webp", ".heic"}


def features(output):
    """不同版本的 transformers 可能回傳 tensor 或含 pooler_output 的物件。"""
    return output if isinstance(output, torch.Tensor) else output.pooler_output


@torch.no_grad()
def embed_images(model, processor, paths, batch=16):
    out = []
    for i in range(0, len(paths), batch):
        imgs = [Image.open(p).convert("RGB") for p in paths[i:i + batch]]
        inputs = processor(images=imgs, return_tensors="pt")
        out.append(features(model.get_image_features(**inputs)))
    v = torch.cat(out)
    return v / v.norm(dim=-1, keepdim=True)


@torch.no_grad()
def embed_texts(model, processor, texts):
    # SigLIP 訓練時固定補到最大長度，其他模型用一般 padding 即可。
    padding = "max_length" if "siglip" in type(model).__name__.lower() else True
    inputs = processor(text=texts, padding=padding, truncation=True, return_tensors="pt")
    v = features(model.get_text_features(**inputs))
    return v / v.norm(dim=-1, keepdim=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--images", required=True, type=Path)
    ap.add_argument("--prompts", required=True, type=Path, help="每行一個提示詞")
    ap.add_argument("--labels", type=Path, help="標註檔（JSON），用於計算 Recall@K")
    ap.add_argument("--models", nargs="+", default=DEFAULT_MODELS)
    ap.add_argument("--topk", type=int, default=10)
    ap.add_argument("--out", type=Path, default=Path("poc_report.md"))
    args = ap.parse_args()

    paths = sorted(p for p in args.images.rglob("*") if p.suffix.lower() in IMAGE_EXT)
    prompts = [l.strip() for l in args.prompts.read_text(encoding="utf-8").splitlines() if l.strip()]
    labels = json.loads(args.labels.read_text(encoding="utf-8")) if args.labels else {}
    if not paths or not prompts:
        raise SystemExit("找不到圖片或提示詞")
    print(f"{len(paths)} 張圖片、{len(prompts)} 個提示詞")

    report = ["# CLIP 模型 PoC 報告", "", f"圖片數：{len(paths)}", ""]
    for name in args.models:
        print(f"== {name}")
        try:
            model = AutoModel.from_pretrained(name).eval()
            processor = AutoProcessor.from_pretrained(name)
        except Exception as e:  # 單一模型失敗不影響其他模型
            report += [f"## {name}", "", f"載入失敗：{e}", ""]
            continue

        t0 = time.time()
        img = embed_images(model, processor, paths)
        per_image = (time.time() - t0) / len(paths)
        sims = embed_texts(model, processor, prompts) @ img.T

        report += [f"## {name}", "", f"- 每張圖片推論時間（本機 CPU）：{per_image * 1000:.0f} ms",
                   f"- embedding 維度：{img.shape[1]}", ""]
        recalls = []
        for pi, prompt in enumerate(prompts):
            row = sims[pi]
            top = torch.topk(row, min(args.topk, len(paths)))
            names = [paths[i].name for i in top.indices.tolist()]
            report += [f"### {prompt}", "",
                       f"分數分布：max {row.max():.3f}／中位數 {row.median():.3f}／min {row.min():.3f}", ""]
            relevant = set(labels.get(prompt, []))
            if relevant:
                recall = len(relevant & set(names)) / len(relevant)
                recalls.append(recall)
                report.append(f"Recall@{args.topk}：{recall:.2f}")
                report.append("")
            report += [f"{i + 1}. `{n}` {s:.3f}{' ✅' if n in relevant else ''}"
                       for i, (n, s) in enumerate(zip(names, top.values.tolist()))]
            report.append("")
        if recalls:
            report += [f"**平均 Recall@{args.topk}：{sum(recalls) / len(recalls):.3f}**", ""]

    args.out.write_text("\n".join(report), encoding="utf-8")
    print(f"已輸出 {args.out}")


if __name__ == "__main__":
    main()
