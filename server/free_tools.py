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

    # ── 1. 匹配源文字 ──
    # 记录每个匹配框的原文长度，用于精确擦除
    source_lower = source_words.lower() if source_words else ""

    # 存储：(box_x, box_y, box_w, box_h, ocr_text, is_exact_match)
    match_info = []
    for b in ocr_boxes:
        text = b["words"]
        if source_lower:
            if source_lower in text.lower() or text.lower() in source_lower:
                match_info.append((b["left"], b["top"], b["width"], b["height"], text, True))

    # 逐字匹配兜底
    if not match_info and source_words:
        for b in ocr_boxes:
            text = b["words"]
            for sw_char in source_words:
                if sw_char in text:
                    match_info.append((b["left"], b["top"], b["width"], b["height"], text, False))
                    break

    # ── 2. 智能分块：如果OCR框包含多余字符，只擦除目标部分 ──
    # 比如 OCR 检测到 "贺泽鲜肉"，但只改 "贺泽" → 保留 "鲜肉"
    erase_boxes = []  # 实际要擦除的 (x, y, w, h)
    write_boxes = []  # 实际要写字的 (x, y, w, h, 背景采样区域)

    for x, y, bw, bh, ocr_text, is_exact in match_info:
        ocr_len = len(ocr_text)
        src_len = len(source_words)

        if is_exact and ocr_len > src_len and src_len > 0:
            # source_words 是 ocr_text 的子串 → 只在对应位置擦除和写入
            # 按字符宽度比例分割
            char_ratio = src_len / max(ocr_len, 1)
            # 找到 source 在 text 中的位置
            src_idx = ocr_text.lower().find(source_lower)
            if src_idx < 0:
                src_idx = 0
            # 起始偏移 = 总宽 * (source起始位置 / 总字符数)
            offset_ratio = src_idx / max(ocr_len, 1)
            seg_w = bw * char_ratio
            seg_x = x + int(bw * offset_ratio)
            # 微调：左右各加一点padding
            seg_pad_x = int(seg_w * 0.05)
            # 擦除区域（只擦除目标文字部分）
            ex1 = max(0, seg_x - seg_pad_x)
            ey1 = max(0, y - 2)
            ex2 = min(w, seg_x + int(seg_w) + seg_pad_x)
            ey2 = min(h, y + bh + 2)
            erase_boxes.append((ex1, ey1, ex2 - ex1, ey2 - ey1))
            # 写入区域（与擦除区域一致，但用于居中写新字）
            write_boxes.append((seg_x, y, int(seg_w), bh, x, y, bw, bh))
        else:
            # 完全匹配或模糊匹配 → 整块擦除
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

    # ── 3. 采集纯背景颜色（从文字框周边角落，不含文字本身）──
    bg_samples = []  # [(B, G, R), ...] 纯背景采样
    if erase_boxes:
        for x, y, bw, bh in erase_boxes:
            # 从文字框四个角落外沿采样（避开文字区域）
            corners = [
                (x - 10, y - 10, 10, 10),
                (x + bw - 10, y - 10, 10, 10),
                (x - 10, y + bh - 10, 10, 10),
                (x + bw - 10, y + bh - 10, 10, 10),
            ]
            for cx, cy, cw, ch in corners:
                if cx >= 0 and cy >= 0 and cx + cw <= w and cy + ch <= h:
                    area = img[cy:cy + ch, cx:cx + cw]
                    if area.size > 0:
                        avg = np.mean(area.reshape(-1, 3), axis=0)
                        bg_samples.append(avg)
        # 如果角落采样不够，扩大范围
        if len(bg_samples) < 2:
            for x, y, bw, bh in erase_boxes:
                pad = max(bh, 20)
                x1_s = max(0, x - pad)
                y1_s = max(0, y - pad)
                x2_s = min(w, x + bw + pad)
                y2_s = min(h, y + bh + pad)
                area = img[y1_s:y2_s, x1_s:x2_s]
                if area.size > 0:
                    avg = np.mean(area.reshape(-1, 3), axis=0)
                    bg_samples.append(avg)

    # ── 4. 擦除旧文字（改进版：双遍 inpaint + 自适应半径）──
    mask = np.zeros((h, w), dtype=np.uint8)
    if erase_boxes:
        for x, y, bw, bh in erase_boxes:
            pad = max(8, int(min(bw, bh) * 0.25))
            x1 = max(0, x - pad)
            y1 = max(0, y - pad)
            x2 = min(w, x + bw + pad)
            y2 = min(h, y + bh + pad)
            cv2.rectangle(mask, (x1, y1), (x2, y2), 255, -1)
        max_box_size = max(bh for _, _, _, _ in erase_boxes)
        # 大区域用大半径多遍修复
        base_radius = min(max(3, int(max_box_size * 0.15)), 20)
        inpainted = img.copy()
        for _ in range(2):  # 双遍修复，减少模糊
            inpainted = cv2.inpaint(inpainted, mask, base_radius, cv2.INPAINT_NS)
    else:
        inpainted = img.copy()

    # ── 5. 写入新文字（改进版：描边 + 纹理匹配 + 噪点融合）──
    result_rgb = cv2.cvtColor(inpainted, cv2.COLOR_BGR2RGB)
    result_pil = Image.fromarray(result_rgb)
    draw = ImageDraw.Draw(result_pil)

    if target_words and write_boxes:
        # 预加载字体缓存
        _font_cache = {}

        def _get_font(size):
            if size in _font_cache:
                return _font_cache[size]
            for fp in [
                '/usr/share/fonts/HarmonyFont/Harmony-Bold.ttf',
                os.path.join(os.path.dirname(__file__), '..', 'fonts', 'Harmony-Bold.ttf'),
                '/usr/share/fonts/HarmonyFont/Harmony-SemiBold.ttf',
                '/usr/share/fonts/HarmonyFont/Harmony-Medium.ttf',
                '/usr/share/fonts/HarmonyFont/Harmony-Regular.ttf',
                os.path.join(os.path.dirname(__file__), '..', 'fonts', 'Harmony-Regular.ttf'),
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

        # 分析全局背景色
        global_bg = np.array([128, 128, 128])
        if bg_samples:
            global_bg = np.mean(bg_samples, axis=0)
        bg_lum = 0.299 * global_bg[2] + 0.587 * global_bg[1] + 0.114 * global_bg[0]
        # 红底判断
        is_red_bg = global_bg[2] > global_bg[1] * 1.4 and global_bg[2] > global_bg[0] * 1.4
        # 采样周边纹理/噪点强度（用于后续融合）
        texture_areas = []
        if bg_samples:
            for bx, by, bw, bh in erase_boxes:
                pad = max(10, bh)
                x1_s = max(0, bx - pad)
                y1_s = max(0, by - pad)
                x2_s = min(w, bx + bw + pad)
                y2_s = min(h, by + bh + pad)
                area = img[y1_s:y2_s, x1_s:x2_s]
                if area.size > 0:
                    gray = cv2.cvtColor(area, cv2.COLOR_BGR2GRAY)
                    texture_areas.append(gray)
        # 全局噪声水平
        global_noise_std = 8.0
        if texture_areas:
            noise_stds = [np.std(a) for a in texture_areas if a.size > 0]
            if noise_stds:
                global_noise_std = np.mean(noise_stds)

        # 新建一个透明图层用于文字渲染（先渲染，再融合到背景）
        text_layer = Image.new('RGBA', (w, h), (0, 0, 0, 0))
        text_draw = ImageDraw.Draw(text_layer)

        for box in write_boxes:
            write_x, write_y, write_w, write_h = box[0], box[1], box[2], box[3]

            # ── 5a. 确定文字颜色（带透明度通道）──
            if is_red_bg:
                text_color = (255, 255, 255, 235)
                stroke_color = (80, 20, 20, 120)  # 暗红描边
                shadow_color = (20, 10, 10, 100)
            elif bg_lum > 150:
                text_color = (0, 0, 0, 235)
                stroke_color = (180, 180, 180, 80)
                shadow_color = (200, 200, 200, 80)
            elif bg_lum < 70:
                text_color = (255, 255, 255, 235)
                stroke_color = (30, 30, 30, 100)
                shadow_color = (10, 10, 10, 100)
            else:
                if bg_lum < 128:
                    text_color = (255, 255, 255, 235)
                    stroke_color = (50, 50, 50, 80)
                    shadow_color = (10, 10, 10, 100)
                else:
                    text_color = (0, 0, 0, 235)
                    stroke_color = (180, 180, 180, 80)
                    shadow_color = (200, 200, 200, 80)

            # ── 5b. 自适应字体大小（宽度+高度双维度）──
            font_size = max(14, write_h - 2)
            font = _get_font(font_size)
            bbox = text_draw.textbbox((0, 0), target_words, font=font)
            tw = bbox[2] - bbox[0]
            th = bbox[3] - bbox[1]

            w_ratio = write_w * 0.88 / max(tw, 1)
            h_ratio = write_h * 0.82 / max(th, 1)
            ratio = min(w_ratio, h_ratio, 1.0)
            if ratio < 0.95:
                font_size = max(10, int(font_size * ratio))
                font = _get_font(font_size)
                bbox = text_draw.textbbox((0, 0), target_words, font=font)
                tw = bbox[2] - bbox[0]
                th = bbox[3] - bbox[1]

            # ── 5c. 居中 ──
            tx = write_x + (write_w - tw) // 2
            ty = write_y + (write_h - th) // 2
            sh_off = max(2, min(4, int(font_size * 0.07)))
            stroke_w = max(1, int(font_size * 0.06))

            # ── 5d. 三层绘制：描边 → 阴影 → 正文 ──
            # 描边（模拟立体字的边缘）
            for sx in range(-stroke_w, stroke_w + 1):
                for sy in range(-stroke_w, stroke_w + 1):
                    if sx != 0 or sy != 0:
                        stroke_alpha = 60 if abs(sx) + abs(sy) < stroke_w * 1.5 else 30
                        sc = (stroke_color[0], stroke_color[1], stroke_color[2], stroke_alpha)
                        text_draw.text((tx + sx, ty + sy), target_words, fill=sc, font=font)
            # 阴影
            text_draw.text((tx + sh_off, ty + sh_off), target_words, fill=shadow_color, font=font)
            # 正文
            text_draw.text((tx, ty), target_words, fill=text_color, font=font)

        # ── 5e. 纹理融合 ──
        # 将文字图层与背景融合，并添加噪点匹配原图纹理
        text_np = np.array(text_layer)
        text_rgb = text_np[:, :, :3]
        text_alpha = text_np[:, :, 3:4] / 255.0

        # 合成到原图
        result_np = np.array(result_pil).astype(np.float32)
        blended = result_np * (1 - text_alpha) + text_rgb.astype(np.float32) * text_alpha
        blended = np.clip(blended, 0, 255).astype(np.uint8)

        # ── 5f. 噪点匹配（只在文字区域添加与原图纹理匹配的噪点）──
        noise_mask = (text_alpha[:, :, 0] > 10).astype(np.uint8) * 255
        if np.any(noise_mask > 0):
            noise = np.random.normal(0, global_noise_std * 0.3, blended.shape).astype(np.int16)
            # 只对文字区域加噪，外围衰减
            kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
            noise_mask_dilated = cv2.dilate(noise_mask, kernel, iterations=2)
            noise_faded = noise * (noise_mask_dilated / 255.0)[:, :, np.newaxis]
            blended = np.clip(blended.astype(np.int16) + noise_faded, 0, 255).astype(np.uint8)

        result_final = Image.fromarray(blended)
        result_final.save(out, 'JPEG', quality=95)
    else:
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
