#!/usr/bin/env python3
"""
修图App 后端服务
- 双模式：免费版(本地AI处理) / 美图工具(付费API)
- 免费版工具: rembg抠图、OpenCV增强/去噪/暗部提升、OCR改字
"""
import os
import json
import subprocess
import tempfile
import shutil
import uuid
import io
import re
import traceback
from pathlib import Path
from datetime import datetime
from flask import Flask, request, jsonify, send_file
from flask_cors import CORS
from PIL import Image, ImageDraw, ImageFont
import numpy as np

app = Flask(__name__)
CORS(app)

# ===================== Config =====================
MEITU_CLI = os.path.expanduser("/home/sandbox/.npm-global/bin/meitu")
UPLOAD_DIR = Path(tempfile.gettempdir()) / "xiutu_uploads"
OUTPUT_DIR = Path(tempfile.gettempdir()) / "xiutu_outputs"
UPLOAD_DIR.mkdir(exist_ok=True)
OUTPUT_DIR.mkdir(exist_ok=True)

# ===================== Free tools imports (lazy) =====================
_rembg = None
_cv2 = None
_pytesseract = None

def _import_rembg():
    global _rembg
    if _rembg is None:
        from rembg import remove as _r
        _rembg = _r
    return _rembg

def _import_cv2():
    global _cv2
    if _cv2 is None:
        import cv2 as _c
        _cv2 = _c
    return _cv2

def _import_tesseract():
    global _pytesseract
    if _pytesseract is None:
        import pytesseract as _t
        # Default tesseract path
        _t.pytesseract.tesseract_cmd = _t.pytesseract.tesseract_cmd or '/usr/bin/tesseract'
        _pytesseract = _t
    return _pytesseract

# ===================== Free Processing Functions =====================

def free_cutout(image_path: str, output_path: str) -> dict:
    """抠图 - 使用rembg本地模型"""
    rembg = _import_rembg()
    with open(image_path, 'rb') as f:
        input_bytes = f.read()
    result_bytes = rembg.remove(input_bytes)
    with open(output_path, 'wb') as f:
        f.write(result_bytes)
    return {"success": True, "explanation": "✅ 免费版抠图完成，已去除背景"}


def free_text_replace(image_path: str, source_words: str, target_words: str, output_path: str) -> dict:
    """改字 - OCR识别位置→inpaint擦除→Pillow写入新字（优化版）"""
    cv2 = _import_cv2()
    pytesseract = _import_tesseract()

    img_cv = cv2.imread(image_path)
    if img_cv is None:
        return {"error": "无法读取图片"}

    h, w = img_cv.shape[:2]

    # 1. OCR识别所有文字位置
    rgb = cv2.cvtColor(img_cv, cv2.COLOR_BGR2RGB)
    pil_img = Image.fromarray(rgb)
    data = pytesseract.image_to_data(pil_img, lang='chi_sim+eng', output_type=pytesseract.Output.DICT)

    # ── 1a. 匹配源文字，同时记录OCR完整文本用于智能分块 ──
    # 存储：(x, y, w, h, ocr_text)
    raw_matches = []
    target_lower = source_words.lower() if source_words else ""

    for i, text in enumerate(data['text']):
        text = text.strip()
        if not text:
            continue
        if target_lower and (target_lower in text.lower() or text.lower() in target_lower):
            x, y, bw, bh = data['left'][i], data['top'][i], data['width'][i], data['height'][i]
            if bw > 5 and bh > 5:
                raw_matches.append((x, y, bw, bh, text))

    # 逐字匹配兜底
    if not raw_matches and source_words:
        for i, text in enumerate(data['text']):
            text = text.strip()
            if not text:
                continue
            for sw_char in source_words:
                if sw_char in text:
                    x, y, bw, bh = data['left'][i], data['top'][i], data['width'][i], data['height'][i]
                    if bw > 5 and bh > 5:
                        raw_matches.append((x, y, bw, bh, text))
                    break

    # ── 1b. 智能分块 ──
    # 如果OCR检测到"贺泽鲜肉"但只要改"贺泽"，只擦除子串区域
    erase_boxes = []
    write_boxes = []
    src_len = len(source_words)

    for x, y, bw, bh, ocr_text in raw_matches:
        ocr_len = len(ocr_text)
        if ocr_len > src_len > 0 and source_words.lower() in ocr_text.lower():
            src_idx = ocr_text.lower().find(source_words.lower())
            if src_idx >= 0:
                char_ratio = src_len / max(ocr_len, 1)
                offset_ratio = src_idx / max(ocr_len, 1)
                seg_w = bw * char_ratio
                seg_x = x + int(bw * offset_ratio)
                seg_pad = int(seg_w * 0.05)
                ex1 = max(0, seg_x - seg_pad)
                ey1 = max(0, y - 2)
                ex2 = min(w, seg_x + int(seg_w) + seg_pad)
                ey2 = min(h, y + bh + 2)
                erase_boxes.append((ex1, ey1, ex2 - ex1, ey2 - ey1))
                write_boxes.append((seg_x, y, int(seg_w), bh, x, y, bw, bh))
            else:
                erase_boxes.append((x, y, bw, bh))
                write_boxes.append((x, y, bw, bh, x, y, bw, bh))
        else:
            erase_boxes.append((x, y, bw, bh))
            write_boxes.append((x, y, bw, bh, x, y, bw, bh))

    # 合并重叠擦除框
    if erase_boxes:
        erase_boxes.sort(key=lambda b: (b[1], b[0]))
        merged = [erase_boxes[0]]
        for box in erase_boxes[1:]:
            last = merged[-1]
            if abs(box[1] - last[1]) < 20 and box[0] - (last[0] + last[2]) < 30:
                nx = min(last[0], box[0])
                ny = min(last[1], box[1])
                nw = max(last[0] + last[2], box[0] + box[2]) - nx
                nh = max(last[1] + last[3], box[1] + box[3]) - ny
                merged[-1] = (nx, ny, nw, nh)
            else:
                merged.append(box)
        erase_boxes = merged

    # ── 2. 采集纯背景颜色 ──
    bg_samples = []
    if erase_boxes:
        for x, y, bw, bh in erase_boxes:
            for dx, dy in [(-10, -10), (bw + 5, -10), (-10, bh + 5), (bw + 5, bh + 5)]:
                cx = x + dx
                cy = y + dy
                if cx >= 0 and cy >= 0 and cx + 10 <= w and cy + 10 <= h:
                    area = img_cv[cy:cy + 10, cx:cx + 10]
                    if area.size > 0:
                        bg_samples.append(np.mean(area.reshape(-1, 3), axis=0))
            if len(bg_samples) < 2:
                pad = max(bh, 20)
                x1_s = max(0, x - pad)
                y1_s = max(0, y - pad)
                x2_s = min(w, x + bw + pad)
                y2_s = min(h, y + bh + pad)
                area = img_cv[y1_s:y2_s, x1_s:x2_s]
                if area.size > 0:
                    bg_samples.append(np.mean(area.reshape(-1, 3), axis=0))

    # ── 3. Inpaint擦除 ──
    mask = np.zeros((h, w), dtype=np.uint8)
    if erase_boxes:
        for x, y, bw, bh in erase_boxes:
            pad = max(6, int(min(bw, bh) * 0.2))
            x1 = max(0, x - pad)
            y1 = max(0, y - pad)
            x2 = min(w, x + bw + pad)
            y2 = min(h, y + bh + pad)
            cv2.rectangle(mask, (x1, y1), (x2, y2), 255, -1)
        max_box_size = max(bh for _, _, _, _ in erase_boxes) if erase_boxes else 20
        inradius = min(max(5, int(max_box_size * 0.22)), 12)
        inpainted = cv2.inpaint(img_cv, mask, inradius, cv2.INPAINT_TELEA)
    else:
        inpainted = img_cv.copy()

    # ── 4. 分析全局背景 ──
    global_bg = np.array([128, 128, 128])
    if bg_samples:
        global_bg = np.mean(bg_samples, axis=0)
    bg_lum = 0.299 * global_bg[2] + 0.587 * global_bg[1] + 0.114 * global_bg[0]
    is_red_bg = global_bg[2] > global_bg[1] * 1.4 and global_bg[2] > global_bg[0] * 1.4

    # ── 5. 写入新文字 ──
    result_rgb = cv2.cvtColor(inpainted, cv2.COLOR_BGR2RGB)
    result_pil = Image.fromarray(result_rgb)
    draw = ImageDraw.Draw(result_pil)

    if target_words and write_boxes:
        _font_cache = {}

        def _get_font(size):
            if size in _font_cache:
                return _font_cache[size]
            for fp in [
                '/usr/share/fonts/HarmonyFont/Harmony-Bold.ttf',
                '/usr/share/fonts/HarmonyFont/Harmony-SemiBold.ttf',
                '/usr/share/fonts/HarmonyFont/Harmony-Medium.ttf',
                '/usr/share/fonts/HarmonyFont/Harmony-Regular.ttf',
                '/usr/share/fonts/SubSetSourceHanSans/SourceHanSansCN-list-label.ttf',
            ]:
                try:
                    f = ImageFont.truetype(fp, size)
                    _font_cache[size] = f
                    return f
                except:
                    continue
            _font_cache[size] = ImageFont.load_default()
            return _font_cache[size]

        for box in write_boxes:
            write_x, write_y, write_w, write_h = box[0], box[1], box[2], box[3]
            orig_x, orig_y, orig_bw, orig_bh = box[4], box[5], box[6], box[7]

            # 文字颜色
            if is_red_bg:
                text_color = (255, 255, 255)
                shadow_color = (30, 30, 30)
            elif bg_lum > 150:
                text_color = (0, 0, 0)
                shadow_color = (180, 180, 180)
            elif bg_lum < 70:
                text_color = (255, 255, 255)
                shadow_color = (20, 20, 20)
            else:
                text_color = (255, 255, 255) if bg_lum < 128 else (0, 0, 0)
                shadow_color = (30, 30, 30) if bg_lum < 128 else (180, 180, 180)

            # 自适应字体
            font_size = max(14, write_h - 2)
            font = _get_font(font_size)
            bbox = draw.textbbox((0, 0), target_words, font=font)
            tw = bbox[2] - bbox[0]
            th = bbox[3] - bbox[1]

            w_ratio = write_w * 0.90 / max(tw, 1)
            h_ratio = write_h * 0.85 / max(th, 1)
            ratio = min(w_ratio, h_ratio, 1.0)
            if ratio < 0.95:
                font_size = max(10, int(font_size * ratio))
                font = _get_font(font_size)
                bbox = draw.textbbox((0, 0), target_words, font=font)
                tw = bbox[2] - bbox[0]
                th = bbox[3] - bbox[1]

            # 居中
            tx = write_x + (write_w - tw) // 2
            ty = write_y + (write_h - th) // 2
            sh_off = max(2, min(4, int(font_size * 0.07)))

            # 阴影 + 正文
            draw.text((tx + sh_off, ty + sh_off), target_words, fill=shadow_color, font=font)
            draw.text((tx, ty), target_words, fill=text_color, font=font)

    result_pil.save(output_path)
    explanation = '✅ 免费版改字完成'
    if source_words and target_words:
        explanation += f'："{source_words}" → "{target_words}"'
    return {"success": True, "explanation": explanation}


def free_denoise(image_path: str, output_path: str) -> dict:
    """去噪 - OpenCV fastNlMeansDenoising"""
    cv2 = _import_cv2()
    img = cv2.imread(image_path)
    if img is None:
        return {"error": "无法读取图片"}
    result = cv2.fastNlMeansDenoisingColored(img, None, 10, 10, 7, 21)
    cv2.imwrite(output_path, result)
    return {"success": True, "explanation": "✅ 免费版去噪完成，已去除图片噪点"}


def free_enhance(image_path: str, output_path: str) -> dict:
    """暗部增强 - CLAHE + 亮度调整"""
    cv2 = _import_cv2()
    img = cv2.imread(image_path)
    if img is None:
        return {"error": "无法读取图片"}
    
    # Convert to LAB and apply CLAHE on L channel
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    l = clahe.apply(l)
    lab = cv2.merge([l, a, b])
    result = cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)
    
    # Also slightly increase saturation
    hsv = cv2.cvtColor(result, cv2.COLOR_BGR2HSV)
    hsv[:, :, 1] = np.clip(hsv[:, :, 1] * 1.15, 0, 255).astype(np.uint8)
    result = cv2.cvtColor(hsv, cv2.COLOR_HSV2BGR)
    
    cv2.imwrite(output_path, result)
    return {"success": True, "explanation": "✅ 免费版暗部增强完成，已提亮暗部细节"}


def free_superres(image_path: str, output_path: str) -> dict:
    """超清 - OpenCV放大+锐化"""
    cv2 = _import_cv2()
    img = cv2.imread(image_path)
    if img is None:
        return {"error": "无法读取图片"}
    
    h, w = img.shape[:2]
    # Up to 2x if small
    if h < 1000 or w < 1000:
        scale = min(2.0, 1500 / min(h, w))
        new_w, new_h = int(w * scale), int(h * scale)
        img = cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_CUBIC)
    
    # Sharpen
    kernel = np.array([[-1, -1, -1],
                       [-1,  9, -1],
                       [-1, -1, -1]]) / 1.0
    result = cv2.filter2D(img, -1, kernel)
    
    cv2.imwrite(output_path, result)
    return {"success": True, "explanation": "✅ 免费版超清完成，已放大并锐化图片"}


def free_grayscale(image_path: str, output_path: str) -> dict:
    """灰度图"""
    cv2 = _import_cv2()
    img = cv2.imread(image_path)
    if img is None:
        return {"error": "无法读取图片"}
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    cv2.imwrite(output_path, gray)
    return {"success": True, "explanation": "✅ 免费版黑白效果完成"}


def free_sepia(image_path: str, output_path: str) -> dict:
    """复古棕色调"""
    cv2 = _import_cv2()
    img = cv2.imread(image_path)
    if img is None:
        return {"error": "无法读取图片"}
    sepia_kernel = np.array([[0.272, 0.534, 0.131],
                             [0.349, 0.686, 0.168],
                             [0.393, 0.769, 0.189]])
    result = cv2.transform(img, sepia_kernel)
    result = np.clip(result, 0, 255).astype(np.uint8)
    cv2.imwrite(output_path, result)
    return {"success": True, "explanation": "✅ 免费版复古滤镜完成"}


def free_rotate(image_path: str, output_path: str) -> dict:
    """顺时针旋转90度"""
    cv2 = _import_cv2()
    img = cv2.imread(image_path)
    if img is None:
        return {"error": "无法读取图片"}
    result = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    cv2.imwrite(output_path, result)
    return {"success": True, "explanation": "✅ 免费版图片旋转完成"}


def free_blur(image_path: str, output_path: str) -> dict:
    """高斯模糊"""
    cv2 = _import_cv2()
    img = cv2.imread(image_path)
    if img is None:
        return {"error": "无法读取图片"}
    result = cv2.GaussianBlur(img, (15, 15), 0)
    cv2.imwrite(output_path, result)
    return {"success": True, "explanation": "✅ 免费版高斯模糊完成"}


# ===================== Free tool router =====================
FREE_TOOLS = {
    "cutout":       {"fn": free_cutout,       "label": "抠图",       "needs_text": False},
    "text-replace": {"fn": free_text_replace,  "label": "改字",       "needs_text": True},
    "denoise":      {"fn": free_denoise,       "label": "去噪",       "needs_text": False},
    "enhance":      {"fn": free_enhance,       "label": "暗部增强",   "needs_text": False},
    "superres":     {"fn": free_superres,      "label": "超清",       "needs_text": False},
    "grayscale":    {"fn": free_grayscale,     "label": "黑白效果",   "needs_text": False},
    "sepia":        {"fn": free_sepia,         "label": "复古滤镜",   "needs_text": False},
    "rotate":       {"fn": free_rotate,        "label": "旋转",       "needs_text": False},
    "blur":         {"fn": free_blur,          "label": "模糊",       "needs_text": False},
}


def classify_free_tool(user_text: str) -> dict:
    """Classify user text into a free tool"""
    text = user_text.lower()
    
    if any(kw in text for kw in ["抠图", "去背景", "透明", "扣图", "cutout"]):
        return {"tool": "cutout", "params": {}, "explanation": "免费抠图"}
    
    if any(kw in text for kw in ["改字", "改文字", "替换文字", "改成", "改为", "text", "替换"]):
        old_text, new_text = extract_text_replace(user_text)
        return {"tool": "text-replace", "params": {"source_words": old_text, "target_words": new_text},
                "explanation": f'改字: "{old_text}"→"{new_text}"' if old_text and new_text else "改字"}
    
    if any(kw in text for kw in ["去噪", "降噪", "噪点", "颗粒", "denoise"]):
        return {"tool": "denoise", "params": {}, "explanation": "免费去噪"}
    
    if any(kw in text for kw in ["暗部", "提亮", "暗光", "夜景", "曝光不足", "暗", "增强", "enhance"]):
        return {"tool": "enhance", "params": {}, "explanation": "免费暗部增强"}
    
    if any(kw in text for kw in ["超清", "高清", "清晰", "放大", "锐化", "super"]):
        return {"tool": "superres", "params": {}, "explanation": "免费超清"}
    
    if any(kw in text for kw in ["黑白", "灰度", "grayscale"]):
        return {"tool": "grayscale", "params": {}, "explanation": "免费黑白效果"}
    
    if any(kw in text for kw in ["复古", "棕", "旧照片", "sepia"]):
        return {"tool": "sepia", "params": {}, "explanation": "免费复古滤镜"}
    
    if any(kw in text for kw in ["旋转", "rotate"]):
        return {"tool": "rotate", "params": {}, "explanation": "免费旋转"}
    
    if any(kw in text for kw in ["模糊", "毛玻璃", "高斯", "blur"]):
        return {"tool": "blur", "params": {}, "explanation": "免费模糊"}
    
    # Default: try to detect text replacement pattern
    old_text, new_text = extract_text_replace(user_text)
    if old_text and new_text:
        return {"tool": "text-replace", "params": {"source_words": old_text, "target_words": new_text},
                "explanation": f'改字: "{old_text}"→"{new_text}"'}
    
    return {"tool": "enhance", "params": {}, "explanation": "免费图片增强"}


# ===================== Shared helpers =====================

def extract_text_replace(text: str) -> tuple:
    """Extract old text and new text for replacement"""
    patterns = [
        r"(?:把|将)?(.+?)(?:改成|改为|替换为)(.+?)(?:$|的|，|。)",
        r"(?:改成|改为|替换为)(.+?)(?:$|的|，|。)",
    ]
    for pat in patterns:
        m = re.search(pat, text)
        if m:
            groups = m.groups()
            if len(groups) == 2:
                return groups[0].strip(), groups[1].strip()
            elif len(groups) == 1:
                return "", groups[0].strip()
    if "改成" in text or "改为" in text:
        sep = "改成" if "改成" in text else "改为"
        parts = text.split(sep)
        if len(parts) == 2:
            return parts[0].strip(), parts[1].strip()
    return "", ""


# ===================== Meitu Tool Registry =====================
TOOL_REGISTRY_PATH = os.path.expanduser("~/.meitu/tool-registry.json")
TOOL_REGISTRY = {}
if os.path.exists(TOOL_REGISTRY_PATH):
    with open(TOOL_REGISTRY_PATH) as f:
        TOOL_REGISTRY = json.load(f).get("tools", {})


def classify_meitu_request(user_text: str) -> dict:
    """Classify user's natural language request into a Meitu API command (existing logic)"""
    text = user_text.lower()
    
    if any(kw in text for kw in ["抠图", "去背景", "透明", "扣图", "remove background", "cutout"]):
        return {"tool": "image-cutout", "params": {"prompt": "subject"}, "explanation": "正在为您抠图"}
    
    if any(kw in text for kw in ["换背景", "更换背景", "替换背景", "改背景", "背景换成", "背景改为"]):
        target_bg = ""  # simplified
        return {"tool": "image-background-replace", "params": {"prompt": target_bg or "white background"},
                "explanation": "正在为您更换背景"}
    
    if any(kw in text for kw in ["去水印", "去除水印", "去掉水印", "消除", "去除", "去掉文字"]):
        return {"tool": "image-element-remove", "params": {}, "explanation": "正在去除水印/杂物"}
    
    if any(kw in text for kw in ["改字", "改文字", "替换文字", "文字改成", "文字改为"]):
        old_text, new_text = extract_text_replace(user_text)
        params = {"source_words": old_text, "target_words": new_text} if old_text and new_text else {}
        return {"tool": "image-text-replace", "params": params,
                "explanation": f'将文字「{old_text}」改为「{new_text}」' if old_text and new_text else "正在替换文字"}
    
    return {"tool": "image-edit", "params": {"prompt": user_text, "model": "auto"},
            "explanation": f"正在处理：{user_text}"}


def get_credit_remaining() -> dict:
    try:
        result = subprocess.run([MEITU_CLI, "account", "overview", "--json"],
                                capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            data = json.loads(result.stdout)
            left = data.get("data", {}).get("credits_balance", 0)
            return {"success": True, "data": {"left": left}}
        return {"success": False, "error": result.stderr}
    except Exception as e:
        return {"success": False, "error": str(e)}


# ===================== Routes =====================

@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "mode": "dual", "free_tools": list(FREE_TOOLS.keys())})


@app.route("/api/credit", methods=["GET"])
def credit():
    result = get_credit_remaining()
    return jsonify(result)


@app.route("/api/edit", methods=["POST"])
def edit_image():
    """
    Main endpoint: process image
    Accepts multipart form:
      - image: file
      - text: string (user's request)
      - mode: "free" (default) or "meitu"
      - tool: explicit tool name (optional, if user clicked a button)
    """
    if "image" not in request.files:
        return jsonify({"error": "No image provided"}), 400
    
    file = request.files["image"]
    user_text = request.form.get("text", "")
    mode = request.form.get("mode", "free").lower()
    explicit_tool = request.form.get("tool", "").lower()
    
    if not user_text and not explicit_tool:
        return jsonify({"error": "No instruction provided"}), 400
    
    # Save uploaded image
    ext = os.path.splitext(file.filename or "image.jpg")[1] or ".jpg"
    upload_filename = f"{uuid.uuid4()}{ext}"
    upload_path = UPLOAD_DIR / upload_filename
    file.save(str(upload_path))
    
    # Generate unique output path
    output_filename = f"result_{uuid.uuid4()}{ext}"
    output_path = OUTPUT_DIR / output_filename
    
    try:
        if mode == "free":
            return _process_free(upload_path, output_path, user_text, explicit_tool)
        else:
            return _process_meitu(upload_path, output_path, user_text, explicit_tool)
    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": f"处理失败: {str(e)}"}), 500
    finally:
        # Cleanup uploaded file
        try:
            if upload_path.exists():
                upload_path.unlink()
        except:
            pass


def _process_free(upload_path: Path, output_path: Path, user_text: str, explicit_tool: str):
    """Handle processing with free local tools"""
    # Determine which tool to use
    if explicit_tool and explicit_tool in FREE_TOOLS:
        tool_name = explicit_tool
        tool_info = FREE_TOOLS[tool_name]
        params = {}
        if user_text and tool_info["needs_text"]:
            old_text, new_text = extract_text_replace(user_text)
            params = {"source_words": old_text, "target_words": new_text}
        explanation = f"免费{tool_info['label']}"
    else:
        classification = classify_free_tool(user_text)
        tool_name = classification["tool"]
        params = classification["params"]
        explanation = classification["explanation"]
    
    tool_fn = FREE_TOOLS[tool_name]["fn"]
    
    # Call the processing function
    if tool_name == "text-replace":
        result = tool_fn(str(upload_path),
                         params.get("source_words", ""),
                         params.get("target_words", ""),
                         str(output_path))
    elif tool_name == "cutout":
        result = tool_fn(str(upload_path), str(output_path))
    else:
        result = tool_fn(str(upload_path), str(output_path))
    
    if "error" in result:
        return jsonify({"error": result["error"], "tool_used": f"free/{tool_name}"}), 500
    
    result_image_url = f"/api/result/{output_path.name}" if output_path.exists() else None
    
    return jsonify({
        "success": True,
        "mode": "free",
        "explanation": result.get("explanation", explanation),
        "tool_used": f"free/{tool_name}",
        "result_image_url": result_image_url,
        "credit_consumed": 0,
        "credit_remaining": "∞ (免费)",
    })


def _process_meitu(upload_path: Path, output_path: Path, user_text: str, explicit_tool: str):
    """Handle processing with Meitu API (existing flow)"""
    # Get pre-credit
    pre_credit = get_credit_remaining()
    
    # Classify the request
    if explicit_tool:
        tool_name = explicit_tool
        params = {}
        if user_text:
            old_text, new_text = extract_text_replace(user_text)
            if old_text and new_text:
                params = {"source_words": old_text, "target_words": new_text}
        explanation = f"美图处理"
    else:
        classification = classify_meitu_request(user_text)
        tool_name = classification["tool"]
        params = classification["params"]
        explanation = classification["explanation"]
    
    # Get tool info
    tool_info = TOOL_REGISTRY.get(tool_name, {})
    
    try:
        # Call Meitu CLI
        cmd = [MEITU_CLI, tool_name.replace("_", "-"), "--json"]
        
        if "image" in str(tool_info.get("media_inputs", [])):
            cmd.extend(["--image_url", str(upload_path)])
        else:
            cmd.extend(["--image_url", str(upload_path)])
        
        for key, value in params.items():
            if value:
                cmd.extend([f"--{key}", str(value)])
        
        # Set download dir
        download_dir = OUTPUT_DIR / str(uuid.uuid4())
        download_dir.mkdir(parents=True, exist_ok=True)
        cmd.extend(["--download-dir", str(download_dir)])
        
        print(f"Meitu: {' '.join(cmd)}")
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        
        if result.returncode != 0:
            error_msg = result.stderr or result.stdout or "Unknown error"
            try:
                error_data = json.loads(result.stdout)
                error_msg = json.dumps(error_data, ensure_ascii=False, indent=2)
            except:
                pass
            return jsonify({
                "error": f"美图API处理失败: {error_msg[:500]}",
                "explanation": explanation,
                "tool_used": tool_name,
            }), 500
        
        # Find result image
        output_files = list(download_dir.glob("*.*"))
        result_data = {}
        try:
            result_data = json.loads(result.stdout)
        except:
            result_data = {"raw": result.stdout[:500]}
        
        result_image_url = None
        if output_files:
            result_image_path = str(output_files[0])
            result_image_url = f"/api/result/{output_files[0].name}"
            # Copy to standard output path
            shutil.copy2(output_files[0], output_path)
        
        # Get post-credit
        post_credit = get_credit_remaining()
        credit_consumed = None
        credit_remaining_val = None
        if pre_credit.get("success") and post_credit.get("success"):
            pre_left = pre_credit["data"].get("left", 0)
            post_left = post_credit["data"].get("left", 0)
            if isinstance(pre_left, (int, float)) and isinstance(post_left, (int, float)):
                credit_consumed = max(0, pre_left - post_left)
                credit_remaining_val = post_left
        
        return jsonify({
            "success": True,
            "mode": "meitu",
            "explanation": explanation,
            "tool_used": tool_name,
            "result_image_url": result_image_url,
            "result_data": result_data,
            "credit_consumed": credit_consumed,
            "credit_remaining": credit_remaining_val,
        })
        
    except subprocess.TimeoutExpired:
        return jsonify({"error": "美图API处理超时，请稍后重试"}), 504


@app.route("/api/result/<filename>", methods=["GET"])
def serve_result(filename):
    """Serve processed result images"""
    f = OUTPUT_DIR / filename
    if f.exists():
        return send_file(str(f), mimetype="image/jpeg")
    return jsonify({"error": "File not found"}), 404


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5078))
    print(f"修图App后端服务启动 (端口: {port}), 双模式: 免费+美图")
    app.run(host="0.0.0.0", port=port, debug=True)
