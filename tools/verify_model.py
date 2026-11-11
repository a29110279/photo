#!/usr/bin/env python3
"""驗證匯出的模型包：ONNX 與原始 PyTorch 模型的輸出是否一致，並產生 tokenizer 對照資料。

用法：
  python tools/verify_model.py --model-dir dist/model --cases dist/tokenizer_cases.json

- 比對文字與影像 embedding 的 cosine 相似度
- 輸出 tokenizer_cases.json，供 test/tokenizer_vocab_test.dart 驗證 Dart 版 tokenizer
"""
import argparse
import json
from pathlib import Path

from transformers import ChineseCLIPModel, ChineseCLIPProcessor

from model_check import Reference


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--model-dir", type=Path, default=Path("dist/model"))
    ap.add_argument("--model", default="OFA-Sys/chinese-clip-vit-base-patch16")
    ap.add_argument("--cases", type=Path, default=Path("dist/tokenizer_cases.json"))
    ap.add_argument("--min-cos", type=float, default=0.95)
    args = ap.parse_args()

    manifest = json.loads((args.model_dir / "manifest.json").read_text(encoding="utf-8"))
    n = manifest["contextLength"]
    ref = Reference(ChineseCLIPModel.from_pretrained(args.model).eval(),
                    ChineseCLIPProcessor.from_pretrained(args.model), n)

    print("量化設定：", manifest.get("quantization"))
    worst = 1.0
    for kind in ("text", "image"):
        scores = ref.scores(args.model_dir / kind, kind)
        worst = min(worst, *scores)
        print(kind, " ".join(f"{s:.4f}" for s in scores))

    args.cases.parent.mkdir(parents=True, exist_ok=True)
    args.cases.write_text(json.dumps({"contextLength": n, "cases": ref.cases},
                                     ensure_ascii=False, indent=1), encoding="utf-8")
    if worst < args.min_cos:
        raise SystemExit(f"ONNX 與原始模型差異過大：最低 cosine {worst:.4f} < {args.min_cos}")
    print(f"OK：最低 cosine {worst:.4f}")


if __name__ == "__main__":
    main()
