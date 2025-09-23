#!/usr/bin/env bash
# install.sh — 一键安装/执行 终极网络加速脚本
# 用法：
#   一键默认：  bash <(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh) apply --profile=auto
#   低时延：    bash <(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh) apply --profile=fqcodel --ecn
#   QOS/丢包：  bash <(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh) apply --profile=fqpie --ecn
#   稳定吞吐：  bash <(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh) apply --profile=cake --egress=780mbit
#   回滚：      bash <(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh) revert
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main"
TARGET="/usr/local/bin/vps-net-ultimate"
TMP="$(mktemp -d)"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

# 1) 下载主脚本到本地
curl -fsSL "$RAW_BASE/vps-net-ultimate.sh" -o "$TMP/vps-net-ultimate.sh"
install -m 0755 "$TMP/vps-net-ultimate.sh" "$TARGET"

# 2) 透传后续参数到主脚本（默认无参则显示帮助）
if [[ $# -eq 0 ]]; then
  echo "用法示例："
  echo "  $TARGET apply --profile=auto"
  echo "  $TARGET apply --profile=fqpie --ecn"
  echo "  $TARGET apply --profile=cake --egress=780mbit [--ingress=780mbit]"
  echo "  $TARGET revert | uninstall"
  exit 0
fi

exec "$TARGET" "$@"
