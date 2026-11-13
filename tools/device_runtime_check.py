#!/usr/bin/env python3
"""以手機上的 ONNX Runtime 版本實際執行模型包。

App 使用的 Dart 套件 onnxruntime 1.4.1 內含 ONNX Runtime 1.15.1，而匯出與驗證
用的是最新版；新版能跑的圖，舊版不一定能跑（例如動態尺寸的 cubic Resize）。
這支腳本要在裝有該舊版的環境執行，失敗就不要把模型包進 App。

用法：
  python tools/device_runtime_check.py --model-dir dist/model
"""
import argparse
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--model-dir", type=Path, default=Path("dist/model"))
    ap.add_argument("--runtime", default="1.15.", help="預期的 ONNX Runtime 版本開頭")
    args = ap.parse_args()
    if not ort.__version__.startswith(args.runtime):
        raise SystemExit(f"需要 ONNX Runtime {args.runtime}x，目前是 {ort.__version__}")

    manifest = json.loads((args.model_dir / "manifest.json").read_text(encoding="utf-8"))
    size, dim = manifest["imageSize"], manifest["embeddingDim"]
    rng = np.random.default_rng(0)

    image = ort.InferenceSession(str(args.model_dir / "image"), providers=["CPUExecutionProvider"])
    for batch in sorted({1, manifest.get("imageBatch", 1)}):
        x = rng.standard_normal((batch, 3, size, size)).astype(np.float32)
        out = image.run(None, {"image": x})[0]
        if out.shape != (batch, dim) or not np.isfinite(out).all():
            raise SystemExit(f"image 批次 {batch} 的輸出不正確：{out.shape}")
        print(f"image 批次 {batch}：OK")

    text = ort.InferenceSession(str(args.model_dir / "text"), providers=["CPUExecutionProvider"])
    ids = np.zeros((1, manifest["contextLength"]), dtype=np.int64)
    ids[0, :3] = [101, 3862, 102]
    out = text.run(None, {"text": ids})[0]
    if out.shape != (1, dim) or not np.isfinite(out).all():
        raise SystemExit(f"text 的輸出不正確：{out.shape}")
    print(f"text：OK（ONNX Runtime {ort.__version__}）")


if __name__ == "__main__":
    main()
