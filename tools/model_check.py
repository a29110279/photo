"""匯出與驗證共用：以原始 PyTorch 模型為基準，比對 ONNX 輸出的 cosine 相似度。"""
import numpy as np
import onnxruntime as ort
import torch
from PIL import Image

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


def sample_images(size=400):
    """不需外部檔案的測試圖：漸層、色塊、雜訊紋理。"""
    rng = np.random.default_rng(0)
    y, x = np.mgrid[0:size, 0:size]
    a = np.stack([x * 255 // size, y * 255 // size, (x + y) * 127 // size], -1)
    a[size // 4:size // 2, size // 4:size // 2] = [250, 30, 30]
    b = np.zeros((size, size, 3), np.int64)
    b[: size // 2] = [70, 130, 220]
    b[size // 2:] = [230, 200, 140]
    c = rng.integers(0, 256, (size, size, 3))
    return [Image.fromarray(i.astype(np.uint8)) for i in (a, b, c)]


def pixels(img, size, mean, std):
    """與 App 相同的前處理：直接縮放成 size×size（不裁切）再正規化，回傳 [1,3,S,S]。"""
    arr = np.asarray(img.convert("RGB").resize((size, size), Image.BICUBIC), dtype=np.float32) / 255
    arr = (arr - np.asarray(mean, dtype=np.float32)) / np.asarray(std, dtype=np.float32)
    return arr.transpose(2, 0, 1)[None].copy()


def encode_image(model, pixel_values):
    """影像特徵；輸入不是模型原生解析度時，對位置編碼做內插。"""
    native = model.config.vision_config.image_size
    out = model.vision_model(pixel_values=pixel_values,
                             interpolate_pos_encoding=pixel_values.shape[-1] != native)
    return model.visual_projection(out.pooler_output)


class Reference:
    """原始模型對固定樣本的輸出，供各種 ONNX 變體比對。"""

    def __init__(self, model, processor, context_length, image_size=None):
        ip = processor.image_processor
        image_size = image_size or model.config.vision_config.image_size
        tok = processor.tokenizer
        self.text_inputs, self.text_refs, self.cases = [], [], []
        self.image_inputs, self.image_refs = [], []
        with torch.no_grad():
            for t in TEXTS:
                enc = tok(t, padding="max_length", max_length=context_length,
                          truncation=True, return_tensors="np")
                ids = enc["input_ids"].astype(np.int64)
                self.cases.append({"text": t, "ids": ids[0].tolist()})
                self.text_inputs.append(ids)
                self.text_refs.append(features(model.get_text_features(
                    input_ids=torch.from_numpy(ids),
                    attention_mask=torch.from_numpy(enc["attention_mask"].astype(np.int64)),
                )).numpy())
            for img in sample_images():
                px = pixels(img, image_size, ip.image_mean, ip.image_std)
                self.image_inputs.append(px)
                self.image_refs.append(encode_image(model, torch.from_numpy(px)).numpy())

    def scores(self, onnx_path, kind):
        """回傳每個樣本的 cosine（kind 為 'text' 或 'image'）。"""
        sess = ort.InferenceSession(str(onnx_path))
        inputs, refs = ((self.text_inputs, self.text_refs) if kind == "text"
                        else (self.image_inputs, self.image_refs))
        return [cos(r, sess.run(None, {kind: x})[0]) for x, r in zip(inputs, refs)]
