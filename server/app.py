#!/usr/bin/env python3
"""
修图App 后端服务
- 接收图片 + 用户自然语言需求
- 理解需求并翻译成美图API参数
- 调用美图CLI处理
- 返回结果
"""
import os
import json
import subprocess
import tempfile
import shutil
import uuid
from pathlib import Path
from flask import Flask, request, jsonify, send_file
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

# Config
MEITU_CLI = os.path.expanduser("~/.npm-global/bin/meitu")
UPLOAD_DIR = Path(tempfile.gettempdir()) / "xiutu_uploads"
OUTPUT_DIR = Path(tempfile.gettempdir()) / "xiutu_outputs"
UPLOAD_DIR.mkdir(exist_ok=True)
OUTPUT_DIR.mkdir(exist_ok=True)

# Meitu tool registry - load to understand available tools
TOOL_REGISTRY_PATH = os.path.expanduser("~/.meitu/tool-registry.json")
TOOL_REGISTRY = {}
if os.path.exists(TOOL_REGISTRY_PATH):
    with open(TOOL_REGISTRY_PATH) as f:
        TOOL_REGISTRY = json.load(f).get("tools", {})


def classify_request(user_text: str) -> dict:
    """
    Classify user's natural language request into a Meitu API command.
    Returns dict with:
      - tool: Meitu command name
      - params: dict of parameters to pass
      - explanation: what we understood
    """
    text = user_text.lower()

    # === Detect request types ===

    # 1. Cutout / Remove background / Transparent
    if any(kw in text for kw in ["抠图", "去背景", "透明", "扣图", "remove background", "cutout"]):
        return {
            "tool": "image-cutout",
            "params": {"prompt": extract_subject(user_text)},
            "explanation": f"正在为您抠图，去除背景保留主体"
        }

    # 2. Background replacement
    if any(kw in text for kw in ["换背景", "更换背景", "替换背景", "改背景", "背景换成", "背景改为"]):
        target_bg = extract_target_bg(user_text)
        return {
            "tool": "image-background-replace",
            "params": {"prompt": target_bg or "white background"},
            "explanation": f"正在为您更换背景为：{target_bg or '白色背景'}"
        }

    # 3. Element/watermark removal
    if any(kw in text for kw in ["去水印", "去除水印", "去掉水印", "消除", "去除", "去掉文字"]):
        target = extract_target_element(user_text)
        return {
            "tool": "image-element-remove",
            "params": {"prompt": target} if target else {},
            "explanation": f"正在为您去除图片中的{target or '水印/杂物'}"
        }

    # 4. Text replacement
    if any(kw in text for kw in ["改字", "改文字", "替换文字", "文字改成", "文字改为", "替换文本"]):
        old_text, new_text = extract_text_replace(user_text)
        params = {"source_words": old_text, "target_words": new_text} if old_text and new_text else {}
        return {
            "tool": "image-text-replace",
            "params": params,
            "explanation": f"正在为您将文字「{old_text}」改为「{new_text}」" if old_text and new_text else "正在为您替换文字"
        }

    # 5. General image edit (default catch-all)
    return {
        "tool": "image-edit",
        "params": {"prompt": user_text, "model": "auto"},
        "explanation": f"正在处理您的需求：{user_text}"
    }


def extract_subject(text: str) -> str:
    """Extract the subject for cutout"""
    subjects = ["人物", "人", "person", "product", "产品", "商品", "宠物", "pet", "动物", "建筑", "building", "车辆", "car", "植物", "plant", "植物", "flower"]
    for s in subjects:
        if s in text.lower():
            return s
    return "subject"


def extract_target_bg(text: str) -> str:
    """Extract target background description"""
    import re
    patterns = [
        r"背景(换成|改为|改成|替换为|变成)(.+?)(?:的|$|，|。)",
        r"(换成|改为|改成)(.+?)背景",
        r"背景是(.+?)(?:的|$|，|。)",
    ]
    for pat in patterns:
        m = re.search(pat, text)
        if m:
            return m.group(2).strip() or None
    return None


def extract_target_element(text: str) -> str:
    """Extract what to remove"""
    import re
    patterns = [
        r"去除(.+?)(?:水印|文字|杂物|元素|东西)",
        r"去掉(.+?)(?:水印|文字|杂物|元素|东西)",
        r"消除(.+?)(?:水印|文字|杂物|元素|东西)",
        r"(去掉|去除|消除)(?:水印|文字|杂物|元素|东西)(.+?)(?:$|。|，)",
    ]
    for pat in patterns:
        m = re.search(pat, text)
        if m:
            result = m.group(2).strip() if m.lastindex == 2 else m.group(1).strip()
            if result:
                return result
    return ""


def extract_text_replace(text: str) -> tuple:
    """Extract old text and new text for replacement"""
    import re
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
    # Try to detect from phrases
    if "改成" in text or "改为" in text or "换成" in text:
        parts = text.split("改成" if "改成" in text else "改为" if "改为" in text else "换成")
        if len(parts) == 2:
            return parts[0].strip(), parts[1].strip()
    return "", ""


def get_credit_remaining() -> dict:
    """Get remaining credits from Meitu"""
    try:
        result = subprocess.run(
            [MEITU_CLI, "auth", "volume", "--json"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            return {
                "success": True,
                "data": data
            }
        return {"success": False, "error": result.stderr}
    except Exception as e:
        return {"success": False, "error": str(e)}


@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


@app.route("/api/credit", methods=["GET"])
def credit():
    """Get remaining credits"""
    result = get_credit_remaining()
    return jsonify(result)


@app.route("/api/edit", methods=["POST"])
def edit_image():
    """
    Main endpoint: receive image + request, process via Meitu API
    
    Expects multipart form:
      - image: file
      - text: string (user's request)
    """
    if "image" not in request.files:
        return jsonify({"error": "No image provided"}), 400
    
    file = request.files["image"]
    user_text = request.form.get("text", "")
    
    if not user_text:
        return jsonify({"error": "No text instruction provided"}), 400
    
    # Save uploaded image
    ext = os.path.splitext(file.filename or "image.jpg")[1] or ".jpg"
    upload_filename = f"{uuid.uuid4()}{ext}"
    upload_path = UPLOAD_DIR / upload_filename
    file.save(str(upload_path))
    
    # Get pre-credit
    pre_credit = get_credit_remaining()
    
    # Classify the request
    classification = classify_request(user_text)
    tool_name = classification["tool"]
    params = classification["params"]
    explanation = classification["explanation"]
    
    # Get tool info
    tool_info = TOOL_REGISTRY.get(tool_name, {})
    api_name = tool_info.get("api_name", tool_name)
    
    try:
        # Call Meitu CLI
        cmd = [MEITU_CLI, tool_name.replace("_", "-"), "--json"]
        
        # Add image input
        media_inputs = tool_info.get("media_inputs", [])
        if media_inputs:
            att_name = media_inputs[0].get("att_name", "image_url")
            if att_name == "image_list":
                cmd.extend(["--image_list", str(upload_path)])
            else:
                cmd.extend(["--image_url", str(upload_path)])
        
        # Add text params
        for key, value in params.items():
            if value:
                cmd.extend([f"--{key}", str(value)])
        
        # Set download dir
        download_dir = OUTPUT_DIR / str(uuid.uuid4())
        download_dir.mkdir(parents=True, exist_ok=True)
        cmd.extend(["--download-dir", str(download_dir)])
        
        print(f"Running: {' '.join(cmd)}")
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        
        if result.returncode != 0:
            error_msg = result.stderr or result.stdout or "Unknown error"
            # Try to parse JSON error
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
        
        # Parse output to find result image
        output_files = list(download_dir.glob("*.*"))
        result_data = {}
        try:
            result_data = json.loads(result.stdout)
        except:
            result_data = {"raw": result.stdout[:500]}
        
        # Find the output image
        result_image_url = None
        if output_files:
            result_image_path = str(output_files[0])
            result_image_url = f"/api/result/{os.path.basename(result_image_path)}"
        
        # Get post-credit
        post_credit = get_credit_remaining()
        
        # Calculate credit consumption
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
            "explanation": explanation,
            "tool_used": tool_name,
            "result_image_url": result_image_url,
            "result_data": result_data,
            "credit_consumed": credit_consumed,
            "credit_remaining": credit_remaining_val,
        })
        
    except subprocess.TimeoutExpired:
        return jsonify({"error": "美图API处理超时，请稍后重试"}), 504
    except Exception as e:
        return jsonify({"error": f"处理失败: {str(e)}"}), 500


@app.route("/api/result/<filename>", methods=["GET"])
def serve_result(filename):
    """Serve processed result images"""
    # Search all download dirs
    for d in OUTPUT_DIR.iterdir():
        if d.is_dir():
            f = d / filename
            if f.exists():
                return send_file(str(f), mimetype="image/jpeg")
    return jsonify({"error": "File not found"}), 404


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5078))
    print(f"修图App后端服务启动，端口: {port}")
    app.run(host="0.0.0.0", port=port, debug=True)
