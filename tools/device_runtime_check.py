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

import importlib.util
import struct

import numpy as np


def _clear_execstack():
    """舊版 onnxruntime 的函式庫標示需要可執行堆疊，較新的 glibc 會拒絕載入；先清掉該旗標。"""
    spec = importlib.util.find_spec("onnxruntime")
    if spec is None or not spec.submodule_search_locations:
        return
    for so in Path(spec.submodule_search_locations[0]).glob("capi/onnxruntime_pybind11_state*.so"):
        data = bytearray(so.read_bytes())
        if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:  # 只處理 64 位元 little-endian
            continue
        phoff, = struct.unpack_from("<Q", data, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
        for i in range(phnum):
            base = phoff + i * phentsize
            p_type, p_flags = struct.unpack_from("<II", data, base)
            if p_type == 0x6474E551 and p_flags & 1:  # PT_GNU_STACK 帶 PF_X
                struct.pack_into("<I", data, base + 4, p_flags & ~1)
                so.write_bytes(data)


_clear_execstack()
import onnxruntime as ort  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--model-dir", type=Path, default=Path("dist/model"))
    ap.add_argument("--face-dir", type=Path, help="改為檢查人臉模型（含 face 與 face_manifest.json）")
    ap.add_argument("--runtime", default="1.15.", help="預期的 ONNX Runtime 版本開頭")
    args = ap.parse_args()
    if not ort.__version__.startswith(args.runtime):
        raise SystemExit(f"需要 ONNX Runtime {args.runtime}x，目前是 {ort.__version__}")

    if args.face_dir:
        m = json.loads((args.face_dir / "face_manifest.json").read_text(encoding="utf-8"))
        s = m["inputSize"]
        face = ort.InferenceSession(str(args.face_dir / "face"), providers=["CPUExecutionProvider"])
        x = np.random.default_rng(0).standard_normal((1, 3, s, s)).astype(np.float32)
        out = face.run(None, {face.get_inputs()[0].name: x})[0]
        if out.shape != (1, m["embeddingDim"]) or not np.isfinite(out).all():
            raise SystemExit(f"face 的輸出不正確：{out.shape}")
        print(f"face：OK（ONNX Runtime {ort.__version__}）")
        return

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
