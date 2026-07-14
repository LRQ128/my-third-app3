#!/bin/bash
# 修图App 后端服务启动脚本
# 运行在 0.0.0.0:5078，公网可访问

cd "$(dirname "$0")"
echo "🔧 启动修图App后端服务 (0.0.0.0:5078)..."
exec python3 app.py
