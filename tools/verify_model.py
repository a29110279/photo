#!/usr/bin/env python3
"""驗證匯出的模型包：ONNX 與原始 PyTorch 模型的輸出是否一致，並產生 tokenizer 對照資料。

用法：
  python tools/verify_model.py --model-dir dist/model --cases dist/tokenizer_cases.json

- 比對文字與影像 embedding 的 cosine 相似度（int8 量化後通常 > 0.95）
- 輸出 tokenizer_cases.json，供 test/tokenizer_vocab_test.dart 驗證 Dart 版 tokenizer
"""
import argparse
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch
from PIL import Image
from transformers import ChineseCLIPModel, ChineseCLIPProcessor

TEXTS = [
    "海邊的夕陽",
    "一隻貓",
    "穿紅色衣服的小孩在公園玩",
    "Tokyo 夜景",
    "收據 Receipt 2024",
    "生日蛋糕、蠟燭！",
    "這是一段很長很長的描述文字，用來測試超過長度上限時的截斷行為是否與原始 tokenizer 相同，"
    "所以需要寫得非常非常長才會超過五十二個 token 的限制喔",
]


def features(out):
    return out if isinstance(out, torch.Tensor) else out.pooler_output


def cos(a, b):
    a, b = np.asarray(a).ravel(), np.asarray(b).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def sample_image(size=400):
    """不需外部檔案的測試圖：彩色漸層加幾何圖形。"""
    y, x = np.mgrid[0:size, 0:size]
    img = np.stack([x * 255 // size, y * 255 // size, (x + y) * 127 // size], -1)
    img[size // 4:size // 2, size // 4:size // 2] = [250, 30, 30]
    return Image.fromarray(img.astype(np.uint8))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--model-dir", type=Path, default=Path("dist/model"))
    ap.add_argument("--model", default="OFA-Sys/chinese-clip-vit-base-patch16")
    ap.add_argument("--cases", type=Path, default=Path("dist/tokenizer_cases.json"))
    ap.add_argument("--min-cos", type=float, default=0.95)
    args = ap.parse_args()

    manifest = json.loads((args.model_dir / "manifest.json").read_text(encoding="utf-8"))
    n = manifest["contextLength"]
    model = ChineseCLIPModel.from_pretrained(args.model).eval()
    proc = ChineseCLIPProcessor.from_pretrained(args.model)
    tok = proc.tokenizer
    text_sess = ort.InferenceSession(str(args.model_dir / "text"))
    image_sess = ort.InferenceSession(str(args.model_dir / "image"))

    worst = 1.0
    cases = []
    with torch.no_grad():
        for t in TEXTS:
            enc = tok(t, padding="max_length", max_length=n, truncation=True, return_tensors="np")
            ids = enc["input_ids"].astype(np.int64)
            cases.append({"text": t, "ids": ids[0].tolist()})
            ref = features(model.get_text_features(
                input_ids=torch.from_numpy(ids),
                attention_mask=torch.from_numpy(enc["attention_mask"].astype(np.int64)),
            )).numpy()
            out = text_sess.run(None, {"text": ids})[0]
            c = cos(ref, out)
            worst = min(worst, c)
            print(f"text  {c:.4f}  {t}")

        pixels = proc(images=sample_image(), return_tensors="np")["pixel_values"].astype(np.float32)
        ref = features(model.get_image_features(pixel_values=torch.from_numpy(pixels))).numpy()
        out = image_sess.run(None, {"image": pixels})[0]
        c = cos(ref, out)
        worst = min(worst, c)
        print(f"image {c:.4f}")

    args.cases.parent.mkdir(parents=True, exist_ok=True)
    args.cases.write_text(json.dumps({"contextLength": n, "cases": cases}, ensure_ascii=False, indent=1),
                          encoding="utf-8")
    if worst < args.min_cos:
        raise SystemExit(f"ONNX 與原始模型差異過大：最低 cosine {worst:.4f} < {args.min_cos}")
    print(f"OK：最低 cosine {worst:.4f}")


if __name__ == "__main__":
    main()
