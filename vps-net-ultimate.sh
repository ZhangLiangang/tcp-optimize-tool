#!/usr/bin/env bash
# vps-net-ultimate.sh — VPS 终极网络加速一体化脚本
# 功能见头部注释与 README；建议 root 执行
set -euo pipefail

ACTION="${1:-}"; shift || true
[[ -z "${ACTION}" ]] && { echo "用法：apply|revert|uninstall（示例：apply --profile=auto）"; exit 1; }

PROFILE="auto"       # auto|fqcodel|fqpie|cake
NIC=""
EGRESS=""
INGRESS=""
SET_ECN="0"
CLEAR_DSCP="1"
PERSIST="1"
SYSCTL_DROP="/etc/sysctl.d/99-vps-ultimate-net.conf"
LIMIT_DROP="/etc/security/limits.d/99-vps-ultimate-nofile.conf"
MANAGER_DROP="/etc/systemd/system.conf.d/99-vps-ultimate.conf"
BACKUP_DIR="/root/vps-ultimate-backup-$(date +%Y%m%d-%H%M%S)"

log(){ echo -e "\033[1;36m$*\033[0m"; }
ok(){  echo -e "\033[1;32m[✓] $*\033[0m"; }
wrn(){ echo -e "\033[1;33m[!] $*\033[0m"; }
err(){ echo -e "\033[1;31m[✗] $*\033[0m"; }
need(){ command -v "$1" >/dev/null 2>&1 || { err "缺少命令：$1"; exit 1; }; }

while (( "$#" )); do
  case "$1" in
    --profile=*) PROFILE="${1#*=}";;
    --nic=*) NIC="${1#*=}";;
    --egress=*) EGRESS="${1#*=}";;
    --ingress=*) INGRESS="${1#*=}";;
    --ecn) SET_ECN="1";;
    --no-ecn) SET_ECN="0";;
    --no-dscp-clear) CLEAR_DSCP="0";;
    --no-persist) PERSIST="0";;
    *) wrn "忽略未知参数：$1";;
  esac; shift
done

need sysctl; need tc; need modprobe
command -v ip >/dev/null 2>&1 || alias ip="/sbin/ip"

if [[ -z "${NIC}" ]]; then
  NIC="$(ip -o link show | awk -F': ' '/state UP/{print $2; exit}')"
fi
[[ -z "${NIC}" ]] && { err "未找到活动网卡，请用 --nic=eth0 指定"; exit 1; }

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

write_sysctl(){
  cat > "$SYSCTL_DROP" <<'EOF'
# ===== vps-ultimate: TCP/BBR/内核网络优化 =====
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.ip_local_port_range = 10000 60999
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.optmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 131072 134217728
net.ipv4.tcp_wmem = 4096 131072 134217728
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
fs.file-max = 1048576
vm.swappiness = 10
vm.overcommit_memory = 1
EOF
}

write_limits(){
  mkdir -p /etc/security/limits.d
  cat > "$LIMIT_DROP" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
  mkdir -p /etc/systemd/system.conf.d
  cat > "$MANAGER_DROP" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
}

apply_sysctl_limits(){
  modprobe tcp_bbr 2>/dev/null || true
  if [[ "$PERSIST" == "1" ]]; then
    write_sysctl
    write_limits
  fi
  sysctl --system >/dev/null || true
  systemctl daemon-reload >/dev/null || true
}

detect_modules(){
  local have_cake=0 have_fqpie=0
  modprobe sch_cake 2>/dev/null && have_cake=1 || true
  modprobe sch_pie 2>/dev/null || true
  modprobe sch_fq_pie 2>/dev/null && have_fqpie=1 || true
  modprobe sch_fq_codel 2>/dev/null || true
  modprobe ifb 2>/dev/null || true
  modprobe clsact 2>/dev/null || true
  modprobe act_mirred 2>/dev/null || true
  echo "$have_cake $have_fqpie"
}

apply_qdisc(){
  local ecn_flag="noecn"
  [[ "$SET_ECN" == "1" ]] && ecn_flag="ecn"

  clear_qdisc

  if [[ "$CLEAR_DSCP" == "1" ]]; then
    tc qdisc add dev "$NIC" clsact
    tc filter add dev "$NIC" egress matchall action skbedit priority 0 ip dscp 0 pipe \
                                        action skbedit priority 0 ipv6 dscp 0 2>/dev/null || true
    ok "已启用 DSCP 清零"
  fi

  local have_cake have_fqpie
  read have_cake have_fqpie < <(detect_modules)

  local mode="$PROFILE"
  if [[ "$PROFILE" == "auto" ]]; then
    if [[ -n "$EGRESS" && $have_cake -eq 1 ]]; then
      mode="cake"
    elif [[ $have_fqpie -eq 1 ]]; then
      mode="fqpie"
    else
      mode="fqcodel"
    fi
    wrn "AUTO 选择队列：$mode"
  fi

  case "$mode" in
    cake)
      [[ -z "$EGRESS" ]] && { err "CAKE 需要 --egress=<速率>（如 780mbit）"; exit 1; }
      tc qdisc replace dev "$NIC" root cake bandwidth "$EGRESS" besteffort triple-isolate ack-filter
      ok "出口：CAKE $EGRESS（besteffort, triple-isolate, ack-filter）"
      ;;
    fqpie)
      tc qdisc replace dev "$NIC" root fq_pie $ecn_flag flows 4096 target 15ms tupdate 15ms alpha 2 beta 20
      ok "出口：fq_pie（$ecn_flag, target=15ms）"
      ;;
    fqcodel)
      tc qdisc replace dev "$NIC" root fq_codel $ecn_flag quantum 1514 flows 2048
      ok "出口：fq_codel（$ecn_flag）"
      ;;
    *) err "未知 profile：$PROFILE"; exit 1;;
  esac

  # 入口管理/整形
  if [[ -n "$INGRESS" || "$mode" != "cake" && -n "$INGRESS" ]]; then
    ip link add ifb0 type ifb 2>/dev/null || true
    ip link set ifb0 up
    tc qdisc add dev "$NIC" handle ffff: ingress
    tc filter add dev "$NIC" parent ffff: matchall action mirred egress redirect dev ifb0
    if [[ "$mode" == "cake" && -n "$INGRESS" && $have_cake -eq 1 ]]; then
      tc qdisc replace dev ifb0 root cake bandwidth "$INGRESS" besteffort triple-isolate
      ok "入口：CAKE $INGRESS"
    else
      tc qdisc replace dev ifb0 root fq_codel $ecn_flag
      ok "入口：fq_codel（无整形或内核不支持 CAKE）"
    fi
  fi
}

show_state(){
  echo "----- sysctl 关键项 -----"
  echo -n "tcp_congestion_control = "; sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true
  echo -n "default_qdisc          = "; sysctl -n net.core.default_qdisc 2>/dev/null || true
  echo; echo "----- qdisc(root) -----"
  tc -s qdisc show dev "$NIC" || true
  if ip link show ifb0 >/dev/null 2>&1; then
    echo; echo "----- qdisc(ifb0) -----"
    tc -s qdisc show dev ifb0 || true
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
  sysctl --system >/dev/null || true
  systemctl daemon-reload >/dev/null || true
  ok "已回滚（建议重启以彻底清理旧参数影响）"
}

uninstall_all(){
  revert_all
  ok "卸载完成。"
}

case "$ACTION" in
  apply)
    log "VPS Ultimate Net — APPLY (profile=$PROFILE nic=$NIC egress=${EGRESS:-N/A} ingress=${INGRESS:-N/A} ecn=$SET_ECN dscp_clear=$CLEAR_DSCP persist=$PERSIST)"
    backup_configs
    apply_sysctl_limits
    apply_qdisc
    show_state
    ok "完成。若刚从 CUBIC 切换到 BBR/BBR2，重启一次通常更稳。"
    ;;
  revert)    revert_all ;;
  uninstall) uninstall_all ;;
  *) err "未知动作：$ACTION" && exit 1 ;;
esac
