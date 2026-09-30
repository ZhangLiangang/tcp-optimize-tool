#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

# vps-ultimate-net v2
# Adaptive TCP/network tuning for modern Ubuntu/Debian VPS.
# Safe design goals:
#   - apply/repair are the only commands that change persistent tuning.
#   - diagnose/status/selftest are read-only.
#   - BBR is a hard requirement for apply/repair.
#   - GRO/GSO/TSO are never disabled automatically.
#   - RPS/XPS are configured according to CPU/queue topology, not "all queues -> all CPUs".
#   - a first-run baseline is saved and rollback restores that baseline.

SCRIPT_NAME="vps-ultimate-net"
SCRIPT_VERSION="2.0.0"

SYSCTL_FILE="/etc/sysctl.d/99-${SCRIPT_NAME}.conf"
LIMITS_FILE="/etc/security/limits.d/99-${SCRIPT_NAME}.conf"
SYSTEMD_DROPIN="/etc/systemd/system.conf.d/99-${SCRIPT_NAME}.conf"
RPS_SERVICE="/etc/systemd/system/${SCRIPT_NAME}-rps.service"
RPS_SCRIPT="/usr/local/sbin/${SCRIPT_NAME}-rps-apply.sh"
LEGACY_ETHTOOL_SERVICE="/etc/systemd/system/${SCRIPT_NAME}-ethtool.service"

BACKUP_DIR="/var/backups/${SCRIPT_NAME}"
BASELINE_DIR="${BACKUP_DIR}/baseline-v2"
BASELINE_STATE="${BASELINE_DIR}/files.tsv"
BASELINE_RPS_STATE="${BASELINE_DIR}/rps-xps.tsv"
BASELINE_SYSCTL_STATE="${BASELINE_DIR}/sysctl.tsv"
BASELINE_SERVICE_STATE="${BASELINE_DIR}/services.tsv"

LOG_TAG="${SCRIPT_NAME}"

# ------------------------------ output ------------------------------
if [[ -t 1 ]]; then
  C_GREEN='\033[0;32m'
  C_YELLOW='\033[1;33m'
  C_RED='\033[0;31m'
  C_BLUE='\033[1;34m'
  C_NC='\033[0m'
else
  C_GREEN=''
  C_YELLOW=''
  C_RED=''
  C_BLUE=''
  C_NC=''
fi

log()  { printf '[%s] %b%s%b\n' "$LOG_TAG" "$C_GREEN" "$*" "$C_NC"; }
info() { printf '[%s] %s\n' "$LOG_TAG" "$*"; }
warn() { printf '[%s] %bWARNING:%b %s\n' "$LOG_TAG" "$C_YELLOW" "$C_NC" "$*" >&2; }
err()  { printf '[%s] %bERROR:%b %s\n' "$LOG_TAG" "$C_RED" "$C_NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "此操作需要 root：sudo $0 $*"
}

# ------------------------------ platform ------------------------------
OS_ID="unknown"
OS_PRETTY="unknown"
HAS_SYSTEMD=0

load_os_info() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
  fi

  if have systemctl && [[ -d /run/systemd/system ]]; then
    HAS_SYSTEMD=1
  else
    HAS_SYSTEMD=0
  fi
}

check_supported_os() {
  load_os_info
  case "$OS_ID" in
    ubuntu|debian) ;;
    *) warn "当前系统为 ${OS_PRETTY}；本工具主要针对 Ubuntu/Debian，继续运行前请确认兼容性。" ;;
  esac
}

ensure_packages() {
  need_root "$@"
  have apt-get || die "未找到 apt-get；自动安装依赖仅支持 Debian/Ubuntu。"

  local pkgs=(iproute2 procps ethtool kmod)
  local missing=()
  local p

  for p in "${pkgs[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^Status: install ok installed$'; then
      missing+=("$p")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  log "安装缺失依赖：${missing[*]}"

  local attempt
  for attempt in 1 2 3; do
    if apt-get update && apt-get install -y --no-install-recommends "${missing[@]}"; then
      return 0
    fi
    warn "APT 失败（${attempt}/3）"
    sleep $((attempt * 2))
  done

  die "依赖安装失败。"
}

# ------------------------------ interface ------------------------------
is_bad_iface() {
  local d="$1"
  [[ "$d" == lo || "$d" == docker* || "$d" == veth* || "$d" == br-* || "$d" == virbr* ]]
}

detect_iface() {
  local dev=""

  dev="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [[ -n "$dev" && -d "/sys/class/net/$dev" ]]; then
    printf '%s\n' "$dev"
    return 0
  fi

  dev="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [[ -n "$dev" && -d "/sys/class/net/$dev" ]]; then
    printf '%s\n' "$dev"
    return 0
  fi

  local path
  for path in /sys/class/net/*; do
    [[ -e "$path" ]] || continue
    dev="$(basename "$path")"
    is_bad_iface "$dev" && continue
    printf '%s\n' "$dev"
    return 0
  done

  return 1
}

iface_driver() {
  local iface="$1"
  if have ethtool; then
    ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver:/{print $2; exit}'
  fi
}

count_queues() {
  local iface="$1" kind="$2"
  local files=(/sys/class/net/"$iface"/queues/"$kind"-*)
  printf '%s\n' "${#files[@]}"
}

# ------------------------------ BBR ------------------------------
SUPPORT_BBR=0
SUPPORT_BBR2=0
SELECTED_CC=""

refresh_bbr_support() {
  SUPPORT_BBR=0
  SUPPORT_BBR2=0
  SELECTED_CC=""

  local avail
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"

  [[ " $avail " == *" bbr "* ]] && SUPPORT_BBR=1
  [[ " $avail " == *" bbr2 "* ]] && SUPPORT_BBR2=1

  if (( SUPPORT_BBR2 == 1 )); then
    SELECTED_CC="bbr2"
  elif (( SUPPORT_BBR == 1 )); then
    SELECTED_CC="bbr"
  fi
}

load_bbr_modules() {
  if have modprobe; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe tcp_bbr2 >/dev/null 2>&1 || true
  fi
}

require_bbr() {
  load_bbr_modules
  refresh_bbr_support
  [[ -n "$SELECTED_CC" ]] || die "当前内核未提供 BBR/BBR2。apply/repair 已中止，未写入任何持久化配置。"
}

# ------------------------------ adaptive profile ------------------------------
MEM_KB=0
TCP_MAX=0
NETDEV_BACKLOG=0
SOMAXCONN=0
NOFILE_LIMIT=0
PROFILE_NAME=""

calculate_profile() {
  MEM_KB="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  [[ "$MEM_KB" =~ ^[0-9]+$ ]] || MEM_KB=0

  if (( MEM_KB < 1048576 )); then
    PROFILE_NAME="tiny"
    TCP_MAX=$((16 * 1024 * 1024))
    NETDEV_BACKLOG=8192
    SOMAXCONN=8192
  elif (( MEM_KB < 2097152 )); then
    PROFILE_NAME="small"
    TCP_MAX=$((32 * 1024 * 1024))
    NETDEV_BACKLOG=16384
    SOMAXCONN=16384
  elif (( MEM_KB < 8388608 )); then
    PROFILE_NAME="standard"
    TCP_MAX=$((64 * 1024 * 1024))
    NETDEV_BACKLOG=32768
    SOMAXCONN=32768
  else
    PROFILE_NAME="large"
    TCP_MAX=$((128 * 1024 * 1024))
    NETDEV_BACKLOG=65536
    SOMAXCONN=65535
  fi

  local nr_open
  nr_open="$(sysctl -n fs.nr_open 2>/dev/null || echo 1048576)"
  [[ "$nr_open" =~ ^[0-9]+$ ]] || nr_open=1048576

  if (( nr_open < 1048576 )); then
    NOFILE_LIMIT="$nr_open"
  else
    NOFILE_LIMIT=1048576
  fi
}

# ------------------------------ baseline backup ------------------------------
managed_sysctl_keys() {
  printf '%s\n' \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    net.core.rmem_max \
    net.core.wmem_max \
    net.core.netdev_max_backlog \
    net.core.somaxconn \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.tcp_moderate_rcvbuf \
    net.ipv4.tcp_window_scaling \
    net.ipv4.tcp_sack \
    net.ipv4.tcp_timestamps \
    net.ipv4.tcp_fastopen \
    net.ipv4.tcp_mtu_probing \
    net.ipv4.tcp_syncookies \
    net.ipv4.tcp_slow_start_after_idle
}

managed_files() {
  printf '%s\n' \
    "$SYSCTL_FILE" \
    "$LIMITS_FILE" \
    "$SYSTEMD_DROPIN" \
    "$RPS_SERVICE" \
    "$RPS_SCRIPT" \
    "$LEGACY_ETHTOOL_SERVICE"
}

backup_runtime_sysctl_once() {
  [[ -e "$BASELINE_SYSCTL_STATE" ]] && return 0

  : >"${BASELINE_SYSCTL_STATE}.tmp"
  local key value
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    value="$(sysctl -n "$key" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      printf '%s\t%s\n' "$key" "$value" >>"${BASELINE_SYSCTL_STATE}.tmp"
    fi
  done < <(managed_sysctl_keys)
  mv -f "${BASELINE_SYSCTL_STATE}.tmp" "$BASELINE_SYSCTL_STATE"
}

backup_service_state_once() {
  [[ -e "$BASELINE_SERVICE_STATE" ]] && return 0
  : >"${BASELINE_SERVICE_STATE}.tmp"

  if (( HAS_SYSTEMD == 1 )); then
    local svc enabled active
    for svc in "$(basename "$RPS_SERVICE")" "$(basename "$LEGACY_ETHTOOL_SERVICE")"; do
      enabled="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
      active="$(systemctl is-active "$svc" 2>/dev/null || true)"
      printf '%s\t%s\t%s\n' "$svc" "${enabled:-not-found}" "${active:-inactive}" >>"${BASELINE_SERVICE_STATE}.tmp"
    done
  fi

  mv -f "${BASELINE_SERVICE_STATE}.tmp" "$BASELINE_SERVICE_STATE"
}

backup_runtime_rps_xps_once() {
  [[ -e "$BASELINE_RPS_STATE" ]] && return 0

  : >"${BASELINE_RPS_STATE}.tmp"
  local f v
  for f in /sys/class/net/*/queues/rx-*/rps_cpus /sys/class/net/*/queues/tx-*/xps_cpus; do
    [[ -f "$f" ]] || continue
    v="$(cat "$f" 2>/dev/null || true)"
    printf '%s\t%s\n' "$f" "$v" >>"${BASELINE_RPS_STATE}.tmp"
  done
  mv -f "${BASELINE_RPS_STATE}.tmp" "$BASELINE_RPS_STATE"
}

backup_baseline_once() {
  [[ -e "$BASELINE_STATE" ]] && return 0

  mkdir -p "$BASELINE_DIR/rootfs"
  : >"${BASELINE_STATE}.tmp"

  local f backup_path
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -e "$f" || -L "$f" ]]; then
      printf 'present\t%s\n' "$f" >>"${BASELINE_STATE}.tmp"
      backup_path="${BASELINE_DIR}/rootfs${f}"
      mkdir -p "$(dirname "$backup_path")"
      cp -a "$f" "$backup_path"
    else
      printf 'absent\t%s\n' "$f" >>"${BASELINE_STATE}.tmp"
    fi
  done < <(managed_files)

  mv -f "${BASELINE_STATE}.tmp" "$BASELINE_STATE"
  backup_runtime_sysctl_once
  backup_runtime_rps_xps_once
  backup_service_state_once
  log "已保存 V2 基线：$BASELINE_DIR"
}

restore_baseline_files() {
  [[ -r "$BASELINE_STATE" ]] || die "没有找到 V2 baseline，无法执行真正的 rollback。"

  local state f src
  while IFS=$'\t' read -r state f; do
    [[ -n "${f:-}" ]] || continue
    case "$state" in
      present)
        src="${BASELINE_DIR}/rootfs${f}"
        [[ -e "$src" || -L "$src" ]] || { warn "baseline 缺少：$src"; continue; }
        mkdir -p "$(dirname "$f")"
        rm -rf "$f"
        cp -a "$src" "$f"
        ;;
      absent)
        rm -rf "$f"
        ;;
    esac
  done <"$BASELINE_STATE"
}

restore_runtime_rps_xps() {
  [[ -r "$BASELINE_RPS_STATE" ]] || return 0
  local f v
  while IFS=$'\t' read -r f v; do
    [[ -n "${f:-}" && -w "$f" ]] || continue
    printf '%s\n' "$v" >"$f" 2>/dev/null || true
  done <"$BASELINE_RPS_STATE"
}

restore_runtime_sysctl() {
  [[ -r "$BASELINE_SYSCTL_STATE" ]] || return 0
  local key value
  while IFS=$'\t' read -r key value; do
    [[ -n "${key:-}" ]] || continue
    sysctl -w "${key}=${value}" >/dev/null 2>&1 || warn "无法恢复 runtime sysctl：$key"
  done <"$BASELINE_SYSCTL_STATE"
}

restore_service_state() {
  (( HAS_SYSTEMD == 1 )) || return 0
  [[ -r "$BASELINE_SERVICE_STATE" ]] || return 0

  systemctl daemon-reload || true
  local svc enabled active
  while IFS=$'\t' read -r svc enabled active; do
    [[ -n "${svc:-}" ]] || continue
    case "$enabled" in
      enabled|enabled-runtime|linked|linked-runtime|alias)
        systemctl enable "$svc" >/dev/null 2>&1 || true
        ;;
      disabled)
        systemctl disable "$svc" >/dev/null 2>&1 || true
        ;;
    esac

    if [[ "$active" == "active" ]]; then
      systemctl start "$svc" >/dev/null 2>&1 || true
    else
      systemctl stop "$svc" >/dev/null 2>&1 || true
    fi
  done <"$BASELINE_SERVICE_STATE"
}

# ------------------------------ sysctl generation ------------------------------
sysctl_exists() {
  local key="$1"
  [[ -e "/proc/sys/${key//./\/}" ]]
}

emit_sysctl() {
  local key="$1" value="$2"
  sysctl_exists "$key" && printf '%s = %s\n' "$key" "$value"
}

triple_or() {
  local key="$1" fallback="$2" value
  value="$(sysctl -n "$key" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

write_sysctl() {
  calculate_profile
  refresh_bbr_support
  [[ -n "$SELECTED_CC" ]] || die "BBR support disappeared before sysctl generation."

  local current_rmem current_wmem rmin rdef _rmax wmin wdef _wmax
  current_rmem="$(triple_or net.ipv4.tcp_rmem '4096 131072 6291456')"
  current_wmem="$(triple_or net.ipv4.tcp_wmem '4096 16384 4194304')"
  read -r rmin rdef _rmax <<<"$current_rmem"
  read -r wmin wdef _wmax <<<"$current_wmem"

  local tmp
  tmp="$(mktemp)"
  {
    printf '# %s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf '# Generated profile: %s; MemTotal=%s KiB\n' "$PROFILE_NAME" "$MEM_KB"
    printf '# BBR + fq, adaptive buffers, conservative server-safe TCP settings.\n\n'

    emit_sysctl net.core.default_qdisc fq
    emit_sysctl net.ipv4.tcp_congestion_control "$SELECTED_CC"
    printf '\n'

    emit_sysctl net.core.rmem_max "$TCP_MAX"
    emit_sysctl net.core.wmem_max "$TCP_MAX"
    emit_sysctl net.core.netdev_max_backlog "$NETDEV_BACKLOG"
    emit_sysctl net.core.somaxconn "$SOMAXCONN"
    printf '\n'

    emit_sysctl net.ipv4.tcp_rmem "$rmin $rdef $TCP_MAX"
    emit_sysctl net.ipv4.tcp_wmem "$wmin $wdef $TCP_MAX"
    emit_sysctl net.ipv4.tcp_moderate_rcvbuf 1
    emit_sysctl net.ipv4.tcp_window_scaling 1
    emit_sysctl net.ipv4.tcp_sack 1
    emit_sysctl net.ipv4.tcp_timestamps 1
    printf '\n'

    emit_sysctl net.ipv4.tcp_fastopen 3
    emit_sysctl net.ipv4.tcp_mtu_probing 1
    emit_sysctl net.ipv4.tcp_syncookies 1
    emit_sysctl net.ipv4.tcp_slow_start_after_idle 0
  } >"$tmp"

  install -m 0644 "$tmp" "$SYSCTL_FILE"
  rm -f "$tmp"

  log "已写入 sysctl：$SYSCTL_FILE（profile=$PROFILE_NAME, TCP_MAX=$TCP_MAX）"

  if ! sysctl -p "$SYSCTL_FILE"; then
    die "应用本工具 sysctl 失败。请检查上方具体键值错误。"
  fi
}

# ------------------------------ limits ------------------------------
write_limits() {
  calculate_profile

  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<LIMITS_EOF
# ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Session file-descriptor limit for high-connection workloads.
*    soft nofile ${NOFILE_LIMIT}
*    hard nofile ${NOFILE_LIMIT}
root soft nofile ${NOFILE_LIMIT}
root hard nofile ${NOFILE_LIMIT}
LIMITS_EOF
  install -m 0644 "$tmp" "$LIMITS_FILE"
  rm -f "$tmp"

  if (( HAS_SYSTEMD == 1 )); then
    mkdir -p "$(dirname "$SYSTEMD_DROPIN")"
    tmp="$(mktemp)"
    cat >"$tmp" <<SYSTEMD_LIMIT_EOF
# ${SCRIPT_NAME} v${SCRIPT_VERSION}
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}
SYSTEMD_LIMIT_EOF
    install -m 0644 "$tmp" "$SYSTEMD_DROPIN"
    rm -f "$tmp"
  else
    warn "未检测到 systemd；跳过 systemd manager NOFILE drop-in。"
  fi

  log "NOFILE 目标值：$NOFILE_LIMIT"
}

# ------------------------------ adaptive RPS/XPS runtime script ------------------------------
write_rps_script() {
  local tmp
  tmp="$(mktemp)"

  cat >"$tmp" <<'RPS_SCRIPT_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

is_bad_iface() {
  local d="$1"
  [[ "$d" == lo || "$d" == docker* || "$d" == veth* || "$d" == br-* || "$d" == virbr* ]]
}

detect_iface() {
  local dev=""
  dev="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [[ -n "$dev" && -d "/sys/class/net/$dev" ]]; then printf '%s\n' "$dev"; return 0; fi

  dev="$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [[ -n "$dev" && -d "/sys/class/net/$dev" ]]; then printf '%s\n' "$dev"; return 0; fi

  local path
  for path in /sys/class/net/*; do
    [[ -e "$path" ]] || continue
    dev="$(basename "$path")"
    is_bad_iface "$dev" && continue
    printf '%s\n' "$dev"
    return 0
  done
  return 1
}

expand_cpu_list() {
  local spec="$1" part start end i
  local -a parts
  IFS=',' read -r -a parts <<<"$spec"
  for part in "${parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      start="${part%-*}"
      end="${part#*-}"
      for ((i=start; i<=end; i++)); do printf '%s\n' "$i"; done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$part"
    fi
  done
}

online_cpus() {
  local spec
  spec="$(cat /sys/devices/system/cpu/online 2>/dev/null || true)"
  if [[ -n "$spec" ]]; then
    expand_cpu_list "$spec"
  else
    local n i
    n="$(nproc)"
    for ((i=0; i<n; i++)); do printf '%s\n' "$i"; done
  fi
}

cpumask_for_group() {
  local group="$1" groups="$2"
  local -a cpus=()
  mapfile -t cpus < <(online_cpus)

  local max_cpu=0 cpu
  for cpu in "${cpus[@]}"; do
    if (( cpu > max_cpu )); then max_cpu="$cpu"; fi
  done

  local words=$((max_cpu / 32 + 1))
  local -a vals=()
  local i word bit idx=0 hex out="" started=0
  for ((i=0; i<words; i++)); do vals[i]=0; done

  for cpu in "${cpus[@]}"; do
    if (( idx % groups == group )); then
      word=$((cpu / 32))
      bit=$((cpu % 32))
      vals[word]=$(( vals[word] | (1 << bit) ))
    fi
    idx=$((idx + 1))
  done

  for ((i=words-1; i>=0; i--)); do
    printf -v hex '%08x' "${vals[i]}"
    if (( started == 0 )); then
      if [[ "$hex" == "00000000" && i -gt 0 ]]; then continue; fi
      hex="${hex#0000000}"; hex="${hex#000000}"; hex="${hex#00000}"; hex="${hex#0000}"
      hex="${hex#000}"; hex="${hex#00}"; hex="${hex#0}"
      [[ -n "$hex" ]] || hex="0"
      out="$hex"
      started=1
    else
      out+=",$hex"
    fi
  done

  [[ -n "$out" ]] || out="0"
  printf '%s\n' "$out"
}

main() {
  local iface
  iface="$(detect_iface || true)"
  [[ -n "$iface" ]] || exit 0

  local -a cpus=() rxqs=() txqs=()
  mapfile -t cpus < <(online_cpus)
  rxqs=(/sys/class/net/"$iface"/queues/rx-*)
  txqs=(/sys/class/net/"$iface"/queues/tx-*)

  local ncpu="${#cpus[@]}" nrx="${#rxqs[@]}" ntx="${#txqs[@]}"
  (( ncpu > 1 )) || exit 0

  local i mask file

  # RX: if queues >= CPUs, RSS/multiqueue is usually sufficient: disable extra RPS.
  # Otherwise, assign a disjoint CPU group to each RX queue.
  if (( nrx > 0 )); then
    for ((i=0; i<nrx; i++)); do
      file="${rxqs[i]}/rps_cpus"
      [[ -w "$file" ]] || continue
      if (( nrx >= ncpu )); then
        printf '0\n' >"$file" || true
      else
        mask="$(cpumask_for_group "$i" "$nrx")"
        printf '%s\n' "$mask" >"$file" || true
      fi
    done
  fi

  # TX: XPS has no effect on a single TX queue. For multiple queues, split CPUs.
  if (( ntx > 0 )); then
    for ((i=0; i<ntx; i++)); do
      file="${txqs[i]}/xps_cpus"
      [[ -w "$file" ]] || continue
      if (( ntx <= 1 )); then
        printf '0\n' >"$file" || true
      else
        mask="$(cpumask_for_group "$i" "$ntx")"
        printf '%s\n' "$mask" >"$file" || true
      fi
    done
  fi
}

main "$@"
RPS_SCRIPT_EOF

  install -m 0755 "$tmp" "$RPS_SCRIPT"
  rm -f "$tmp"
  log "已生成自适应 RPS/XPS 脚本：$RPS_SCRIPT"
}

write_rps_service() {
  if (( HAS_SYSTEMD == 0 )); then
    warn "未检测到 systemd；RPS/XPS 只应用当前运行时，不创建开机服务。"
    "$RPS_SCRIPT" || true
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<RPS_SERVICE_EOF
[Unit]
Description=Adaptive RPS/XPS for ${SCRIPT_NAME}
After=network.target

[Service]
Type=oneshot
ExecStart=${RPS_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
RPS_SERVICE_EOF
  install -m 0644 "$tmp" "$RPS_SERVICE"
  rm -f "$tmp"

  systemctl daemon-reload
  systemctl enable "$(basename "$RPS_SERVICE")" >/dev/null 2>&1 || true
  systemctl restart "$(basename "$RPS_SERVICE")" || "$RPS_SCRIPT" || true
  log "已启用自适应 RPS/XPS：$(basename "$RPS_SERVICE")"
}

remove_legacy_offload_service() {
  if [[ ! -e "$LEGACY_ETHTOOL_SERVICE" ]]; then
    return 0
  fi

  if (( HAS_SYSTEMD == 1 )); then
    systemctl disable --now "$(basename "$LEGACY_ETHTOOL_SERVICE")" >/dev/null 2>&1 || true
  fi
  rm -f "$LEGACY_ETHTOOL_SERVICE"
  warn "已移除旧版自动关闭 GRO/GSO/TSO 的持久化 service。当前运行时 offload 状态未被强制修改；重启后由驱动恢复默认。"
}

# ------------------------------ checks ------------------------------
PASS_CNT=0
WARN_CNT=0
FAIL_CNT=0

pass() { printf '%b✔%b %s\n' "$C_GREEN" "$C_NC" "$*"; PASS_CNT=$((PASS_CNT + 1)); }
softwarn() { printf '%b⚠%b %s\n' "$C_YELLOW" "$C_NC" "$*"; WARN_CNT=$((WARN_CNT + 1)); }
fail() { printf '%b✘%b %s\n' "$C_RED" "$C_NC" "$*"; FAIL_CNT=$((FAIL_CNT + 1)); }

check_eq() {
  local key="$1" expected="$2" got
  got="$(sysctl -n "$key" 2>/dev/null || true)"
  if [[ "$got" == "$expected" ]]; then
    pass "$key = $expected"
  else
    fail "$key 期望=$expected，实际=${got:-<empty>}"
  fi
}

check_ge() {
  local key="$1" min="$2" got
  got="$(sysctl -n "$key" 2>/dev/null || echo 0)"
  if [[ "$got" =~ ^[0-9]+$ ]] && (( got >= min )); then
    pass "$key >= $min（当前 $got）"
  else
    fail "$key 应 >= $min（当前 ${got:-<empty>}）"
  fi
}

selftest_all() {
  check_supported_os
  refresh_bbr_support
  calculate_profile

  PASS_CNT=0
  WARN_CNT=0
  FAIL_CNT=0

  echo "===== ${SCRIPT_NAME} v${SCRIPT_VERSION} selftest ====="

  [[ -f "$SYSCTL_FILE" ]] && pass "存在 $SYSCTL_FILE" || fail "缺少 $SYSCTL_FILE"
  [[ -f "$LIMITS_FILE" ]] && pass "存在 $LIMITS_FILE" || fail "缺少 $LIMITS_FILE"
  [[ -f "$RPS_SCRIPT" ]] && pass "存在 $RPS_SCRIPT" || fail "缺少 $RPS_SCRIPT"

  if [[ -n "$SELECTED_CC" ]]; then
    check_eq net.ipv4.tcp_congestion_control "$SELECTED_CC"
  else
    fail "内核未提供 BBR/BBR2"
  fi

  check_eq net.core.default_qdisc fq
  check_ge net.core.rmem_max "$TCP_MAX"
  check_ge net.core.wmem_max "$TCP_MAX"
  check_ge net.core.netdev_max_backlog "$NETDEV_BACKLOG"
  check_ge net.core.somaxconn "$SOMAXCONN"
  check_eq net.ipv4.tcp_moderate_rcvbuf 1
  check_eq net.ipv4.tcp_window_scaling 1

  if (( HAS_SYSTEMD == 1 )); then
    if systemctl is-enabled "$(basename "$RPS_SERVICE")" >/dev/null 2>&1; then
      pass "RPS/XPS service 已启用"
    else
      fail "RPS/XPS service 未启用"
    fi
  else
    softwarn "非 systemd 环境，无法验证持久化 RPS/XPS service"
  fi

  local iface
  iface="$(detect_iface || true)"
  if [[ -n "$iface" ]]; then
    pass "默认网络接口：$iface"
  else
    fail "无法找到默认网络接口"
  fi

  echo "===== PASS=$PASS_CNT WARN=$WARN_CNT FAIL=$FAIL_CNT ====="
  (( FAIL_CNT == 0 ))
}

# ------------------------------ status/diagnose ------------------------------
show_qdisc() {
  local iface="$1"
  have tc || return 0
  tc qdisc show dev "$iface" 2>/dev/null || true
}

show_rps_xps() {
  local iface="$1" f
  echo "RPS/XPS:"
  for f in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
    [[ -f "$f" ]] || continue
    printf '  %s=%s\n' "$(basename "$(dirname "$f")")/rps_cpus" "$(cat "$f" 2>/dev/null || true)"
  done
  for f in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
    [[ -f "$f" ]] || continue
    printf '  %s=%s\n' "$(basename "$(dirname "$f")")/xps_cpus" "$(cat "$f" 2>/dev/null || true)"
  done
}

status_all() {
  check_supported_os
  refresh_bbr_support
  calculate_profile

  local iface driver rxq txq
  iface="$(detect_iface || true)"
  driver=""
  rxq=0
  txq=0
  if [[ -n "$iface" ]]; then
    driver="$(iface_driver "$iface" || true)"
    rxq="$(count_queues "$iface" rx)"
    txq="$(count_queues "$iface" tx)"
  fi

  echo "===== ${SCRIPT_NAME} v${SCRIPT_VERSION} status ====="
  echo "OS:                $OS_PRETTY"
  echo "Kernel:            $(uname -r)"
  echo "Virtualization:    $(systemd-detect-virt 2>/dev/null || echo unknown)"
  echo "CPU:               $(nproc)"
  echo "Memory profile:    $PROFILE_NAME"
  echo "TCP max target:    $TCP_MAX"
  echo "Default interface: ${iface:-<none>}"
  echo "Driver:            ${driver:-unknown}"
  echo "RX/TX queues:      $rxq/$txq"
  echo "BBR available:     bbr=$SUPPORT_BBR bbr2=$SUPPORT_BBR2"
  echo "Selected CC:       ${SELECTED_CC:-<none>}"
  echo

  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
  sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true
  sysctl net.core.default_qdisc 2>/dev/null || true
  sysctl net.core.rmem_max net.core.wmem_max 2>/dev/null || true
  sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem 2>/dev/null || true
  sysctl net.core.netdev_max_backlog net.core.somaxconn 2>/dev/null || true
  sysctl net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling 2>/dev/null || true

  if [[ -n "$iface" ]]; then
    echo
    echo "===== qdisc: $iface ====="
    show_qdisc "$iface"
    echo
    show_rps_xps "$iface"
  fi

  echo
  echo "Current shell NOFILE: $(ulimit -n 2>/dev/null || echo unknown)"
  echo "Baseline: $([[ -r "$BASELINE_STATE" ]] && echo present || echo absent)"
}

diagnose_all() {
  local aggressive="${1:-0}"
  check_supported_os
  refresh_bbr_support
  calculate_profile

  local iface driver rxq txq cc qdisc ncpu
  iface="$(detect_iface || true)"
  ncpu="$(nproc)"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  driver=""
  rxq=0
  txq=0

  if [[ -n "$iface" ]]; then
    driver="$(iface_driver "$iface" || true)"
    rxq="$(count_queues "$iface" rx)"
    txq="$(count_queues "$iface" tx)"
  fi

  echo "===== ${SCRIPT_NAME} v${SCRIPT_VERSION} diagnose (READ-ONLY) ====="
  echo "OS: $OS_PRETTY"
  echo "Kernel: $(uname -r)"
  echo "CPU: $ncpu"
  echo "Memory profile: $PROFILE_NAME"
  echo "Interface: ${iface:-<none>} driver=${driver:-unknown} queues RX=$rxq TX=$txq"
  echo "Congestion control: ${cc:-unknown}"
  echo "Default qdisc: ${qdisc:-unknown}"
  echo

  if [[ "$cc" == bbr || "$cc" == bbr2 ]]; then
    pass "正在使用 $cc"
  elif [[ -n "$SELECTED_CC" ]]; then
    softwarn "BBR 可用但当前使用 ${cc:-unknown}；apply 会选择 $SELECTED_CC"
  else
    fail "当前内核未提供 BBR/BBR2"
  fi

  if [[ "$qdisc" == fq ]]; then
    pass "default_qdisc=fq"
  else
    softwarn "default_qdisc=${qdisc:-unknown}；BBR profile 推荐 fq"
  fi

  local moderate scaling rmax wmax
  moderate="$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null || true)"
  scaling="$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null || true)"
  rmax="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  wmax="$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)"

  [[ "$moderate" == 1 ]] && pass "TCP receive autotuning 已启用" || softwarn "tcp_moderate_rcvbuf=$moderate"
  [[ "$scaling" == 1 ]] && pass "TCP window scaling 已启用" || fail "tcp_window_scaling=$scaling"

  if [[ "$rmax" =~ ^[0-9]+$ && "$wmax" =~ ^[0-9]+$ ]] && (( rmax >= TCP_MAX && wmax >= TCP_MAX )); then
    pass "socket buffer 上限满足当前内存 profile"
  else
    softwarn "socket buffer 上限低于本工具 profile（target=$TCP_MAX）"
  fi

  if [[ -n "$iface" ]]; then
    echo
    echo "----- Actual qdisc -----"
    show_qdisc "$iface"

    echo
    show_rps_xps "$iface"

    if (( ncpu <= 1 )); then
      pass "单 vCPU：无需 RPS/XPS"
    elif (( rxq >= ncpu )); then
      info "RPS policy: RX queues($rxq) >= CPUs($ncpu)，RSS/multiqueue 通常已足够，V2 会关闭额外 RPS。"
    elif (( rxq > 0 )); then
      info "RPS policy: RX queues($rxq) < CPUs($ncpu)，V2 会按 queue 分组 CPU。"
    fi

    if (( txq <= 1 )); then
      info "XPS policy: 单 TX queue，无 queue 选择空间，V2 不启用 XPS。"
    else
      info "XPS policy: 多 TX queue，V2 会按 queue 分组 CPU。"
    fi

    echo
    echo "----- NIC counters -----"
    local rxerr txerr rxdrop txdrop
    rxerr="$(cat "/sys/class/net/$iface/statistics/rx_errors" 2>/dev/null || echo 0)"
    txerr="$(cat "/sys/class/net/$iface/statistics/tx_errors" 2>/dev/null || echo 0)"
    rxdrop="$(cat "/sys/class/net/$iface/statistics/rx_dropped" 2>/dev/null || echo 0)"
    txdrop="$(cat "/sys/class/net/$iface/statistics/tx_dropped" 2>/dev/null || echo 0)"
    echo "RX errors=$rxerr dropped=$rxdrop"
    echo "TX errors=$txerr dropped=$txdrop"
  fi

  if (( aggressive == 1 )) && [[ -n "$iface" ]]; then
    echo
    echo "===== aggressive diagnostics (still READ-ONLY) ====="
    if have ethtool; then
      echo "----- Offload state -----"
      ethtool -k "$iface" 2>/dev/null | grep -E '^(rx-checksumming|tx-checksumming|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload):' || true
    else
      softwarn "ethtool 未安装，无法查看 offload。"
    fi

    echo
    echo "----- softnet_stat (raw; per CPU) -----"
    if [[ -r /proc/net/softnet_stat ]]; then
      cat /proc/net/softnet_stat
    fi

    echo
    info "aggressive 模式不会自动关闭 GRO/GSO/TSO。offload 是否应调整必须用真实远端流量做 A/B test。"
  fi

  echo
  echo "诊断完成：未修改任何 sysctl、service、qdisc 或 NIC offload。"
}

# ------------------------------ apply/repair ------------------------------
apply_all() {
  need_root "apply"
  check_supported_os
  ensure_packages
  load_os_info

  # Hard preflight: do not create baseline or alter anything if BBR is unavailable.
  require_bbr
  calculate_profile

  local iface
  iface="$(detect_iface || true)"
  [[ -n "$iface" ]] || die "无法检测默认网络接口。"

  log "目标系统：$OS_PRETTY"
  log "内核：$(uname -r)"
  log "默认接口：$iface"
  log "选择拥塞控制：$SELECTED_CC"
  log "自适应 profile：$PROFILE_NAME"

  mkdir -p "$BACKUP_DIR"
  backup_baseline_once

  # Remove legacy v1 behavior that persisted GRO/GSO/TSO=off.
  remove_legacy_offload_service

  write_sysctl
  write_limits
  write_rps_script
  write_rps_service

  if (( HAS_SYSTEMD == 1 )); then
    systemctl daemon-reload
  fi

  echo
  if selftest_all; then
    log "apply 完成，自检通过。"
  else
    warn "apply 已完成，但 selftest 存在失败项；请根据上方结果检查。"
  fi

  echo
  info "建议重启一次，使 systemd manager 默认 NOFILE 以及驱动默认 offload 状态完整重新继承。"
}

repair_all() {
  need_root "repair"
  log "repair 将重新生成并应用 V2 管理的配置，不会覆盖第一次 V2 apply 保存的 baseline。"
  apply_all
}

# ------------------------------ rollback/purge ------------------------------
rollback_all() {
  need_root "rollback"
  load_os_info
  [[ -r "$BASELINE_STATE" ]] || die "没有 V2 baseline。为了避免伪回滚，本工具拒绝仅删除配置。"

  warn "正在恢复第一次 V2 apply 前保存的 baseline。"

  if (( HAS_SYSTEMD == 1 )); then
    systemctl disable --now "$(basename "$RPS_SERVICE")" >/dev/null 2>&1 || true
    systemctl disable --now "$(basename "$LEGACY_ETHTOOL_SERVICE")" >/dev/null 2>&1 || true
  fi

  restore_baseline_files
  restore_runtime_sysctl
  restore_runtime_rps_xps
  restore_service_state

  log "baseline 文件、runtime sysctl、RPS/XPS 与 systemd service 状态已恢复。"
  info "建议重启一次，确保 systemd manager limits 与 NIC runtime 状态完全回到 baseline 环境。"
}

purge_all() {
  need_root "purge"
  rollback_all
  rm -rf "$BACKUP_DIR"
  log "已删除备份目录：$BACKUP_DIR"
  info "主脚本本身未自动删除；如需删除：rm -f /usr/local/sbin/${SCRIPT_NAME}.sh"
}

# ------------------------------ usage ------------------------------
usage() {
  cat <<USAGE_EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Usage:
  $0 apply
  $0 repair
  $0 status
  $0 selftest
  $0 diagnose
  $0 diagnose aggressive
  $0 "diagnose aggressive"
  $0 rollback
  $0 purge

Commands:
  apply                 自适应应用网络优化。BBR/BBR2 是硬要求；无 BBR 时零修改退出。
  repair                重新生成/应用 V2 管理的配置，不覆盖第一次 V2 baseline。
  status                只读：显示当前核心状态。
  selftest              只读：验证 V2 目标是否真正生效。
  diagnose              只读：常规诊断，不自动修复。
  diagnose aggressive   只读：增加 offload/softnet 等深度信息；仍不会关闭 GRO/GSO/TSO。
  rollback              真正恢复第一次 V2 apply 前的 baseline，而不是简单删除文件。
  purge                 rollback 后删除 V2 baseline/backup。

Design:
  - 主要支持 Ubuntu/Debian。
  - apply 选择 bbr2（若内核提供），否则 bbr；没有 BBR 就中止。
  - default qdisc 使用 fq。
  - TCP buffer/backlog 根据 RAM 自适应，不再所有 VPS 固定 128 MiB/250000。
  - 不修改 tcp_tw_reuse、route.gc_timeout、neighbor GC 阈值、全局 nproc。
  - RPS/XPS 根据 CPU 与 RX/TX queue 数量自适应。
  - 不会基于 loopback iperf 猜测 NIC offload，更不会自动关闭 GRO/GSO/TSO。
USAGE_EOF
}

# ------------------------------ main ------------------------------
main() {
  load_os_info

  case "${1:-}" in
    apply)
      apply_all
      ;;
    repair)
      repair_all
      ;;
    status)
      status_all
      ;;
    selftest)
      selftest_all
      ;;
    diagnose)
      if [[ "${2:-}" == "aggressive" ]]; then
        diagnose_all 1
      else
        diagnose_all 0
      fi
      ;;
    "diagnose aggressive")
      diagnose_all 1
      ;;
    rollback)
      rollback_all
      ;;
    purge)
      purge_all
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
