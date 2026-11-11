#!/usr/bin/env python3
"""匯出人臉特徵模型（O12 人物分群），輸出 ONNX + face_manifest.json。

模型：facenet-pytorch 的 InceptionResnetV1（VGGFace2 預訓練），輸入 160×160 RGB，
正規化為 (x - 127.5) / 128，輸出已 L2 正規化的 512 維向量。

加上 --quantize 時嘗試 int8 動態量化，與原始模型比對 cosine，
通過 --min-cos 才採用，否則保留 fp32。

用法：
  python tools/export_face_model.py --out dist/face --quantize
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort
import torch
from facenet_pytorch import InceptionResnetV1

SIZE = 160


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def samples(n=6):
    """不需外部檔案的測試輸入：雜訊與漸層。"""
    rng = np.random.default_rng(0)
    out = []
    for i in range(n):
        if i % 2:
            x = rng.uniform(0, 255, (1, 3, SIZE, SIZE))
        else:
            g = np.linspace(0, 255, SIZE)
            x = np.stack([np.add.outer(g, g * (j + 1) / 3) % 256 for j in range(3)])[None]
        out.append(((x - 127.5) / 128).astype(np.float32))
    return out


def min_cos(path, refs, inputs):
    sess = ort.InferenceSession(str(path))
    worst = 1.0
    for x, r in zip(inputs, refs):
        y = sess.run(None, {"face": x})[0].ravel()
        worst = min(worst, float(y @ r / (np.linalg.norm(y) * np.linalg.norm(r))))
    return worst


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--out", type=Path, default=Path("dist/face"))
    ap.add_argument("--quantize", action="store_true")
    ap.add_argument("--min-cos", type=float, default=0.98)
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    model = InceptionResnetV1(pretrained="vggface2").eval()
    inputs = samples()
    with torch.no_grad():
        refs = [model(torch.from_numpy(x)).numpy().ravel() for x in inputs]

    fp32 = args.out / "face.fp32.onnx"
    with torch.no_grad():
        torch.onnx.export(model, torch.zeros(1, 3, SIZE, SIZE), str(fp32),
                          input_names=["face"], output_names=["embedding"],
                          opset_version=17, dynamo=False)
    base = min_cos(fp32, refs, inputs)
    print(f"fp32: min cos {base:.4f}, {fp32.stat().st_size / 1e6:.0f} MB")
    if base < 0.999:
        raise SystemExit(f"fp32 與原始模型不一致（{base:.4f}）")

    final = args.out / "face"
    chosen = "fp32"
    if args.quantize:
        from onnxruntime.quantization import QuantType, quantize_dynamic
        q = args.out / "face.u8.onnx"
        quantize_dynamic(str(fp32), str(q), weight_type=QuantType.QUInt8)
        score = min_cos(q, refs, inputs)
        print(f"u8: min cos {score:.4f}, {q.stat().st_size / 1e6:.0f} MB")
        if score >= args.min_cos:
            chosen = f"u8 (cos {score:.4f})"
            q.replace(final)
            fp32.unlink()
        else:
            q.unlink()
    if chosen == "fp32":
        fp32.replace(final)

    manifest = {
        "version": f"facenet-vggface2-{chosen.split(' ')[0]}",
        "inputSize": SIZE,
        "mean": 127.5,
        "scale": 128.0,
        "embeddingDim": 512,
        "quantization": chosen,
        "files": {"face": {"url": "face", "sha256": sha256(final), "size": final.stat().st_size}},
    }
    (args.out / "face_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
