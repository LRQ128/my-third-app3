#!/bin/bash
set -e

# 美图CLI认证配置
MEITU_DIR="$HOME/.meitu"
mkdir -p "$MEITU_DIR"

if [ -n "$MEITU_OPENAPI_ACCESS_KEY" ] && [ -n "$MEITU_OPENAPI_SECRET_KEY" ]; then
  cat > "$MEITU_DIR/credentials.json" << EOF
{"accessKey":"$MEITU_OPENAPI_ACCESS_KEY","secretKey":"$MEITU_OPENAPI_SECRET_KEY"}
EOF
  echo "美图CLI认证配置已完成"
fi

# 复制工具注册表（本地打包进来的）
if [ -f "server/tool-registry.json" ]; then
  cp server/tool-registry.json "$MEITU_DIR/tool-registry.json"
  echo "工具注册表已部署"
fi

# 启动应用
node server/index.js
