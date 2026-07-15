#!/bin/bash
set -e

# 美图CLI认证配置
MEITU_DIR="$HOME/.meitu"
mkdir -p "$MEITU_DIR"

if [ -n "$MEITU_ACCESS_KEY" ] && [ -n "$MEITU_SECRET_KEY" ]; then
  cat > "$MEITU_DIR/credentials.json" << EOF
{"accessKey":"$MEITU_ACCESS_KEY","secretKey":"$MEITU_SECRET_KEY"}
EOF
  echo "美图CLI认证配置已完成"
fi

# 启动应用
node server/index.js
