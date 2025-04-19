#!/bin/bash

echo "🔧 正在安装 TCP 性能体检工具..."

# 正确下载到指定位置
curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/tcp-diagnose.sh -o /usr/local/bin/tcp-diagnose

# 授予可执行权限
chmod +x /usr/local/bin/tcp-diagnose

echo "✅ 安装完成！你现在可以使用命令：tcp-diagnose 来运行 TCP 网络体检。"
