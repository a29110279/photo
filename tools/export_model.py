#!/usr/bin/env python3
"""把 Chinese-CLIP 匯出成 App 使用的模型包（ONNX + vocab + manifest.json）。

用法：
  python tools/export_model.py --out dist/model --quantize
  # 之後把 dist/model/ 內的 4 個檔案上傳到公開靜態空間（例如 GitHub Releases），
  # 再把 manifest.json 的網址填進 App 的「設定 › 模型清單網址」。

manifest.json 內的檔案網址為相對路徑，因此 4 個檔案需放在同一層。
文字模型只吃 input_ids，attention mask 於模型內由 [PAD] 推得，
與 App 端 tokenizer（lib/services/bert_tokenizer.dart）對應。
"""
import argparse
import hashlib
import json
from pathlib import Path

import torch
from transformers import ChineseCLIPModel, ChineseCLIPProcessor

CONTEXT_LENGTH = 52


class ImageEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, image):
        out = self.model.get_image_features(pixel_values=image)
        return out if isinstance(out, torch.Tensor) else out.pooler_output


class TextEncoder(torch.nn.Module):
    def __init__(self, model, pad_id):
        super().__init__()
        self.model = model
        self.pad_id = pad_id

    def forward(self, text):
        mask = (text != self.pad_id).long()
        out = self.model.get_text_features(input_ids=text, attention_mask=mask)
        return out if isinstance(out, torch.Tensor) else out.pooler_output


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--model", default="OFA-Sys/chinese-clip-vit-base-patch16")
    ap.add_argument("--out", type=Path, default=Path("dist/model"))
    ap.add_argument("--quantize", action="store_true", help="動態量化為 int8（檔案約縮為 1/4，準確度略降，需自行驗證）")
    ap.add_argument("--version", help="模型版本字串（預設由模型名稱產生）")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    model = ChineseCLIPModel.from_pretrained(args.model).eval()
    processor = ChineseCLIPProcessor.from_pretrained(args.model)
    ip, tok = processor.image_processor, processor.tokenizer
    size = ip.size.get("height") or ip.size.get("shortest_edge")

    raw = {"image": args.out / "image.fp32.onnx", "text": args.out / "text.fp32.onnx"}
    with torch.no_grad():
        torch.onnx.export(
            ImageEncoder(model), torch.zeros(1, 3, size, size), str(raw["image"]),
            input_names=["image"], output_names=["image_features"], opset_version=17, dynamo=False)
        torch.onnx.export(
            TextEncoder(model, tok.pad_token_id),
            torch.zeros(1, CONTEXT_LENGTH, dtype=torch.long), str(raw["text"]),
            input_names=["text"], output_names=["text_features"], opset_version=17, dynamo=False)

    final = {"image": args.out / "image", "text": args.out / "text", "vocab": args.out / "vocab"}
    for key in ("image", "text"):
        if args.quantize:
            from onnxruntime.quantization import QuantType, quantize_dynamic
            quantize_dynamic(str(raw[key]), str(final[key]), weight_type=QuantType.QUInt8)
            raw[key].unlink()
        else:
            raw[key].replace(final[key])
    vocab = dict(sorted(tok.get_vocab().items(), key=lambda kv: kv[1]))
    final["vocab"].write_text("\n".join(vocab.keys()) + "\n", encoding="utf-8")

    version = args.version or (
        args.model.split("/")[-1] + ("-int8" if args.quantize else "-fp32"))
    manifest = {
        "version": version,
        "embeddingDim": model.config.projection_dim,
        "imageSize": size,
        "mean": list(ip.image_mean),
        "std": list(ip.image_std),
        "centerCrop": bool(getattr(ip, "do_center_crop", False)),
        "contextLength": CONTEXT_LENGTH,
        "files": {
            k: {"url": p.name, "sha256": sha256(p), "size": p.stat().st_size}
            for k, p in final.items()
        },
    }
    (args.out / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
