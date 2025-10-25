#!/usr/bin/env bash
# tcp-optimize-tool :: installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- apply
#   curl -fsSL .../install.sh | bash -s -- diagnose
#   curl -fsSL .../install.sh | bash -s -- "diagnose aggressive"

set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main"
TARGET="/usr/local/sbin/vps-ultimate-net.sh"

need_root() {
  if [ "${EUID:-$(id -u)}" != "0" ]; then
    if command -v sudo >/dev/null 2>&1; then
      echo "[installer] using sudo to gain root..."
      exec sudo -E bash "$0" "$@"
    else
      echo "[installer] please run as root (no sudo found)."
      exit 1
    fi
  fi
}

ensure_deps() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl ca-certificates iproute2 procps >/dev/null 2>&1 || true
  fi
}

download() {
  local url="$1" dst="$2"
  echo "[installer] fetching $url -> $dst"
  curl -fsSL "$url" -o "$dst".tmp
  chmod +x "$dst".tmp
  mv "$dst".tmp "$dst"
}

main() {
  need_root "$@"
  ensure_deps
  download "${RAW_BASE}/vps-ultimate-net.sh" "$TARGET"

  # 默认动作（可通过第一个参数覆盖）
  local subcmd="${1:-apply}"

  echo "[installer] installed to $TARGET"
  echo "[installer] running: $TARGET $subcmd"
  exec "$TARGET" "$subcmd"
}

main "$@"
