#!/bin/bash

echo "🔧 正在安装 TCP 性能体检工具..."

bash <(curl -fsSL https://raw.githubusercontent.com/liangang/tcp-optimize-tool/main/tcp-diagnose-installer.sh)
chmod +x /usr/local/bin/tcp-diagnose

echo "✅ 安装完成！你现在可以使用命令：tcp-diagnose 来运行 TCP 网络体检。"
