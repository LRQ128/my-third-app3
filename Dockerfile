# =============================================
# Dockerfile - 修图App (Node.js后端)
# 部署目标: Zeabur
# 优化: 精简依赖，健康检查
# =============================================

FROM node:20-slim

# 安装系统依赖
RUN set -ex \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /app

# 复制 package.json 并安装依赖（用官方源，部署环境不需镜像）
COPY package.json package-lock.json* ./
RUN npm install && npm cache clean --force

# 复制服务端代码
COPY server/ ./server/

# 复制启动脚本
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# 环境变量
ENV PORT=5078
ENV NODE_ENV=production

# 暴露端口
EXPOSE 5078

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://localhost:$PORT/api/health || exit 1

# 启动命令
CMD ["bash", "/app/start.sh"]
