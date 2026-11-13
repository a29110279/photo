#!/usr/bin/env python3
"""把 Chinese-CLIP 匯出成 App 使用的模型包（ONNX + vocab + manifest.json）。

加上 --quantize 時會嘗試多種 int8 量化設定，與原始模型比對 cosine 相似度，
各編碼器分別採用「通過門檻（--min-cos）中檔案最小」的版本；都不通過則保留 fp32。
注意：比對在執行匯出的機器（CI 為 x86）上進行，手機（ARM）的量化數值可能略有差異。

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

from model_check import Reference, encode_image

CONTEXT_LENGTH = 52
# 影像一次推論的張數上限（App 會實測，較快才使用）。
IMAGE_BATCH = 4


class ImageEncoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, image):
        return encode_image(self.model, image)


def bake_image_size(model, size):
    """把位置編碼內插成 size 的大小並寫回模型，之後就以這個解析度為原生解析度。

    若在匯出時才內插，圖裡會留下一個 Resize（cubic）節點；支援批次（動態軸）後
    它不會被常數折疊掉，而手機上的 ONNX Runtime 1.15 執行這個節點會失敗。
    """
    emb = model.vision_model.embeddings
    if size == emb.image_size:
        return
    n = (size // emb.patch_size) ** 2 + 1
    with torch.no_grad():
        pos = emb.interpolate_pos_encoding(torch.zeros(1, n, emb.embed_dim), size, size)[0]
    emb.position_embedding = torch.nn.Embedding.from_pretrained(pos.clone(), freeze=True)
    emb.register_buffer("position_ids", torch.arange(n).expand((1, -1)), persistent=False)
    emb.image_size = size
    emb.num_patches = n - 1
    emb.num_positions = n
    model.config.vision_config.image_size = size


def forbid_ops(path, ops=("Resize",)):
    """確認圖裡沒有手機上的舊版 ONNX Runtime 跑不動的運算。"""
    import onnx
    found = sorted({n.op_type for n in onnx.load(str(path), load_external_data=False).graph.node
                    if n.op_type in ops})
    if found:
        raise SystemExit(f"{path} 含有不支援的運算：{found}")


class TextEncoder(torch.nn.Module):
    def __init__(self, model, pad_id):
        super().__init__()
        self.model = model
        self.pad_id = pad_id

    def forward(self, text):
        mask = (text != self.pad_id).long()
        out = self.model.get_text_features(input_ids=text, attention_mask=mask)
        return out if isinstance(out, torch.Tensor) else out.pooler_output


def _quant_candidates():
    from onnxruntime.quantization import QuantType
    return [
        ("u8", dict(weight_type=QuantType.QUInt8)),
        ("u8-reduce", dict(weight_type=QuantType.QUInt8, reduce_range=True)),
        ("u8-matmul", dict(weight_type=QuantType.QUInt8, op_types_to_quantize=["MatMul"])),
        ("u8-matmul-pc", dict(weight_type=QuantType.QUInt8, per_channel=True,
                              reduce_range=True, op_types_to_quantize=["MatMul"])),
    ]


def quantize_dynamic(src, dst, **opts):
    from onnxruntime.quantization import quantize_dynamic as q
    q(src, dst, **opts)


QUANT_CANDIDATES = []


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
    ap.add_argument("--quantize", action="store_true", help="嘗試 int8 量化，自動挑選通過門檻者")
    ap.add_argument("--min-cos", type=float, default=0.97, help="量化版與原始模型的最低 cosine 門檻")
    ap.add_argument("--image-size", type=int,
                    help="影像輸入解析度（預設為模型原生的 224）。需為 16 的倍數；"
                         "較小的解析度推論較快、準確度較低")
    ap.add_argument("--version", help="模型版本字串（預設由模型名稱產生）")
    args = ap.parse_args()
    QUANT_CANDIDATES.extend(_quant_candidates() if args.quantize else [])
    args.out.mkdir(parents=True, exist_ok=True)

    model = ChineseCLIPModel.from_pretrained(args.model).eval()
    processor = ChineseCLIPProcessor.from_pretrained(args.model)
    ip, tok = processor.image_processor, processor.tokenizer
    native = ip.size.get("height") or ip.size.get("shortest_edge")
    size = args.image_size or native
    if size % 16:
        raise SystemExit("--image-size 需為 16 的倍數")

    # 基準必須在匯出前計算：TorchScript 匯出會改動模型的注意力實作等內部狀態，
    # 之後再算會讓文字編碼器的基準偏移（fp32 自比只剩約 0.95）。
    ref = Reference(model, processor, CONTEXT_LENGTH, image_size=size) if args.quantize else None

    raw = {"image": args.out / "image.fp32.onnx", "text": args.out / "text.fp32.onnx"}
    bake_image_size(model, size)
    with torch.no_grad():
        torch.onnx.export(
            ImageEncoder(model), torch.zeros(1, 3, size, size), str(raw["image"]),
            input_names=["image"], output_names=["image_features"], opset_version=17, dynamo=False,
            # 影像模型可一次推論多張（索引時批次處理）。
            dynamic_axes={"image": {0: "batch"}, "image_features": {0: "batch"}})
        torch.onnx.export(
            TextEncoder(model, tok.pad_token_id),
            torch.zeros(1, CONTEXT_LENGTH, dtype=torch.long), str(raw["text"]),
            input_names=["text"], output_names=["text_features"], opset_version=17, dynamo=False)

    forbid_ops(raw["image"])
    final = {"image": args.out / "image", "text": args.out / "text", "vocab": args.out / "vocab"}
    chosen = {}
    for key in ("image", "text"):
        chosen[key] = "fp32"
        if ref is not None:
            fp32_min = min(ref.scores(raw[key], key))
            print(f"{key} fp32: min cos {fp32_min:.4f}")
            if fp32_min < 0.999:
                raise SystemExit(f"{key} fp32 與原始模型不一致（{fp32_min:.4f}），匯出流程有問題")
            best = None
            for name, opts in QUANT_CANDIDATES:
                out = args.out / f"{key}.{name}.onnx"
                quantize_dynamic(str(raw[key]), str(out), **opts)
                score = min(ref.scores(out, key))
                nbytes = out.stat().st_size
                print(f"{key} {name}: min cos {score:.4f}, {nbytes / 1e6:.0f} MB")
                if score >= args.min_cos and (best is None or nbytes < best[2]):
                    if best is not None:
                        best[1].unlink()
                    best = (name, out, nbytes, score)
                else:
                    out.unlink()
            if best is not None:
                chosen[key] = f"{best[0]} (cos {best[3]:.4f})"
                best[1].replace(final[key])
                raw[key].unlink()
                continue
        raw[key].replace(final[key])
    print("採用：", chosen)

    # 批次推論：確認一次送多張時與原始模型仍夠接近，通過才在 manifest 標示可用的批次大小。
    image_batch = 1
    if ref is not None:
        try:
            batch_min = min(ref.batch_scores(final["image"], IMAGE_BATCH))
            print(f"image 批次 {IMAGE_BATCH}: min cos {batch_min:.4f}")
            if batch_min >= args.min_cos:
                image_batch = IMAGE_BATCH
            else:
                print("批次推論低於門檻，App 將逐張推論")
        except Exception as e:  # noqa: BLE001 - 不支援批次時逐張推論即可
            print(f"批次推論不可用：{e}")
    vocab = dict(sorted(tok.get_vocab().items(), key=lambda kv: kv[1]))
    final["vocab"].write_text("\n".join(vocab.keys()) + "\n", encoding="utf-8")

    tag = "-".join(v.split(" ")[0] for v in (chosen["image"], chosen["text"]))
    res = "" if size == native else f"-{size}px"
    version = args.version or f'{args.model.split("/")[-1]}{res}-{tag}'
    manifest = {
        "version": version,
        "embeddingDim": model.config.projection_dim,
        "imageSize": size,
        "imageBatch": image_batch,
        "mean": list(ip.image_mean),
        "std": list(ip.image_std),
        "centerCrop": bool(getattr(ip, "do_center_crop", False)),
        "contextLength": CONTEXT_LENGTH,
        "quantization": chosen,
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
