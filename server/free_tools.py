#!/usr/bin/env python3
"""
免费修图工具 - CLI版
被 server/index.js 调用:
  python3 server/free_tools.py <tool_name> <input_image> <output_image> [extra_args...]
输出JSON到stdout

改字功能(text-replace)使用百度OCR API替代Tesseract，提升中文识别率
环境变量: BAIDU_OCR_API_KEY, BAIDU_OCR_SECRET_KEY
"""
import sys, json, os, re, traceback, time, base64, urllib.request, urllib.parse
import numpy as np

# Lazy imports
_rembg = None
_cv2 = None

def _get_rembg():
    global _rembg
    if _rembg is None:
        from rembg import remove as r
        _rembg = r
    return _rembg

def _get_cv2():
    global _cv2
    if _cv2 is None:
        import cv2 as c
        _cv2 = c
    return _cv2


# ===================== 百度OCR Token管理 =====================
_BAIDU_TOKEN_CACHE = "/tmp/baidu_ocr_token.json"

def _get_baidu_token():
    api_key = os.environ.get("BAIDU_OCR_API_KEY", "")
    secret_key = os.environ.get("BAIDU_OCR_SECRET_KEY", "")
    if not api_key or not secret_key:
        raise RuntimeError("缺少百度OCR环境变量: BAIDU_OCR_API_KEY / BAIDU_OCR_SECRET_KEY")

    # 检查缓存
    if os.path.exists(_BAIDU_TOKEN_CACHE):
        try:
            with open(_BAIDU_TOKEN_CACHE, "r") as f:
                cached = json.load(f)
            if cached.get("api_key") == api_key and cached.get("secret_key") == secret_key and time.time() < cached.get("expires_at", 0):
                return cached["access_token"]
        except:
            pass

    # 请求新token
    url = f"https://aip.baidubce.com/oauth/2.0/token?grant_type=client_credentials&client_id={urllib.parse.quote(api_key)}&client_secret={urllib.parse.quote(secret_key)}"
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())

    if "access_token" not in data:
        raise RuntimeError(f"百度OCR获取token失败: {data.get('error_description', str(data))}")

    token = data["access_token"]
    expires_in = data.get("expires_in", 2592000)
    # 提前1小时过期，安全
    expires_at = time.time() + expires_in - 3600

    os.makedirs(os.path.dirname(_BAIDU_TOKEN_CACHE), exist_ok=True)
    with open(_BAIDU_TOKEN_CACHE, "w") as f:
        json.dump({"api_key": api_key, "secret_key": secret_key, "access_token": token, "expires_at": expires_at}, f)
    return token


def _baidu_ocr(inp_image_path):
    """调用百度OCR通用文字识别(带位置)，返回 [{words, left, top, width, height}, ...]"""
    with open(inp_image_path, "rb") as f:
        img_b64 = base64.b64encode(f.read()).decode()

    token = _get_baidu_token()
    url = f"https://aip.baidubce.com/rest/2.0/ocr/v1/general?access_token={urllib.parse.quote(token)}"

    data = urllib.parse.urlencode({"image": img_b64}).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        result = json.loads(resp.read().decode())

    if "error_code" in result:
        raise RuntimeError(f"百度OCR识别失败: {result.get('error_msg', str(result))}")

    words_result = result.get("words_result", [])
    boxes = []
    for item in words_result:
        text = item.get("words", "").strip()
        loc = item.get("location", {})
        if text and loc.get("width", 0) > 5 and loc.get("height", 0) > 5:
            boxes.append({
                "words": text,
                "left": loc["left"],
                "top": loc["top"],
                "width": loc["width"],
                "height": loc["height"]
            })
    return boxes


# ===================== 工具函数 =====================

def cutout(inp, out):
    from PIL import Image
    import io
    rembg = _get_rembg()
    with open(inp, 'rb') as f:
        result_bytes = rembg.remove(f.read())
    img = Image.open(io.BytesIO(result_bytes)).convert('RGB')
    img.save(out, 'JPEG', quality=95)
    return {"success": True, "explanation": "✅ 抠图完成，已去除背景"}


def text_replace(inp, out, source_words, target_words):
    cv2 = _get_cv2()
    from PIL import Image, ImageDraw, ImageFont

    img = cv2.imread(inp)
    if img is None:
        return {"error": "无法读取图片"}
    h, w = img.shape[:2]

    try:
        ocr_boxes = _baidu_ocr(inp)
    except Exception as e:
        return {"error": f"百度OCR识别失败: {str(e)}，请检查网络或API密钥配置"}

    # 匹配源文字
    found_boxes = []
    source_lower = source_words.lower() if source_words else ""
    for b in ocr_boxes:
        text = b["words"]
        if source_lower:
            if source_lower in text.lower() or text.lower() in source_lower:
                found_boxes.append((b["left"], b["top"], b["width"], b["height"]))

    # 逐字匹配（如果没有精确匹配到整词）
    if not found_boxes and source_words:
        for b in ocr_boxes:
            text = b["words"]
            for sw_char in source_words:
                if sw_char in text:
                    found_boxes.append((b["left"], b["top"], b["width"], b["height"]))
                    break

    # 合并重叠框
    if found_boxes:
        found_boxes.sort(key=lambda b: (b[1], b[0]))
        merged = [found_boxes[0]]
        for box in found_boxes[1:]:
            last = merged[-1]
            if abs(box[1] - last[1]) < 20 and box[0] - (last[0] + last[2]) < 30:
                nx = min(last[0], box[0])
                ny = min(last[1], box[1])
                nw = max(last[0] + last[2], box[0] + box[2]) - nx
                nh = max(last[1] + last[3], box[1] + box[3]) - ny
                merged[-1] = (nx, ny, nw, nh)
            else:
                merged.append(box)
        found_boxes = merged

    # Inpaint（擦除旧文字）
    # 关键：修复半径不能太小，否则大块文字区域中心会模糊
    # 用 NS 方法对大区域效果更好，半径设为文字框尺寸的 30%（最大15）
    mask = np.zeros((h, w), dtype=np.uint8)
    if found_boxes:
        for x, y, bw, bh in found_boxes:
            pad = max(4, int(min(bw, bh) * 0.15))
            x1 = max(0, x - pad)
            y1 = max(0, y - pad)
            x2 = min(w, x + bw + pad)
            y2 = min(h, y + bh + pad)
            cv2.rectangle(mask, (x1, y1), (x2, y2), 255, -1)
        # 取最大文字框尺寸的20%作为半径，至少5，最大15
        max_box_size = max(bh for _, _, _, bh in found_boxes)
        inradius = min(max(5, int(max_box_size * 0.2)), 15)
        inpainted = cv2.inpaint(img, mask, inradius, cv2.INPAINT_NS)
    else:
        inpainted = img.copy()

    # 写入新文字
    result_rgb = cv2.cvtColor(inpainted, cv2.COLOR_BGR2RGB)
    result_pil = Image.fromarray(result_rgb)
    draw = ImageDraw.Draw(result_pil)

    if target_words and found_boxes:
        # 预加载字体（缓存复用，避免每个box都重新加载）
        _font_cache = {}
        def _get_font(size):
            if size in _font_cache:
                return _font_cache[size]
            for fp in [
                os.path.join(os.path.dirname(__file__), '..', 'fonts', 'Harmony-Regular.ttf'),
                os.path.join(os.path.dirname(__file__), '..', 'fonts', 'Harmony-Bold.ttf'),
                '/usr/share/fonts/HarmonyFont/Harmony-Regular.ttf',
                '/usr/share/fonts/SubSetSourceHanSans/SourceHanSansCN-list-label.ttf',
                '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
            ]:
                try:
                    f = ImageFont.truetype(fp, size)
                    _font_cache[size] = f
                    return f
                except:
                    continue
            _font_cache[size] = ImageFont.load_default()
            return _font_cache[size]

        for x, y, bw, bh in found_boxes:
            # 采样区域：从原图（inpaint前）取文字周边区域的平均颜色和纹理特征
            sample_pad = max(10, bh // 2)
            # ── ① 自适应字体大小 ──
            # 先用高度估算初始字号，再检查宽度是否符合，逐步缩小
            font_size = max(12, bh - 4)
            font = _get_font(font_size)
            bbox = draw.textbbox((0, 0), target_words, font=font)
            tw = bbox[2] - bbox[0]
            th = bbox[3] - bbox[1]
            while tw > bw * 0.88 and font_size > 10:
                font_size -= 2
                font = _get_font(font_size)
                bbox = draw.textbbox((0, 0), target_words, font=font)
                tw = bbox[2] - bbox[0]
                th = bbox[3] - bbox[1]

            # ── ② 更精准的文字颜色判断 ──
            # 从原图（inpainted之前）取文字区域周边的平均颜色和纹理
            x1_s = max(0, x - sample_pad)
            y1_s = max(0, y - sample_pad)
            x2_s = min(w, x + bw + sample_pad)
            y2_s = min(h, y + bh + sample_pad)
            sample_area = img[y1_s:y2_s, x1_s:x2_s]

            if sample_area.size > 0:
                pixels = sample_area.reshape(-1, 3)
                avg_bgr = np.mean(pixels, axis=0)
                std_bgr = np.std(pixels, axis=0)
                luminance = 0.299 * avg_bgr[2] + 0.587 * avg_bgr[1] + 0.114 * avg_bgr[0]
                bg_variation = np.mean(std_bgr)  # 纹理复杂度

                if luminance > 160:
                    # 很亮的背景 → 黑字 + 浅灰阴影
                    text_color = (0, 0, 0)
                    shadow_color = (180, 180, 180)
                elif luminance < 80:
                    # 很暗的背景 → 白字 + 深灰阴影
                    text_color = (255, 255, 255)
                    shadow_color = (10, 10, 10)
                else:
                    # 中间亮度 → 取反差最大的颜色
                    if luminance > 128:
                        text_color = (0, 0, 0)
                        shadow_color = (180, 180, 180)
                    else:
                        text_color = (255, 255, 255)
                        shadow_color = (30, 30, 30)
                # 纹理复杂 → 增强对比度确保可读性
                if bg_variation > 35:
                    if luminance > 128:
                        text_color = (0, 0, 0)
                        shadow_color = (160, 160, 160)
                    else:
                        text_color = (255, 255, 255)
                        shadow_color = (0, 0, 0)
            else:
                text_color = (0, 0, 0)
                shadow_color = (180, 180, 180)

            # ── ③ 阴影效果 + 正文绘制 ──
            tx = x + (bw - tw) // 2
            ty = y + (bh - th) // 2
            sh_off = max(2, int(font_size * 0.07))  # 阴影偏移量

            # 先画阴影（右下偏移）
            draw.text((tx + sh_off, ty + sh_off), target_words, fill=shadow_color, font=font)
            # 再画正文（覆盖在阴影之上）
            draw.text((tx, ty), target_words, fill=text_color, font=font)

    result_pil.save(out, 'JPEG', quality=95)
    return {"success": True, "explanation": f'✅ 改字完成："{source_words}"→"{target_words}" (百度OCR)'}


def denoise(inp, out):
    cv2 = _get_cv2()
    img = cv2.imread(inp)
    if img is None:
        return {"error": "无法读取图片"}
    result = cv2.fastNlMeansDenoisingColored(img, None, 10, 10, 7, 21)
    cv2.imwrite(out, result)
    return {"success": True, "explanation": "✅ 去噪完成"}


def enhance(inp, out):
    cv2 = _get_cv2()
    img = cv2.imread(inp)
    if img is None:
        return {"error": "无法读取图片"}
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    l = clahe.apply(l)
    lab = cv2.merge([l, a, b])
    result = cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)
    hsv = cv2.cvtColor(result, cv2.COLOR_BGR2HSV)
    hsv[:, :, 1] = np.clip(hsv[:, :, 1] * 1.15, 0, 255).astype(np.uint8)
    result = cv2.cvtColor(hsv, cv2.COLOR_HSV2BGR)
    cv2.imwrite(out, result)
    return {"success": True, "explanation": "✅ 暗部增强完成"}


def superres(inp, out):
    cv2 = _get_cv2()
    img = cv2.imread(inp)
    if img is None:
        return {"error": "无法读取图片"}
    h, w = img.shape[:2]
    if h < 1000 or w < 1000:
        scale = min(2.0, 1500 / min(h, w))
        new_w, new_h = int(w * scale), int(h * scale)
        img = cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_CUBIC)
    kernel = np.array([[-1, -1, -1], [-1, 9, -1], [-1, -1, -1]]) / 1.0
    result = cv2.filter2D(img, -1, kernel)
    cv2.imwrite(out, result)
    return {"success": True, "explanation": "✅ 超清完成"}


def grayscale(inp, out):
    cv2 = _get_cv2()
    img = cv2.imread(inp)
    if img is None:
        return {"error": "无法读取图片"}
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    cv2.imwrite(out, gray)
    return {"success": True, "explanation": "✅ 黑白效果完成"}


def sepia(inp, out):
    cv2 = _get_cv2()
    img = cv2.imread(inp)
    if img is None:
        return {"error": "无法读取图片"}
    matrix = np.array([[0.272, 0.534, 0.131],
                       [0.349, 0.686, 0.168],
                       [0.393, 0.769, 0.189]])
    result = cv2.transform(img, matrix)
    result = np.clip(result, 0, 255).astype(np.uint8)
    cv2.imwrite(out, result)
    return {"success": True, "explanation": "✅ 复古滤镜完成"}


def rotate(inp, out):
    cv2 = _get_cv2()
    img = cv2.imread(inp)
    if img is None:
        return {"error": "无法读取图片"}
    result = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    cv2.imwrite(out, result)
    return {"success": True, "explanation": "✅ 旋转完成"}


def blur(inp, out):
    cv2 = _get_cv2()
    img = cv2.imread(inp)
    if img is None:
        return {"error": "无法读取图片"}
    result = cv2.GaussianBlur(img, (15, 15), 0)
    cv2.imwrite(out, result)
    return {"success": True, "explanation": "✅ 模糊完成"}


TOOLS = {
    "cutout": cutout, "text-replace": text_replace, "denoise": denoise,
    "enhance": enhance, "superres": superres, "grayscale": grayscale,
    "sepia": sepia, "rotate": rotate, "blur": blur,
}

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(json.dumps({"error": f"Usage: {sys.argv[0]} <tool> <input> <output> [args...]"}))
        sys.exit(1)
    tool_name = sys.argv[1]
    input_path = sys.argv[2]
    output_path = sys.argv[3]
    extra = sys.argv[4:]

    if tool_name not in TOOLS:
        print(json.dumps({"error": f"Unknown tool: {tool_name}, available: {list(TOOLS.keys())}"}))
        sys.exit(1)

    if not os.path.exists(input_path):
        print(json.dumps({"error": f"Input file not found: {input_path}"}))
        sys.exit(1)

    try:
        if tool_name == "text-replace":
            source = extra[0] if len(extra) > 0 else ""
            target = extra[1] if len(extra) > 1 else ""
            result = TOOLS[tool_name](input_path, output_path, source, target)
        else:
            result = TOOLS[tool_name](input_path, output_path)
        print(json.dumps(result, ensure_ascii=False))
    except Exception as e:
        traceback.print_exc()
        print(json.dumps({"error": str(e)}, ensure_ascii=False))
        sys.exit(1)
