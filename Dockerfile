# =============================================
# Dockerfile - 修图App (Node.js + Python双引擎)
# 免费工具: Python (rembg/OpenCV)
# 改字使用百度OCR API（无需Tesseract）
# 美图工具: Node.js (meitu-cli)
# 部署目标: Zeabur
# =============================================

FROM python:3.12-slim

# Step 1: 系统基础包
RUN set -ex \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        libgl1 \
        libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Step 2: 安装 Node.js 20
RUN set -ex \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && python3 --version

WORKDIR /app

# Step 3: 安装 Node.js 依赖
COPY package.json package-lock.json* ./
RUN npm install && npm cache clean --force

# Step 4: 安装 Python 依赖（先复制requirements.txt）
COPY server/requirements.txt ./server/requirements.txt
RUN pip install --no-cache-dir -r server/requirements.txt

# Step 5: LaMa模型已移除（2C2GB内存不够跑两个实例，降级使用RBF+cv2.inpaint）
# Step 6: 复制全部代码
COPY . .

# 环境变量
ENV PORT=5078
ENV NODE_ENV=production
ENV PYTHON_PATH=/usr/local/bin/python3
ENV BAIDU_OCR_API_KEY=b1iRoKMpNcTjGIFs2F6hk3tw
ENV BAIDU_OCR_SECRET_KEY=MJrwon0eoMmFaHaI0nGNGspWgx3BORUP

EXPOSE 5078

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:$PORT/api/health || exit 1

CMD ["bash", "/app/start.sh"]
