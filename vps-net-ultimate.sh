#!/usr/bin/env bash
# vps-net-sane.sh — Steady & Safe VPS network tuning
# 设计目标：可预知、可回滚、最小副作用，优先“轻量+可测量”
# 使用示例：
#   ./vps-net-sane.sh apply --profile=light --ecn
#   ./vps-net-sane.sh apply --profile=cake-egress --egress=200mbit
#   ./vps-net-sane.sh status
#   ./vps-net-sane.sh revert
#
# 关键理念：
# 1) 先做“最小改动”获得 80% 收益；避免 ingress/ifb 与 DSCP 清零的常见副作用
# 2) 仅在你“确定带宽 & 需求”时，再启用 CAKE 整形
# 3) 默认不持久化，观察无回退压力后，再加 --persist
# 4) 所有改动都可一键 revert，并且保留备份

set -euo pipefail

ACTION="${1:-}"; shift || true
if [[ -z "${ACTION}" ]]; then
  echo "用法：apply|status|revert [--profile=light|cake-egress|cake-dual|baseline] [--egress=] [--ingress=] [--ecn] [--persist] [--no-dscp-clear] [--keep-cc] [--dry-run] [--nic=]";
  exit 1
fi

# 默认参数
PROFILE="light"              # baseline|light|cake-egress|cake-dual
NIC=""
EGRESS=""                    # 例如 200mbit / 1gbit
INGRESS=""
SET_ECN=0
PERSIST=0
CLEAR_DSCP=0                 # 默认不清零 DSCP
KEEP_CC=0                    # 默认切到 BBR；若指定 --keep-cc 则保留当前拥塞算法
DRY_RUN=0

# 文件路径
SYSCTL_DROP="/etc/sysctl.d/98-vps-net-sane.conf"
LIMIT_DROP="/etc/security/limits.d/98-vps-net-sane-nofile.conf"
MANAGER_DROP="/etc/systemd/system.conf.d/98-vps-net-sane.conf"
BACKUP_DIR="/root/vps-net-sane-$(date +%Y%m%d-%H%M%S)"

# 彩色输出
log(){ echo -e "\033[1;36m$*\033[0m"; }
ok(){  echo -e "\033[1;32m[✓] $*\033[0m"; }
wrn(){ echo -e "\033[1;33m[!] $*\033[0m"; }
err(){ echo -e "\033[1;31m[✗] $*\033[0m"; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "缺少命令：$1"; exit 1; }; }

# 解析参数
while (( "$#" )); do
  case "$1" in
    --profile=*) PROFILE="${1#*=}";;
    --nic=*) NIC="${1#*=}";;
    --egress=*) EGRESS="${1#*=}";;
    --ingress=*) INGRESS="${1#*=}";;
    --ecn) SET_ECN=1;;
    --persist) PERSIST=1;;
    --no-dscp-clear) CLEAR_DSCP=0;;
    --dscp-clear) CLEAR_DSCP=1;;
    --keep-cc) KEEP_CC=1;;
    --dry-run) DRY_RUN=1;;
    *) wrn "忽略未知参数：$1";;
  esac; shift
done

need sysctl; need tc
command -v ip >/dev/null 2>&1 || alias ip="/sbin/ip"

# 环境探测
virt=$(command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt || echo "unknown")
kernel=$(uname -r)

# 网卡检测
if [[ -z "${NIC}" ]]; then
  NIC=$(ip -o link show | awk -F': ' '/state UP/{print $2; exit}')
fi
[[ -z "${NIC}" ]] && { err "未找到活动网卡，请用 --nic=eth0 指定"; exit 1; }

# 模块探测
have_mod(){ lsmod | awk '{print $1}' | grep -q "^$1$" || modprobe "$1" 2>/dev/null; }

detect_modules(){
  local cake=0 fqcodel=0 fqpie=0
  have_mod sch_cake    && cake=1 || true
  have_mod sch_fq_codel && fqcodel=1 || true
  have_mod sch_fq_pie  && fqpie=1 || true
  have_mod ifb || true
  have_mod clsact || true
  have_mod act_mirred || true
  echo "$cake $fqcodel $fqpie"
}

# 配置写入（谨慎增量，仅必要项）
write_sysctl(){
  cat > "${SYSCTL_DROP}" <<'EOF'
# vps-net-sane: 轻量网络参数（保守）
# 拥塞算法：默认 BBR（若 --keep-cc 则不改变）
# 默认队列：fq（轻量，配合 fq_codel 时仍以 tc 为准）
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
# 适度的 buffer 限制（避免过大引起 bloat）
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 4096
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864
# 文件句柄上限（常见高并发服务用）
fs.file-max = 1048576
EOF
}

write_limits(){
  mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d
  cat > "${LIMIT_DROP}" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
  cat > "${MANAGER_DROP}" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
}

apply_sysctl_limits(){
  if (( PERSIST )); then
    write_sysctl
    write_limits
  fi
  if (( KEEP_CC == 0 )); then
    # 尽量切到 BBR；失败不致命
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  fi
  sysctl --system >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

# qdisc 相关
clear_qdisc(){
  set +e
  tc qdisc del dev "$NIC" root 2>/dev/null
  tc qdisc del dev "$NIC" clsact 2>/dev/null
  tc qdisc del dev "$NIC" ingress 2>/dev/null
  ip link set ifb0 down 2>/dev/null
  tc qdisc del dev ifb0 root 2>/dev/null
  ip link delete ifb0 type ifb 2>/dev/null
  set -e
}

apply_qdisc(){
  local ecn_flag="noecn"
  (( SET_ECN )) && ecn_flag="ecn"

  # 不默认清 DSCP，除非显式 --dscp-clear
  if (( CLEAR_DSCP )); then
    tc qdisc add dev "$NIC" clsact 2>/dev/null || true
    tc filter add dev "$NIC" egress matchall action skbedit priority 0 ip dscp 0 pipe \
                                        action skbedit priority 0 ipv6 dscp 0 2>/dev/null || true
    ok "已启用 DSCP 清零（谨慎使用）"
  fi

  local have_cake have_fqcodel have_fqpie
  read have_cake have_fqcodel have_fqpie < <(detect_modules)

  case "$PROFILE" in
    baseline)
      ok "baseline：不改 qdisc，仅使用系统默认（fq/whatever）" ;;

    light)
      # 只在出口应用 fq_codel，轻量安全
      tc qdisc replace dev "$NIC" root fq_codel $ecn_flag quantum 1514 flows 2048
      ok "出口：fq_codel（$ecn_flag）" ;;

    cake-egress)
      [[ -z "$EGRESS" ]] && { err "cake-egress 需要 --egress=<速率>（如 200mbit）"; exit 1; }
      (( have_cake )) || { err "内核不支持 sch_cake"; exit 1; }
      tc qdisc replace dev "$NIC" root cake bandwidth "$EGRESS" besteffort triple-isolate ack-filter $([ "$ecn_flag" = ecn ] && echo ecn || echo noecn)
      ok "出口：CAKE $EGRESS（besteffort triple-isolate ack-filter $ecn_flag）" ;;

    cake-dual)
      [[ -z "$EGRESS" || -z "$INGRESS" ]] && { err "cake-dual 需要 --egress= 与 --ingress="; exit 1; }
      (( have_cake )) || { err "内核不支持 sch_cake"; exit 1; }
      # 出口
      tc qdisc replace dev "$NIC" root cake bandwidth "$EGRESS" besteffort triple-isolate $([ "$ecn_flag" = ecn ] && echo ecn || echo noecn)
      # 入口 — 仅在明确需要时
      ip link add ifb0 type ifb 2>/dev/null || true
      ip link set ifb0 up
      tc qdisc add dev "$NIC" handle ffff: ingress 2>/dev/null || true
      tc filter add dev "$NIC" parent ffff: matchall action mirred egress redirect dev ifb0 2>/dev/null || true
      tc qdisc replace dev ifb0 root cake bandwidth "$INGRESS" besteffort triple-isolate $([ "$ecn_flag" = ecn ] && echo ecn || echo noecn)
      ok "出口：CAKE $EGRESS；入口：CAKE $INGRESS（谨慎，注意 CPU 开销）" ;;

    *) err "未知 profile：$PROFILE"; exit 1 ;;
  esac
}

show_status(){
  echo "===== 基础信息 ====="
  echo "Virt: $virt"; echo "Kernel: $kernel"; echo "NIC: $NIC"
  echo
  echo "===== sysctl 关键项 ====="
  echo -n "tcp_congestion_control = "; sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true
  echo -n "default_qdisc          = "; sysctl -n net.core.default_qdisc 2>/dev/null || true
  echo -n "netdev_max_backlog     = "; sysctl -n net.core.netdev_max_backlog 2>/dev/null || true
  echo
  echo "===== qdisc(root) ====="; tc -s qdisc show dev "$NIC" || true
  if ip link show ifb0 >/dev/null 2>&1; then
    echo; echo "===== qdisc(ifb0) ====="; tc -s qdisc show dev ifb0 || true
  fi
}

backup_configs(){
  mkdir -p "$BACKUP_DIR"
  cp -a /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak" 2>/dev/null || true
  cp -a "$SYSCTL_DROP" "$BACKUP_DIR/" 2>/dev/null || true
  cp -a /etc/security/limits.conf "$BACKUP_DIR/limits.conf.bak" 2>/dev/null || true
  cp -a "$LIMIT_DROP" "$BACKUP_DIR/" 2>/dev/null || true
  cp -a "$MANAGER_DROP" "$BACKUP_DIR/" 2>/dev/null || true
  ok "已备份配置到：$BACKUP_DIR"
}

revert_all(){
  clear_qdisc
  rm -f "$SYSCTL_DROP" "$LIMIT_DROP" "$MANAGER_DROP" 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "已回滚；建议重启以确保拥塞算法/句柄完全恢复"
}

# 主流程
case "$ACTION" in
  apply)
    log "vps-net-sane APPLY (profile=$PROFILE nic=$NIC egress=${EGRESS:-N/A} ingress=${INGRESS:-N/A} ecn=$SET_ECN dscp_clear=$CLEAR_DSCP persist=$PERSIST keep_cc=$KEEP_CC dry_run=$DRY_RUN)"
    backup_configs
    if (( DRY_RUN )); then
      wrn "dry-run：仅显示即将执行的策略，不落地"; show_status; exit 0
    fi
    apply_sysctl_limits
    clear_qdisc
    apply_qdisc
    show_status
    ok "完成。建议：先观察 24–48 小时再决定是否 --persist 持久化。" ;;

  status)
    show_status ;;

  revert)
    revert_all ;;

  *) err "未知动作：$ACTION"; exit 1 ;;

esac
