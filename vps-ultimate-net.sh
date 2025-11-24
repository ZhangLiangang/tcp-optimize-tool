#!/usr/bin/env bash
set -euo pipefail

# ========== 基本信息 ==========
SCRIPT_NAME="vps-ultimate-net"
SYSCTL_FILE="/etc/sysctl.d/99-${SCRIPT_NAME}.conf"
LIMITS_FILE="/etc/security/limits.d/99-${SCRIPT_NAME}.conf"
SYSTEMD_DROPIN="/etc/systemd/system.conf.d/99-${SCRIPT_NAME}.conf"
RPS_SERVICE="/etc/systemd/system/${SCRIPT_NAME}-rps.service"
RPS_SCRIPT="/usr/local/sbin/${SCRIPT_NAME}-rps-apply.sh"
ETHTOOL_SERVICE="/etc/systemd/system/${SCRIPT_NAME}-ethtool.service"
BACKUP_DIR="/var/backups/${SCRIPT_NAME}"
LOG_TAG="${SCRIPT_NAME}"

log()  { echo -e "[${LOG_TAG}] $*"; }
warn() { echo -e "[${LOG_TAG}] \033[33m$*\033[0m"; }
err()  { echo -e "[${LOG_TAG}] \033[31m$*\033[0m" >&2; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "请以 root 运行：sudo bash $0 <apply|status|selftest|diagnose|diagnose aggressive|rollback|purge>"
    exit 1
  fi
}

detect_iface() {
  local cand
  # 首选有 IPv4 地址、非 lo / 容器设备
  for cand in /sys/class/net/*; do
    cand=$(basename "$cand")
    [[ "$cand" == "lo" ]] && continue
    [[ "$cand" == docker* || "$cand" == veth* || "$cand" == br-* || "$cand" == "tailscale0" ]] && continue
    ip -o -4 addr show dev "$cand" | grep -q 'inet ' && { echo "$cand"; return; }
  done
  # 退而求其次，选任意非 lo 设备
  for cand in /sys/class/net/*; do
    cand=$(basename "$cand")
    [[ "$cand" == "lo" ]] || { echo "$cand"; return; }
  done
}

# ========== BBR 检测（最低要求：必须支持 BBR/BBR2） ==========
support_bbr2=0
support_bbr=0
BBR_MIN_REQUIRED=1       # 你的要求：最低必须 BBR
HAVE_BBR=0               # 实际检测到是否有 BBR/BBR2
BBR_HARD_FAIL=0          # 若最终无 BBR，则在自检中给出硬错误

detect_bbr() {
  local avail

  support_bbr2=0
  support_bbr=0
  HAVE_BBR=0
  BBR_HARD_FAIL=0

  # 尝试加载 BBR 模块（有些内核是模块形式）
  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr  2>/dev/null || true
    modprobe tcp_bbr2 2>/dev/null || true
  fi

  if ! avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null); then
    warn "无法读取 net.ipv4.tcp_available_congestion_control，假定当前不可用 BBR，将使用 cubic。"
    if (( BBR_MIN_REQUIRED == 1 )); then
      BBR_HARD_FAIL=1
    fi
    return
  fi

  if [[ "$avail" =~ (^|[[:space:]])bbr2([[:space:]]|$) ]]; then
    support_bbr2=1
    HAVE_BBR=1
  fi
  if [[ "$avail" =~ (^|[[:space:]])bbr([[:space:]]|$) ]]; then
    support_bbr=1
    HAVE_BBR=1
  fi

  if (( BBR_MIN_REQUIRED == 1 && HAVE_BBR == 0 )); then
    BBR_HARD_FAIL=1
    warn "内核当前未提供 BBR/BBR2 拥塞控制算法，不满足最低要求。将暂时使用 cubic，但自检会标记为 FAIL。"
  fi
}

backup_once() {
  mkdir -p "$BACKUP_DIR"
  for f in "$SYSCTL_FILE" "$LIMITS_FILE" "$SYSTEMD_DROPIN" "$RPS_SERVICE" "$RPS_SCRIPT" "$ETHTOOL_SERVICE"; do
    if [[ -f "$f" ]]; then
      cp -a "$f" "$BACKUP_DIR/$(basename "$f").bak.$(date +%s)"
      log "已备份：$f -> $BACKUP_DIR"
    fi
  done
}

ensure_packages() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y iproute2 iperf3 ethtool procps >/dev/null 2>&1 || true
  fi
}

write_sysctl() {
  detect_bbr

  local qdisc="fq"
  local cc="cubic"

  # 优先级：bbr2 > bbr；若内核无 BBR，则仍用 cubic 但标记为硬错误
  if (( HAVE_BBR == 1 )); then
    if (( support_bbr2 == 1 )); then
      cc="bbr2"
    elif (( support_bbr == 1 )); then
      cc="bbr"
    fi
  else
    # 没有 BBR，只能安全使用 cubic，实际不满足你的“最低要求”
    cc="cubic"
  fi

  cat >"$SYSCTL_FILE" <<EOF
# ${SCRIPT_NAME}: 网络/内核性能增强（可安全回滚）
# 队列与拥塞控制
net.core.default_qdisc = ${qdisc}
net.ipv4.tcp_congestion_control = ${cc}

# 放大队列/缓冲（保守安全值）
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535

# TCP 优化
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_window_scaling = 1

# 兼容性
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.route.gc_timeout = 100
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.tcp_timestamps = 1
EOF

  log "已写入 sysctl 配置：$SYSCTL_FILE"
  sysctl --system >/dev/null || sysctl -p "$SYSCTL_FILE" || true
}

write_limits() {
  cat >"$LIMITS_FILE" <<'EOF'
# 提高文件句柄与进程数限制（对高并发服务必要）
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  262144
* hard nproc  262144
root soft nofile 1048576
root hard nofile 1048576
root soft nproc  262144
root hard nproc  262144
EOF

  mkdir -p "$(dirname "$SYSTEMD_DROPIN")"
  cat > "$SYSTEMD_DROPIN" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=262144
EOF

  log "已写入 limits：$LIMITS_FILE 与 systemd drop-in：$SYSTEMD_DROPIN"
}

write_rps_script() {
  cat >"$RPS_SCRIPT" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

mask_all_cpus() {
  local ncpus mask=0 i=0
  ncpus=$(nproc)
  while (( i < ncpus )); do
    mask=$((mask | (1<<i) ))
    ((i++))
  done
  printf "%x\n" "$mask"
}

apply_rps_for_iface() {
  local IFACE="$1"
  local mask
  mask=$(mask_all_cpus)

  local rxq
  for rxq in /sys/class/net/"$IFACE"/queues/rx-*; do
    [[ -e "$rxq" ]] || continue
    echo "$mask" > "$rxq/rps_cpus" || true
    echo 32768 > "$rxq/rps_flow_cnt" || true
  done

  local txq
  for txq in /sys/class/net/"$IFACE"/queues/tx-*; do
    [[ -e "$txq" ]] || continue
    if [[ -w "$txq/xps_cpus" ]]; then
      echo "$mask" > "$txq/xps_cpus" || true
    fi
  done
}

main() {
  for dev in /sys/class/net/*; do
    dev=$(basename "$dev")
    [[ "$dev" == "lo" ]] && continue
    [[ "$dev" == docker* || "$dev" == veth* || "$dev" == br-* || "$dev" == "tailscale0" ]] && continue
    if ip -o link show "$dev" >/dev/null 2>&1; then
      apply_rps_for_iface "$dev"
    fi
  done
}
main
EOS
  chmod +x "$RPS_SCRIPT"
  log "已生成 RPS 应用脚本：$RPS_SCRIPT"
}

write_rps_service() {
  cat >"$RPS_SERVICE" <<EOF
[Unit]
Description=Apply RPS/XPS settings for ${SCRIPT_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${RPS_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$(basename "$RPS_SERVICE")" || true
  log "已安装并启用 RPS/XPS 开机服务：$(basename "$RPS_SERVICE")"
}

# ========== 自检模块 ==========
PASS_CNT=0
FAIL_CNT=0

record() {
  local ok="$1" msg="$2"
  if [[ "$ok" == "1" ]]; then
    echo -e "✅  $msg"
    PASS_CNT=$((PASS_CNT+1))
  else
    echo -e "❌  $msg"
    FAIL_CNT=$((FAIL_CNT+1))
  fi
}

check_eq() { # key expected
  local key="$1" expected="$2" got
  got=$(sysctl -n "$key" 2>/dev/null || echo "")
  if [[ "$got" == "$expected" ]]; then
    record 1 "sysctl $key = $expected"
  else
    record 0 "sysctl $key 期望=$expected 实际=${got:-<空>}"
  fi
}

check_ge() { # key >= min
  local key="$1" min="$2" got
  got=$(sysctl -n "$key" 2>/dev/null || echo 0)
  if [[ "$got" =~ ^[0-9]+$ ]] && (( got >= min )); then
    record 1 "sysctl $key >= $min (当前 $got)"
  else
    record 0 "sysctl $key 应>= $min (当前 ${got})"
  fi
}

check_file_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    record 1 "存在文件：$f"
  else
    record 0 "缺少文件：$f"
  fi
}

check_service_enabled() {
  local svc
  svc="$(basename "$1")"
  if systemctl is-enabled "$svc" &>/dev/null; then
    record 1 "systemd 服务已启用：$svc"
  else
    record 0 "systemd 服务未启用：$svc"
  fi
  if systemctl is-active "$svc" &>/dev/null; then
    record 1 "systemd 服务已运行：$svc"
  else
    record 0 "systemd 服务未运行：$svc"
  fi
}

check_rps_xps_nonzero() {
  local dev rxfile txfile v any ok
  for dev in /sys/class/net/*; do
    dev=$(basename "$dev")
    [[ "$dev" == "lo" ]] && continue
    [[ "$dev" == docker* || "$dev" == veth* || "$dev" == br-* || "$dev" == "tailscale0" ]] && continue
    if [[ -d "/sys/class/net/$dev/queues" ]]; then
      any=0
      ok=1
      for rxfile in /sys/class/net/"$dev"/queues/rx-*/rps_cpus; do
        [[ -f "$rxfile" ]] || continue
        any=1
        v=$(cat "$rxfile")
        if [[ "$v" == "0" || -z "$v" ]]; then
          ok=0
        fi
      done
      for txfile in /sys/class/net/"$dev"/queues/tx-*/xps_cpus; do
        [[ -f "$txfile" ]] || continue
        any=1
        v=$(cat "$txfile")
        if [[ "$v" == "0" || -z "$v" ]]; then
          ok=0
        fi
      done
      if (( any == 1 )); then
        record $ok "RPS/XPS 非零掩码：$dev"
      fi
    fi
  done
}

check_ulimit_nofile() {
  local cur
  cur=$(ulimit -n 2>/dev/null || echo 0)
  if [[ "$cur" =~ ^[0-9]+$ ]] && (( cur >= 1048576 )); then
    record 1 "当前会话 nofile >= 1048576（$cur）"
  else
    record 0 "当前会话 nofile 不足（$cur），需重启后新会话继承 systemd 限额"
  fi
}

selftest_all() {
  PASS_CNT=0
  FAIL_CNT=0

  # 再次检测 BBR 状态，以确保自检逻辑与当前内核真实状态一致
  detect_bbr

  echo "===== ${SCRIPT_NAME} 自检开始 ====="
  check_file_exists "$SYSCTL_FILE"
  check_file_exists "$LIMITS_FILE"
  check_file_exists "$SYSTEMD_DROPIN"
  check_file_exists "$RPS_SCRIPT"
  check_file_exists "$RPS_SERVICE"
  check_service_enabled "$RPS_SERVICE"

  local cc exp_cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")

  if (( HAVE_BBR == 1 )); then
    if (( support_bbr2 == 1 )); then
      exp_cc="bbr2"
    elif (( support_bbr == 1 )); then
      exp_cc="bbr"
    else
      exp_cc="bbr"
    fi
  else
    # 最低要求是 BBR，因此期望值仍然是 BBR；实际不是就 FAIL
    exp_cc="bbr"
  fi

  # BBR 核心检查：必须是 bbr/bbr2，否则判定为不满足最低要求
  check_eq net.ipv4.tcp_congestion_control "$exp_cc"
  if (( BBR_HARD_FAIL == 1 || HAVE_BBR == 0 )); then
    record 0 "内核未提供 BBR/BBR2（或无法启用），不满足最低要求，请更换内核或启用 tcp_bbr 模块。"
  fi

  check_eq net.core.default_qdisc "fq"
  check_ge net.core.rmem_max 134217728
  check_ge net.core.wmem_max 134217728
  check_ge net.core.netdev_max_backlog 250000
  check_ge net.core.somaxconn 65535
  check_eq net.ipv4.tcp_fastopen 3
  check_eq net.ipv4.tcp_mtu_probing 1
  check_eq net.ipv4.tcp_slow_start_after_idle 0
  check_ge net.ipv4.neigh.default.gc_thresh3 16384

  check_rps_xps_nonzero
  check_ulimit_nofile

  echo "===== 自检结束：PASS=$PASS_CNT, FAIL=$FAIL_CNT ====="
  if (( FAIL_CNT > 0 )); then
    warn "存在未通过项。若仅为 nofile，可重启后再次自检；若为 BBR 相关错误，则当前内核不满足你的最低要求。"
    return 1
  fi
  return 0
}

status_all() {
  echo "===== Sysctl 关键项 ====="
  sysctl net.ipv4.tcp_congestion_control || true
  sysctl net.core.default_qdisc || true
  sysctl net.core.rmem_max net.core.wmem_max || true
  sysctl net.core.netdev_max_backlog || true
  sysctl net.core.somaxconn || true
  sysctl net.ipv4.tcp_fastopen || true
  sysctl vm.swappiness || true

  echo -e "\n===== RPS/XPS 检查 ====="
  local dev rxq txq
  for dev in /sys/class/net/*; do
    dev=$(basename "$dev")
    [[ "$dev" == "lo" ]] && continue
    [[ "$dev" == docker* || "$dev" == veth* || "$dev" == br-* || "$dev" == "tailscale0" ]] && continue
    if [[ -d "/sys/class/net/$dev/queues" ]]; then
      echo ">> $dev"
      for rxq in /sys/class/net/"$dev"/queues/rx-*; do
        [[ -e "$rxq" ]] || continue
        echo -n "  $(basename "$rxq") rps_cpus="; cat "$rxq/rps_cpus"
      done
      for txq in /sys/class/net/"$dev"/queues/tx-*; do
        [[ -e "$txq" ]] || continue
        if [[ -f "$txq/xps_cpus" ]]; then
          echo -n "  $(basename "$txq") xps_cpus="; cat "$txq/xps_cpus"
        else
          echo "  $(basename "$txq") xps_cpus=<不支持/不存在>"
        fi
      done
    fi
  done

  echo -e "\n===== NOFILE 限制（当前会话）====="
  ulimit -n || true
}

# ========== 诊断与自动调优 ==========
iface_driver() {
  local IF
  IF="$(detect_iface)"
  [[ -z "${IF:-}" ]] && IF="eth0"
  if command -v ethtool >/dev/null 2>&1; then
    ethtool -i "$IF" 2>/dev/null | awk -F': ' '/driver:/{print $2; exit}' || echo "unknown"
  else
    echo "unknown"
  fi
}

iface_name() {
  local IF
  IF="$(detect_iface)"
  [[ -z "${IF:-}" ]] && IF="eth0"
  echo "$IF"
}

driver_in_safe_offload_list() {
  local d="$1"
  [[ "$d" == virtio_net || "$d" == ena || "$d" == vmxnet3 || "$d" == hv_netvsc || "$d" == mlx* ]]
}

iperf3_loopback() {
  local PORT
  PORT=$(( 50000 + RANDOM % 10000 ))
  pkill -f "iperf3 -s -p $PORT" >/dev/null 2>&1 || true
  (iperf3 -s -p "$PORT" >/dev/null 2>&1 &)
  sleep 0.5
  local single multi
  single=$(iperf3 -c 127.0.0.1 -p "$PORT" -t 3 2>/dev/null | awk '/sender$/ {bps=$(NF-1);unit=$NF; if(unit=="Gbits/sec")v=bps*1000; else if(unit=="Mbits/sec")v=bps; else v=0; s=v} END{printf "%.0f", s+0}')
  multi=$(iperf3 -c 127.0.0.1 -p "$PORT" -t 3 -P 4 2>/dev/null | awk '/SUM.*sender$/ {bps=$(NF-1);unit=$NF; if(unit=="Gbits/sec")v=bps*1000; else if(unit=="Mbits/sec")v=bps; else v=0; s=v} END{printf "%.0f", s+0}')
  pkill -f "iperf3 -s -p $PORT" >/dev/null 2>&1 || true
  echo "${single:-0} ${multi:-0}"
}

persist_ethtool_off() {
  local IF="$1"
  cat >"$ETHTOOL_SERVICE" <<EOF
[Unit]
Description=Persist ethtool offloads for ${SCRIPT_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -K ${IF} gro off gso off tso off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$(basename "$ETHTOOL_SERVICE")" || true
  log "已持久化关闭 ${IF} 的 GRO/GSO/TSO：$(basename "$ETHTOOL_SERVICE")"
}

auto_fix_safe() {
  sysctl --system >/dev/null || true
  systemctl daemon-reload || true
  systemctl enable --now "$(basename "$RPS_SERVICE")" || true
  bash "$RPS_SCRIPT" || true
}

diagnose_core() {
  need_root
  ensure_packages

  echo "===== ${SCRIPT_NAME} 诊断开始 ====="
  local KERN CPUS IFACE DRV QDISC CC
  KERN="$(uname -r)"
  CPUS="$(nproc)"
  IFACE="$(iface_name)"
  DRV="$(iface_driver)"
  QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")"
  CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")"

  echo "内核：$KERN"
  echo "CPU 核心：$CPUS"
  echo "网卡：$IFACE（驱动：$DRV）"
  echo "qdisc：$QDISC, 拥塞算法：$CC"

  local L1 L4
  read L1 L4 < <(iperf3_loopback)
  echo "loopback 基准：单流 ${L1} Mbit/s，4 流 ${L4} Mbit/s"

  local NEED_FIX=0
  if [[ "$QDISC" != "fq" ]]; then
    echo "建议：将 default_qdisc 设为 fq（当前 $QDISC）。已在配置中指定，将立即修正。"
    NEED_FIX=1
  fi

  local avail EXP_CC
  detect_bbr
  avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
  EXP_CC="bbr"
  if (( HAVE_BBR == 1 )); then
    if (( support_bbr2 == 1 )); then
      EXP_CC="bbr2"
    elif (( support_bbr == 1 )); then
      EXP_CC="bbr"
    fi
  fi

  if [[ "$CC" != "$EXP_CC" ]]; then
    echo "建议：将拥塞控制设置为 $EXP_CC（当前 $CC）。已在配置中指定，将立即修正。"
    NEED_FIX=1
  fi

  local ANY_ZERO=0 f
  for f in /sys/class/net/"$IFACE"/queues/rx-*/rps_cpus /sys/class/net/"$IFACE"/queues/tx-*/xps_cpus; do
    [[ -f "$f" ]] || continue
    [[ "$(cat "$f")" == "0" ]] && ANY_ZERO=1
  done
  if (( ANY_ZERO == 1 )); then
    echo "建议：为 $IFACE 开启 RPS/XPS 并分布到所有 CPU。将立即修正。"
    NEED_FIX=1
  fi

  if (( NEED_FIX == 1 )); then
    auto_fix_safe
    echo "已应用上述安全修复。"
  else
    echo "安全修复：不需要。"
  fi

  local AGGRESSIVE_SUGGEST=0
  local REASON=""
  if ! driver_in_safe_offload_list "$DRV"; then
    if (( L1 < 2500 || L4 < 6000 )); then
      AGGRESSIVE_SUGGEST=1
      REASON="检测到驱动非主流虚拟化栈且 loopback 吞吐偏低，可能受 GRO/GSO/TSO 影响。"
    fi
  fi

  echo "===== 诊断建议汇总 ====="
  echo "- qdisc 建议：fq（已由脚本管理）"
  echo "- 拥塞算法建议：$EXP_CC（已由脚本管理，且 BBR 为最低要求）"
  echo "- RPS/XPS：所有队列掩码非 0（脚本已自动纠正）"
  if (( AGGRESSIVE_SUGGEST == 1 )); then
    echo "- 进取建议：$REASON 建议关闭 ${IFACE} 的 GRO/GSO/TSO 并持久化。"
  else
    echo "- 进取建议：无需调整 offload（或驱动属于安全白名单）。"
  fi

  echo "AGGRESSIVE_SUGGEST=$AGGRESSIVE_SUGGEST"
}

diagnose_safe() {
  local out
  out="$(diagnose_core)"
  echo "$out"
  selftest_all || true
}

diagnose_aggressive() {
  local out
  out="$(diagnose_core)"
  echo "$out"
  local IFACE flag
  IFACE="$(iface_name)"
  flag=$(echo "$out" | awk -F'=' '/AGGRESSIVE_SUGGEST=/{print $2; exit}')
  if [[ "$flag" == "1" ]]; then
    if command -v ethtool >/dev/null 2>&1; then
      /sbin/ethtool -K "$IFACE" gro off gso off tso off || true
      persist_ethtool_off "$IFACE"
      echo "已按进取模式应用 offload 关闭，并写入持久化服务：$ETHTOOL_SERVICE"
    fi
  else
    echo "进取模式：无需要额外更改。"
  fi
  selftest_all || true
}

rollback_all() {
  need_root
  warn "将移除本脚本写入的配置并重载系统。"
  [[ -f "$SYSCTL_FILE" ]] && rm -f "$SYSCTL_FILE"
  [[ -f "$LIMITS_FILE" ]] && rm -f "$LIMITS_FILE"
  [[ -f "$SYSTEMD_DROPIN" ]] && rm -f "$SYSTEMD_DROPIN"
  if systemctl is-enabled "$(basename "$RPS_SERVICE")" &>/dev/null; then
    systemctl disable --now "$(basename "$RPS_SERVICE")" || true
  fi
  [[ -f "$RPS_SERVICE" ]] && rm -f "$RPS_SERVICE"
  [[ -f "$RPS_SCRIPT"  ]] && rm -f "$RPS_SCRIPT"

  if [[ -f "$ETHTOOL_SERVICE" ]]; then
    if systemctl is-enabled "$(basename "$ETHTOOL_SERVICE")" &>/dev/null; then
      systemctl disable --now "$(basename "$ETHTOOL_SERVICE")" || true
    fi
    rm -f "$ETHTOOL_SERVICE"
  fi

  sysctl --system >/dev/null || true
  systemctl daemon-reload || true
  log "回滚完成。建议重启：reboot"
}

purge_all() {
  rollback_all
  [[ -d "$BACKUP_DIR" ]] && rm -rf "$BACKUP_DIR"
  log "已清理备份目录：$BACKUP_DIR"
}

apply_all() {
  need_root
  ensure_packages
  mkdir -p "$BACKUP_DIR"
  backup_once
  write_sysctl
  write_limits
  write_rps_script
  write_rps_service

  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  log "当前拥塞控制算法：${cc:-<未知>}"
  log "apply 完成。将自动执行自检..."
  if selftest_all; then
    log "自检通过。"
  else
    if (( BBR_HARD_FAIL == 1 || HAVE_BBR == 0 )); then
      err "自检未通过：当前内核未满足最低要求 BBR/BBR2。请更换内核或启用 tcp_bbr 模块。"
    else
      warn "自检存在未通过项，详见上方输出。"
    fi
  fi
  log "建议重启以使 systemd 限额完全生效：reboot"
}

usage() {
  cat <<EOF
用法：$0 {apply|status|selftest|diagnose|diagnose aggressive|rollback|purge}

  apply                 应用/更新优化（完成后自动自检，要求至少 BBR）
  status                查看关键状态（sysctl/RPS/NOFILE）
  selftest              手动运行自检（若未满足 BBR 最低要求则退出码非 0）
  diagnose              诊断并输出建议，自动应用“安全修复”
  diagnose aggressive   诊断并应用“进取修复”（可能关闭 GRO/GSO/TSO），可回滚
  rollback              回滚本脚本写入的所有配置与服务
  purge                 回滚并删除备份目录

备注：
- 最低要求为 BBR/BBR2；若内核未提供，将在自检中明确 FAIL，并提醒更换内核或启用 tcp_bbr。
- 自检若仅报 nofile，不影响网络性能；重启后新会话会继承提升的限额。
- 进取模式仅在驱动非 virtio_net/ena/vmxnet3/mlx*/hv_netvsc 且 loopback 明显偏低时才会动 offload。
EOF
}

case "${1:-}" in
  apply)                  apply_all ;;
  status)                 status_all ;;
  selftest)               selftest_all ;;
  diagnose)               diagnose_safe ;;
  "diagnose aggressive")  diagnose_aggressive ;;
  rollback)               rollback_all ;;
  purge)                  purge_all ;;
  *)                      usage; exit 1 ;;
esac
