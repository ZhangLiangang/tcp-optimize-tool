#!/bin/bash

echo "🔧 正在下载 tcp-optimize-all.sh 优化器..."

curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/tcp-optimize-all.sh -o tcp-optimize-all.sh

if [[ $? -ne 0 ]]; then
    echo "❌ 下载失败，请检查网络或 GitHub 路径是否正确。"
    exit 1
fi

chmod +x tcp-optimize-all.sh

echo "🚀 开始执行优化..."
./tcp-optimize-all.sh
