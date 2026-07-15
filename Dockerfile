# =============================================
# Dockerfile - 修图App (Node.js后端)
# 部署目标: Zeabur
# =============================================

FROM node:20-slim

# 安装系统依赖（美图CLI所需）
RUN set -ex \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /app

# 复制 package.json 并安装依赖
COPY package.json package-lock.json* ./
RUN npm install --registry=https://registry.npmmirror.com && npm cache clean --force

# 安装美图CLI全局
RUN npm install -g @bytedance/meitu-cli@latest --registry=https://registry.npmmirror.com

# 复制服务端代码
COPY server/ ./server/

# 设置环境变量
ENV PORT=5078
ENV NODE_ENV=production

# 暴露端口
EXPOSE 5078

# 启动命令（使用Node主入口）
CMD ["node", "server/index.js"]
