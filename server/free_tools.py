#!/usr/bin/env python3
"""
免费修图工具 - CLI版
被 server/index.js 调用:
  python3 server/free_tools.py <tool_name> <input_image> <output_image> [extra_args...]
输出JSON到stdout
"""
import sys, json, os, re, traceback
import numpy as np

# Lazy imports
_rembg = None
_cv2 = None
_pytesseract = None

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

def _get_tesseract():
    global _pytesseract
    if _pytesseract is None:
        import pytesseract as t
        _pytesseract = t
    return _pytesseract


def cutout(inp, out):
    from PIL import Image
    import io
    rembg = _get_rembg()
    with open(inp, 'rb') as f:
        result_bytes = rembg.remove(f.read())
    # Convert to RGB (rembg returns RGBA)
    img = Image.open(io.BytesIO(result_bytes)).convert('RGB')
    img.save(out, 'JPEG', quality=95)
    return {"success": True, "explanation": "✅ 抠图完成，已去除背景"}


def text_replace(inp, out, source_words, target_words):
    cv2 = _get_cv2()
    pytesseract = _get_tesseract()
    from PIL import Image, ImageDraw, ImageFont

    img = cv2.imread(inp)
    if img is None:
        return {"error": "无法读取图片"}
    h, w = img.shape[:2]

    # OCR
    rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    pil_img = Image.fromarray(rgb)
    data = pytesseract.image_to_data(pil_img, lang='chi_sim+eng',
                                      output_type=pytesseract.Output.DICT)

    found_boxes = []
    target_lower = source_words.lower() if source_words else ""
    for i, text in enumerate(data['text']):
        text = text.strip()
        if not text:
            continue
        if target_lower:
            if target_lower in text.lower() or text.lower() in target_lower:
                x, y, bw, bh = data['left'][i], data['top'][i], data['width'][i], data['height'][i]
                if bw > 5 and bh > 5:
                    found_boxes.append((x, y, bw, bh))
    
    # If no exact match, try char by char
    if not found_boxes and source_words:
        for i, text in enumerate(data['text']):
            text = text.strip()
            for sw_char in source_words:
                if sw_char in text:
                    x, y, bw, bh = data['left'][i], data['top'][i], data['width'][i], data['height'][i]
                    if bw > 5 and bh > 5:
                        found_boxes.append((x, y, bw, bh))
                    break

    # Merge overlapping boxes
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

    # Inpaint
    mask = np.zeros((h, w), dtype=np.uint8)
    if found_boxes:
        for x, y, bw, bh in found_boxes:
            pad = max(4, int(min(bw, bh) * 0.15))
            x1 = max(0, x - pad)
            y1 = max(0, y - pad)
            x2 = min(w, x + bw + pad)
            y2 = min(h, y + bh + pad)
            cv2.rectangle(mask, (x1, y1), (x2, y2), 255, -1)
        inpainted = cv2.inpaint(img, mask, 3, cv2.INPAINT_TELEA)
    else:
        inpainted = img.copy()

    # Draw new text
    result_rgb = cv2.cvtColor(inpainted, cv2.COLOR_BGR2RGB)
    result_pil = Image.fromarray(result_rgb)
    draw = ImageDraw.Draw(result_pil)

    if target_words and found_boxes:
        for x, y, bw, bh in found_boxes:
            font_size = max(12, bh - 6)
            font = None
            for fp in ['/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc',
                        '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
                        '/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc',
                        '/usr/share/fonts/noto/NotoSansSC-Regular.otf',
                        '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',
                        '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf']:
                try:
                    font = ImageFont.truetype(fp, font_size)
                    break
                except:
                    continue
            if font is None:
                font = ImageFont.load_default()
            bbox = draw.textbbox((0, 0), target_words, font=font)
            tw = bbox[2] - bbox[0]
            th = bbox[3] - bbox[1]
            tx = x + (bw - tw) // 2
            ty = y + (bh - th) // 2
            sample_area = inpainted[max(0,y-5):min(h,y+bh+5), max(0,x-5):min(w,x+bw+5)]
            if sample_area.size > 0:
                avg_color = np.mean(sample_area.reshape(-1, 3), axis=0)
                text_color = tuple(int(255 - c) for c in avg_color)
            else:
                text_color = (0, 0, 0)
            draw.text((tx, ty), target_words, fill=text_color, font=font)

    result_pil.save(out, 'JPEG', quality=95)
    return {"success": True, "explanation": f'✅ 改字完成："{source_words}"→"{target_words}"'}


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
