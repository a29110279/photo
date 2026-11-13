#!/usr/bin/env python3
"""評估「換較小影像模型」對中文搜尋準確度的影響（文字 → 圖片檢索）。

資料：XTD10 中文版（1000 張 MSCOCO 圖片，每張一句人工翻譯的中文描述）。
同時以 OpenCC 轉成台灣繁體再測一次，因為 App 的提示詞是繁體中文。
指標：Recall@K —— 用描述去搜 1000 張圖，正確那張排在前 K 名的比例。

比較對象：
  - 目前的 Chinese-CLIP ViT-B/16（224px），以及只降低輸入解析度的版本
  - App 實際打包的 int8 ONNX（若有提供 --onnx-dir）
  - 影像端改用 ViT-B/32 的中文／多語模型、Chinese-CLIP RN50

用法：python tools/poc/eval_zh_retrieval.py --out eval_report.md [--onnx-dir assets/model]
"""
import argparse
import concurrent.futures as cf
import json
import os
import time
import traceback
from pathlib import Path

import numpy as np
import requests
import torch
from PIL import Image

XTD = "https://raw.githubusercontent.com/adobe-research/Cross-lingual-Test-Dataset-XTD10/main/XTD10/"
COCO = "http://images.cocodataset.org/{split}/{name}"
CN_CLIP = "OFA-Sys/chinese-clip-vit-base-patch16"
TAIYI = "IDEA-CCNL/Taiyi-CLIP-Roberta-102M-Chinese"
OPENAI_B32 = "openai/clip-vit-base-patch32"
MULTI_B32 = "sentence-transformers/clip-ViT-B-32-multilingual-v1"

torch.set_num_threads(4)


def feats(out):
    return out if isinstance(out, torch.Tensor) else out.pooler_output


def norm(x):
    x = np.asarray(x, dtype=np.float32)
    return x / np.linalg.norm(x, axis=1, keepdims=True)


def recall(text, image):
    sims = norm(text) @ norm(image).T
    n = len(sims)
    correct = sims[np.arange(n), np.arange(n)][:, None]
    ranks = (sims > correct).sum(1)
    return {k: float((ranks < k).mean() * 100) for k in (1, 5, 10)}


def download(names, root):
    root.mkdir(parents=True, exist_ok=True)

    def one(name):
        path = root / name
        if path.exists():
            return
        split = "train2014" if "train2014" in name else "val2014"
        for attempt in range(4):
            try:
                r = requests.get(COCO.format(split=split, name=name), timeout=60)
                r.raise_for_status()
                path.write_bytes(r.content)
                return
            except Exception:
                if attempt == 3:
                    raise
                time.sleep(2 * (attempt + 1))

    with cf.ThreadPoolExecutor(16) as pool:
        list(pool.map(one, names))


def batches(seq, n):
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def load(paths):
    return [Image.open(p).convert("RGB") for p in paths]


def time_single(fn, x, runs=8):
    """單張推論的平均毫秒數（4 執行緒 CPU，先暖機）。"""
    with torch.no_grad():
        fn(x)
        t = time.perf_counter()
        for _ in range(runs):
            fn(x)
    return (time.perf_counter() - t) / runs * 1000


def write_report(rows, out):
    base = next((r for r in rows if r[0].endswith("（目前）") and r[2]), None)
    lines = [
        "# 中文圖文檢索評估（XTD10-zh，1000 張圖 × 1000 句描述）", "",
        "Recall@K：用中文描述搜尋，正確的那張圖排在前 K 名的比例（%，越高越好）。",
        "耗時為 GitHub 伺服器（x86、4 執行緒、未量化）上單張影像推論的毫秒數，只用來看相對速度。", "",
        "| 模型 | 影像端 | 耗時 ms | 相對速度 | 繁體 R@1 | 繁體 R@5 | 繁體 R@10 | 簡體 R@1 | 簡體 R@5 | 簡體 R@10 | 備註 |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for name, side, ms, rs, rt, note in rows:
        if ms is None:
            lines.append(f"| {name} | | | | | | | | | | {note} |")
            continue
        speed = f"{base[2] / ms:.1f}×" if base else ""
        lines.append(
            f"| {name} | {side} | {ms:.0f} | {speed} | {rt[1]:.1f} | {rt[5]:.1f} | {rt[10]:.1f} "
            f"| {rs[1]:.1f} | {rs[5]:.1f} | {rs[10]:.1f} | {note} |")
    report = "\n".join(lines) + "\n"
    out.write_text(report, encoding="utf-8")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(report)
    print("\n===== REPORT =====\n" + report)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--out", type=Path, default=Path("eval_report.md"))
    ap.add_argument("--cache", type=Path, default=Path("eval_cache"))
    ap.add_argument("--onnx-dir", type=Path, action="append", default=[],
                    help="要一併評估的模型包資料夾（image、text、manifest.json），可重複指定")
    ap.add_argument("--quick", action="store_true",
                    help="只評估目前模型、--resolutions 指定的解析度與 --onnx-dir 的模型包")
    ap.add_argument("--resolutions", type=int, nargs="+", default=[224, 192, 160, 128])
    ap.add_argument("--limit", type=int, default=0, help="只取前 N 筆（除錯用）")
    args = ap.parse_args()

    names = requests.get(XTD + "test_image_names.txt", timeout=60).text.split()
    hans = [l.strip() for l in requests.get(XTD + "test_1kcaptions_zh.txt", timeout=60)
            .content.decode("utf-8").splitlines() if l.strip()]
    assert len(names) == len(hans), (len(names), len(hans))
    if args.limit:
        names, hans = names[:args.limit], hans[:args.limit]
    from opencc import OpenCC
    hant = [OpenCC("s2twp").convert(t) for t in hans]
    print(f"{len(names)} 筆；範例：{hans[0]} ／ {hant[0]}")
    download(names, args.cache / "images")
    paths = [args.cache / "images" / n for n in names]

    rows = []  # (名稱, 影像端說明, ms, {簡體 recall}, {繁體 recall}, 備註)

    def add(name, image_side, ms, image_emb, text_fn, note=""):
        r_hans = recall(text_fn(hans), image_emb)
        r_hant = recall(text_fn(hant), image_emb)
        rows.append((name, image_side, ms, r_hans, r_hant, note))
        print(f"{name}: {ms:.0f} ms  簡 {r_hans}  繁 {r_hant}", flush=True)

    def attempt(label, fn):
        try:
            fn()
        except Exception as e:
            traceback.print_exc()
            rows.append((label, "", None, None, None, f"失敗：{type(e).__name__}: {str(e)[:120]}"))

    # ---- Chinese-CLIP ViT-B/16：224px 與降低解析度 ----
    from transformers import ChineseCLIPModel, ChineseCLIPProcessor
    cn = ChineseCLIPModel.from_pretrained(CN_CLIP).eval()
    cn_proc = ChineseCLIPProcessor.from_pretrained(CN_CLIP)
    mean = np.array(cn_proc.image_processor.image_mean, dtype=np.float32)
    std = np.array(cn_proc.image_processor.image_std, dtype=np.float32)

    def cn_pixels(imgs, res):
        # 與 App 相同：直接縮放成正方形（不裁切）再正規化。
        arr = np.stack([
            (np.asarray(im.resize((res, res), Image.BICUBIC), dtype=np.float32) / 255 - mean) / std
            for im in imgs])
        return torch.from_numpy(arr.transpose(0, 3, 1, 2).copy())

    def cn_image(px, res):
        out = cn.vision_model(pixel_values=px, interpolate_pos_encoding=(res != 224))
        return cn.visual_projection(out.pooler_output)

    cn_text_cache = {}

    @torch.no_grad()
    def cn_text(texts):
        key = texts[0]
        if key not in cn_text_cache:
            out = []
            for b in batches(texts, 64):
                enc = cn_proc.tokenizer(b, padding=True, truncation=True, max_length=52, return_tensors="pt")
                out.append(feats(cn.get_text_features(**enc)).numpy())
            cn_text_cache[key] = np.concatenate(out)
        return cn_text_cache[key]

    def run_cn(res):
        def go():
            with torch.no_grad():
                emb = np.concatenate([cn_image(cn_pixels(load(b), res), res).numpy()
                                      for b in batches(paths, 32)])
            ms = time_single(lambda x: cn_image(x, res), cn_pixels(load(paths[:1]), res))
            tokens = (res // 16) ** 2
            add(f"Chinese-CLIP ViT-B/16 @{res}px" + ("（目前）" if res == 224 else ""),
                f"ViT-B/16，{tokens} 個影像區塊", ms, emb, cn_text,
                "" if res == 224 else "同一個模型，只降低輸入解析度；文字模型不變")
        attempt(f"Chinese-CLIP ViT-B/16 @{res}px", go)

    for res in args.resolutions:
        run_cn(res)

    # ---- 匯出的 ONNX 模型包（App 實際使用的格式）----
    def run_onnx(onnx_dir):
        import onnxruntime as ort
        manifest = json.loads((onnx_dir / "manifest.json").read_text(encoding="utf-8"))
        so = ort.SessionOptions()
        so.intra_op_num_threads = 4
        img_sess = ort.InferenceSession(str(onnx_dir / "image"), so)
        txt_sess = ort.InferenceSession(str(onnx_dir / "text"), so)
        n, res = manifest["contextLength"], manifest["imageSize"]
        emb, t = [], 0.0
        for p in paths:
            x = cn_pixels(load([p]), res).numpy()
            s = time.perf_counter()
            emb.append(img_sess.run(None, {"image": x})[0][0])
            t += time.perf_counter() - s

        def text(texts):
            out = []
            for q in texts:
                ids = cn_proc.tokenizer(q, padding="max_length", max_length=n, truncation=True,
                                        return_tensors="np")["input_ids"].astype(np.int64)
                out.append(txt_sess.run(None, {"text": ids})[0][0])
            return np.stack(out)

        size_mb = sum((onnx_dir / k).stat().st_size for k in ("image", "text")) / 1e6
        add(f"ONNX 模型包：{manifest['version']}", f"{res}px，{manifest.get('quantization')}",
            t / len(paths) * 1000, np.stack(emb), text, f"App 使用的格式；模型共 {size_mb:.0f} MB")

        # 批次推論：動態量化以整批的數值範圍決定刻度，準確度與速度都要另外量。
        batch = manifest.get("imageBatch", 1)
        if batch > 1:
            emb, t = [], 0.0
            for i in range(0, len(paths), batch):
                x = np.concatenate([cn_pixels(load([p]), res).numpy() for p in paths[i:i + batch]])
                s = time.perf_counter()
                emb.extend(img_sess.run(None, {"image": x})[0])
                t += time.perf_counter() - s
            add(f"同上，批次 {batch} 張", f"{res}px", t / len(paths) * 1000, np.stack(emb), text,
                "索引時一次推論多張；耗時為每張平均")

    for d in args.onnx_dir:
        if (d / "manifest.json").exists():
            attempt(f"ONNX 模型包：{d}", lambda d=d: run_onnx(d))

    if args.quick:
        write_report(rows, args.out)
        return

    # ---- 影像端 ViT-B/32（OpenAI CLIP），配中文／多語文字模型 ----
    b32 = {}

    def b32_image():
        if "emb" not in b32:
            from transformers import CLIPModel, CLIPProcessor
            m = CLIPModel.from_pretrained(OPENAI_B32).eval()
            proc = CLIPProcessor.from_pretrained(OPENAI_B32)
            with torch.no_grad():
                b32["emb"] = np.concatenate([
                    feats(m.get_image_features(**proc(images=load(b), return_tensors="pt"))).numpy()
                    for b in batches(paths, 32)])
            x = proc(images=load(paths[:1]), return_tensors="pt")["pixel_values"]
            b32["ms"] = time_single(lambda v: m.get_image_features(pixel_values=v), x)
        return b32["emb"], b32["ms"]

    def run_taiyi():
        from transformers import BertForSequenceClassification, BertTokenizer
        tok = BertTokenizer.from_pretrained(TAIYI)
        enc = BertForSequenceClassification.from_pretrained(TAIYI).eval()
        emb, ms = b32_image()

        @torch.no_grad()
        def text(texts):
            return np.concatenate([
                enc(**tok(b, padding=True, truncation=True, max_length=64, return_tensors="pt")).logits.numpy()
                for b in batches(texts, 64)])

        add("Taiyi-CLIP（中文 RoBERTa）+ ViT-B/32", "ViT-B/32，49 個影像區塊", ms, emb, text,
            "中文專用；文字端為 BERT 詞表，可沿用 App 的 tokenizer")
    attempt("Taiyi-CLIP + ViT-B/32", run_taiyi)

    def run_multi():
        from sentence_transformers import SentenceTransformer
        st = SentenceTransformer(MULTI_B32, device="cpu")
        emb, ms = b32_image()
        add("clip-ViT-B-32-multilingual-v1", "ViT-B/32，49 個影像區塊", ms, emb,
            lambda texts: st.encode(texts, batch_size=64, convert_to_numpy=True),
            "多語（DistilBERT）；tokenizer 需另外實作區分大小寫的版本")
    attempt("clip-ViT-B-32-multilingual-v1", run_multi)

    # ---- Chinese-CLIP RN50（官方 cn_clip 套件）----
    def run_rn50():
        import cn_clip.clip as cnclip
        from cn_clip.clip import load_from_name
        m, preprocess = load_from_name("RN50", device="cpu", download_root=str(args.cache / "cn_clip"))
        m = m.float().eval()
        with torch.no_grad():
            emb = np.concatenate([
                m.encode_image(torch.stack([preprocess(im) for im in load(b)])).numpy()
                for b in batches(paths, 32)])

            def text(texts):
                return np.concatenate([m.encode_text(cnclip.tokenize(b)).numpy() for b in batches(texts, 64)])

            ms = time_single(m.encode_image, preprocess(load(paths[:1])[0]).unsqueeze(0))
            add("Chinese-CLIP RN50", "ResNet-50（卷積網路）", ms, emb, text,
                "同系列的小模型；文字端為 3 層 RBT3，tokenizer 與目前相同")
    attempt("Chinese-CLIP RN50", run_rn50)

    write_report(rows, args.out)


if __name__ == "__main__":
    main()
