# =============================================
# Dockerfile - 修图App (Node.js + Python双引擎)
# 免费工具: Python (rembg/OpenCV/Tesseract)
# 美图工具: Node.js (meitu-cli)
# 部署目标: Zeabur
# =============================================

FROM python:3.12-slim

# 安装Node.js + 系统依赖（Tesseract OCR用于改字功能）
RUN set -ex \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        tesseract-ocr \
        tesseract-ocr-chi-sim \
        tesseract-ocr-chi-tra \
        libgl1-mesa-glx \
        libglib2.0-0 \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && python3 --version

WORKDIR /app

# 安装 Node.js 依赖
COPY package.json package-lock.json* ./
RUN npm install && npm cache clean --force

# 安装 Python 依赖（免费工具：rembg抠图、OpenCV处理、Tesseract改字）
COPY server/requirements.txt ./server/requirements.txt
RUN pip install --no-cache-dir -r server/requirements.txt

# 复制全部代码
COPY . .

# 环境变量
ENV PORT=5078
ENV NODE_ENV=production
ENV PYTHON_PATH=/usr/local/bin/python3

EXPOSE 5078

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:$PORT/api/health || exit 1

CMD ["bash", "/app/start.sh"]
