#!/usr/bin/env bash
#
# tcp-optimize-tool :: TCP / VPS Network Diagnostic Tool
#
# Designed for:
#   - Ubuntu
#   - Debian
#   - KVM / VMware / Hyper-V / Xen / LXC / OpenVZ VPS
#
# Usage:
#   sudo ./tcp-diagnose.sh
#   sudo ./tcp-diagnose.sh --speed
#
# This script is READ-ONLY.
# It does NOT modify sysctl, qdisc, NIC offload, systemd, or limits.

set -u

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[1;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

score=0
max_score=100

RUN_SPEED_TEST=0

for arg in "$@"; do
    case "$arg" in
        --speed)
            RUN_SPEED_TEST=1
            ;;
        -h|--help)
            cat <<'EOF'
Usage:
  tcp-diagnose.sh
  tcp-diagnose.sh --speed

Options:
  --speed     Run optional external download test
EOF
            exit 0
            ;;
    esac
done


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

title() {
    echo -e "\n${BLUE}${BOLD}============================================================${NC}"
    echo -e "${BLUE}${BOLD}$1${NC}"
    echo -e "${BLUE}${BOLD}============================================================${NC}"
}

section() {
    echo -e "\n${YELLOW}${BOLD}▶ $1${NC}"
}

ok() {
    echo -e "  ${GREEN}✔${NC} $*"
}

warn() {
    echo -e "  ${YELLOW}⚠${NC} $*"
}

bad() {
    echo -e "  ${RED}✘${NC} $*"
}

info() {
    echo -e "  ${CYAN}•${NC} $*"
}

have() {
    command -v "$1" >/dev/null 2>&1
}

sysctl_get() {
    sysctl -n "$1" 2>/dev/null || true
}

human_bytes() {
    local bytes="${1:-0}"

    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "$bytes"
        return
    fi

    if (( bytes >= 1073741824 )); then
        awk -v b="$bytes" 'BEGIN {printf "%.2f GiB", b/1073741824}'
    elif (( bytes >= 1048576 )); then
        awk -v b="$bytes" 'BEGIN {printf "%.2f MiB", b/1048576}'
    elif (( bytes >= 1024 )); then
        awk -v b="$bytes" 'BEGIN {printf "%.2f KiB", b/1024}'
    else
        echo "${bytes} B"
    fi
}


# ------------------------------------------------------------
# System information
# ------------------------------------------------------------

check_system() {
    section "系统环境"

    local os="Unknown"
    local kernel
    local arch
    local virt="Unknown"
    local memory="Unknown"

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os="${PRETTY_NAME:-${ID:-Unknown}}"
    fi

    kernel="$(uname -r)"
    arch="$(uname -m)"

    if have systemd-detect-virt; then
        virt="$(systemd-detect-virt 2>/dev/null || true)"
        [[ "$virt" == "none" || -z "$virt" ]] && virt="Bare metal / unknown"
    fi

    if have free; then
        memory="$(free -h | awk '/^Mem:/ {print $2}')"
    fi

    info "OS:              $os"
    info "Kernel:          $kernel"
    info "Architecture:    $arch"
    info "Virtualization:  $virt"
    info "Memory:          $memory"

    case "${ID:-}" in
        ubuntu|debian)
            ok "属于主要支持的平台"
            ;;
        *)
            warn "当前发行版不是 Debian/Ubuntu，结果仅供参考"
            ;;
    esac
}


# ------------------------------------------------------------
# Interface / route detection
# ------------------------------------------------------------

get_default_interface() {
    ip route show default 2>/dev/null \
        | awk '/default/ {print $5; exit}'
}

check_interface() {
    section "默认路由与网卡"

    DEFAULT_IFACE="$(get_default_interface)"

    if [[ -z "${DEFAULT_IFACE:-}" ]]; then
        bad "没有找到 IPv4 默认路由"
        return
    fi

    score=$((score + 5))

    local mtu
    local state
    local queues

    mtu="$(cat "/sys/class/net/$DEFAULT_IFACE/mtu" 2>/dev/null || echo unknown)"
    state="$(cat "/sys/class/net/$DEFAULT_IFACE/operstate" 2>/dev/null || echo unknown)"

    queues="$(
        find "/sys/class/net/$DEFAULT_IFACE/queues/" \
            -maxdepth 1 \
            -type d \
            -name 'rx-*' \
            2>/dev/null |
            wc -l
    )"

    info "Interface:       $DEFAULT_IFACE"
    info "State:           $state"
    info "MTU:             $mtu"
    info "RX queues:       $queues"

    ip route show default 2>/dev/null | sed 's/^/    /'

    if [[ "$state" == "up" || "$state" == "unknown" ]]; then
        ok "默认接口工作正常"
    else
        warn "默认接口状态为 $state"
    fi
}


# ------------------------------------------------------------
# Congestion control
# ------------------------------------------------------------

check_congestion_control() {
    section "TCP 拥塞控制算法"

    local current
    local available

    current="$(sysctl_get net.ipv4.tcp_congestion_control)"
    available="$(sysctl_get net.ipv4.tcp_available_congestion_control)"

    info "Current:         ${current:-unknown}"
    info "Available:       ${available:-unknown}"

    case "$current" in
        bbr|bbr2)
            ok "当前正在使用 $current"
            score=$((score + 20))
            ;;
        cubic)
            warn "当前使用 CUBIC；配置正常，但不是本工具推荐的 BBR profile"
            score=$((score + 12))
            ;;
        "")
            bad "无法读取 congestion control"
            ;;
        *)
            warn "当前使用 $current"
            score=$((score + 8))
            ;;
    esac

    if [[ " $available " == *" bbr "* ]] ||
       [[ " $available " == *" bbr2 "* ]]; then

        ok "内核提供 BBR 拥塞控制"
        score=$((score + 5))

    elif [[ "$current" == "bbr" || "$current" == "bbr2" ]]; then

        ok "BBR 当前正在运行"
        score=$((score + 5))

    else
        warn "BBR 没有出现在 available congestion control 中"
    fi

    if have modinfo; then
        if modinfo tcp_bbr >/dev/null 2>&1; then
            info "tcp_bbr kernel module: available"
        fi
    fi
}


# ------------------------------------------------------------
# qdisc
# ------------------------------------------------------------

check_qdisc() {
    section "Queue Discipline"

    local default_qdisc
    local iface="${DEFAULT_IFACE:-}"
    local tc_output=""
    local effective=""

    default_qdisc="$(sysctl_get net.core.default_qdisc)"

    info "net.core.default_qdisc: ${default_qdisc:-unknown}"

    if [[ -n "$iface" ]] && have tc; then
        echo
        info "实际 $iface qdisc："

        tc_output="$(tc qdisc show dev "$iface" 2>/dev/null || true)"

        if [[ -n "$tc_output" ]]; then
            echo "$tc_output" | sed 's/^/    /'
        fi

        if echo "$tc_output" | grep -qw fq; then
            effective="fq"
        elif echo "$tc_output" | grep -qw fq_codel; then
            effective="fq_codel"
        elif echo "$tc_output" | grep -qw cake; then
            effective="cake"
        elif echo "$tc_output" | grep -qw mq; then
            effective="mq"
        fi
    fi

    case "$effective" in
        fq)
            ok "实际接口使用 fq"
            score=$((score + 15))
            ;;
        fq_codel)
            ok "实际接口使用 fq_codel"
            score=$((score + 12))
            ;;
        cake)
            ok "实际接口使用 CAKE"
            score=$((score + 12))
            ;;
        mq)
            warn "根 qdisc 为 mq；应继续关注各 TX queue 的 leaf qdisc"
            score=$((score + 10))
            ;;
        *)
            case "$default_qdisc" in
                fq)
                    ok "默认 qdisc 为 fq"
                    score=$((score + 13))
                    ;;
                fq_codel)
                    ok "默认 qdisc 为 fq_codel"
                    score=$((score + 11))
                    ;;
                *)
                    warn "没有检测到 fq/fq_codel"
                    score=$((score + 5))
                    ;;
            esac
            ;;
    esac
}


# ------------------------------------------------------------
# TCP auto tuning / protocol features
# ------------------------------------------------------------

check_tcp_features() {
    section "TCP 内核功能"

    local moderate
    local scaling
    local sack
    local timestamps
    local ecn

    moderate="$(sysctl_get net.ipv4.tcp_moderate_rcvbuf)"
    scaling="$(sysctl_get net.ipv4.tcp_window_scaling)"
    sack="$(sysctl_get net.ipv4.tcp_sack)"
    timestamps="$(sysctl_get net.ipv4.tcp_timestamps)"
    ecn="$(sysctl_get net.ipv4.tcp_ecn)"

    if [[ "$moderate" == "1" ]]; then
        ok "TCP receive buffer autotuning 已启用"
        score=$((score + 10))
    else
        bad "tcp_moderate_rcvbuf=$moderate"
    fi

    if [[ "$scaling" == "1" ]]; then
        ok "TCP Window Scaling 已启用"
        score=$((score + 10))
    else
        bad "TCP Window Scaling 未启用"
    fi

    if [[ "$sack" == "1" ]]; then
        ok "TCP SACK 已启用"
        score=$((score + 10))
    else
        warn "TCP SACK 未启用"
    fi

    info "TCP timestamps:  ${timestamps:-unknown}"
    info "TCP ECN:         ${ecn:-unknown}"
}


# ------------------------------------------------------------
# TCP buffers
# ------------------------------------------------------------

check_buffers() {
    section "TCP Buffer"

    local rmem
    local wmem

    local rmin=0
    local rdefault=0
    local rmax=0

    local wmin=0
    local wdefault=0
    local wmax=0

    rmem="$(sysctl_get net.ipv4.tcp_rmem)"
    wmem="$(sysctl_get net.ipv4.tcp_wmem)"

    read -r rmin rdefault rmax <<< "$rmem"
    read -r wmin wdefault wmax <<< "$wmem"

    info "tcp_rmem:"
    info "  min:      $(human_bytes "$rmin")"
    info "  default:  $(human_bytes "$rdefault")"
    info "  max:      $(human_bytes "$rmax")"

    echo

    info "tcp_wmem:"
    info "  min:      $(human_bytes "$wmin")"
    info "  default:  $(human_bytes "$wdefault")"
    info "  max:      $(human_bytes "$wmax")"

    echo

    #
    # 不再硬性要求 64 MiB。
    #
    # 这里只检查：
    #   1. 参数顺序合理
    #   2. 是否有足够的高 BDP 调优空间
    #

    if (( rmin <= rdefault &&
          rdefault <= rmax &&
          wmin <= wdefault &&
          wdefault <= wmax )); then

        ok "TCP buffer 参数顺序正常"

        if (( rmax >= 16777216 && wmax >= 16777216 )); then
            ok "TCP buffer 最大值具有较充足的高速/高 RTT 调优空间"
            score=$((score + 10))

        elif (( rmax >= 4194304 && wmax >= 4194304 )); then
            warn "TCP buffer 最大值中等"
            score=$((score + 7))

        else
            warn "TCP buffer 最大值偏小；高 BDP 链路可能受限"
            score=$((score + 4))
        fi
    else
        bad "TCP buffer min/default/max 顺序异常"
    fi
}


# ------------------------------------------------------------
# File descriptor limits
# ------------------------------------------------------------

check_limits() {
    section "文件描述符"

    local filemax
    local shell_nofile

    filemax="$(sysctl_get fs.file-max)"
    shell_nofile="$(ulimit -n 2>/dev/null || echo unknown)"

    info "fs.file-max:     ${filemax:-unknown}"
    info "Shell NOFILE:    $shell_nofile"

    if [[ "$shell_nofile" =~ ^[0-9]+$ ]]; then
        if (( shell_nofile >= 65535 )); then
            ok "当前 shell NOFILE 对绝大多数 VPS 服务已较充足"
            score=$((score + 5))
        elif (( shell_nofile >= 8192 )); then
            warn "当前 shell NOFILE 中等"
            score=$((score + 3))
        else
            warn "当前 shell NOFILE 较低"
        fi
    fi

    info "注意：systemd 服务可能拥有独立 LimitNOFILE"
}


# ------------------------------------------------------------
# NIC stats
# ------------------------------------------------------------

check_nic_health() {
    section "网卡错误 / 丢包"

    local iface="${DEFAULT_IFACE:-}"

    if [[ -z "$iface" ]]; then
        warn "无法检测默认接口"
        return
    fi

    local rx_errors
    local tx_errors
    local rx_dropped
    local tx_dropped

    rx_errors="$(cat "/sys/class/net/$iface/statistics/rx_errors" 2>/dev/null || echo 0)"
    tx_errors="$(cat "/sys/class/net/$iface/statistics/tx_errors" 2>/dev/null || echo 0)"
    rx_dropped="$(cat "/sys/class/net/$iface/statistics/rx_dropped" 2>/dev/null || echo 0)"
    tx_dropped="$(cat "/sys/class/net/$iface/statistics/tx_dropped" 2>/dev/null || echo 0)"

    info "RX errors:       $rx_errors"
    info "TX errors:       $tx_errors"
    info "RX dropped:      $rx_dropped"
    info "TX dropped:      $tx_dropped"

    if (( rx_errors == 0 && tx_errors == 0 )); then
        ok "未发现网卡 RX/TX error"
        score=$((score + 10))
    else
        warn "存在接口 error，需要进一步调查"
    fi

    if (( rx_dropped > 0 || tx_dropped > 0 )); then
        warn "发现 dropped packets；需要结合运行时间与总包数判断"
    fi
}


# ------------------------------------------------------------
# NIC offload
# ------------------------------------------------------------

check_offload() {
    section "NIC Offload"

    local iface="${DEFAULT_IFACE:-}"

    if [[ -z "$iface" ]]; then
        return
    fi

    if ! have ethtool; then
        warn "ethtool 未安装"
        return
    fi

    local data

    data="$(ethtool -k "$iface" 2>/dev/null || true)"

    if [[ -z "$data" ]]; then
        warn "当前虚拟网卡不支持读取 offload 状态"
        return
    fi

    echo "$data" |
        grep -E \
        'tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload' |
        sed 's/^/    /'

    info "这里只报告状态，不把 GRO/GSO/TSO 开关简单判定为好或坏"
}


# ------------------------------------------------------------
# RPS
# ------------------------------------------------------------

check_rps() {
    section "RPS / RX Queue"

    local iface="${DEFAULT_IFACE:-}"

    [[ -z "$iface" ]] && return

    local found=0
    local f

    for f in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
        [[ -e "$f" ]] || continue

        found=1

        printf "    %-12s %s\n" \
            "$(basename "$(dirname "$f")")" \
            "$(cat "$f" 2>/dev/null)"
    done

    if (( found == 0 )); then
        info "没有找到 RX queue RPS 配置"
    fi
}


# ------------------------------------------------------------
# Connectivity
# ------------------------------------------------------------

check_connectivity() {
    section "外部网络连接"

    if ! have curl; then
        warn "curl 未安装"
        return
    fi

    local result

    result="$(
        curl \
            -o /dev/null \
            -sS \
            --connect-timeout 5 \
            --max-time 15 \
            -w \
'HTTP=%{http_code}
RemoteIP=%{remote_ip}
DNS=%{time_namelookup}
TCP=%{time_connect}
TLS=%{time_appconnect}
TTFB=%{time_starttransfer}
Total=%{time_total}
' \
            https://www.cloudflare.com/ \
            2>/dev/null
    )"

    if [[ $? -eq 0 ]]; then
        echo "$result" | sed 's/^/    /'
        ok "HTTPS connectivity 正常"
    else
        warn "外部 HTTPS 测试失败"
        info "这本身不证明 TCP 配置存在问题"
    fi
}


# ------------------------------------------------------------
# Optional speed test
# ------------------------------------------------------------

check_speed() {
    (( RUN_SPEED_TEST == 1 )) || return

    section "可选下载测试"

    if ! have curl; then
        warn "curl 未安装"
        return
    fi

    local url="${SPEED_URL:-https://speed.cloudflare.com/__down?bytes=10000000}"

    info "测试大小约 10 MB"
    info "目标: $url"
    info "结果仅表示当前 VPS → 测试节点路径"

    local result

    result="$(
        curl \
            -o /dev/null \
            -sS \
            --connect-timeout 5 \
            --max-time 30 \
            -w \
'RemoteIP=%{remote_ip}
Connect=%{time_connect}
TTFB=%{time_starttransfer}
Downloaded=%{size_download}
Speed=%{speed_download}
Total=%{time_total}
' \
            "$url" \
            2>/dev/null
    )"

    if [[ $? -ne 0 ]]; then
        warn "下载测试失败"
        return
    fi

    echo "$result" | sed 's/^/    /'

    local speed

    speed="$(echo "$result" |
        awk -F= '/^Speed=/ {print int($2)}')"

    if [[ "$speed" =~ ^[0-9]+$ && "$speed" -gt 0 ]]; then

        local mbps

        mbps="$(
            awk -v b="$speed" \
                'BEGIN {printf "%.2f", b*8/1000000}'
        )"

        info "Approx download: ${mbps} Mbit/s"
    fi

    warn "不要使用单次测速结果评价 VPS 的真实带宽上限"
}


# ------------------------------------------------------------
# Score
# ------------------------------------------------------------

give_score() {
    section "配置健康评分"

    echo -e "  ${BOLD}${score} / ${max_score}${NC}"

    if (( score >= 90 )); then
        echo -e "  ${GREEN}A+  网络栈配置整体优秀${NC}"

    elif (( score >= 80 )); then
        echo -e "  ${GREEN}A   网络栈配置良好${NC}"

    elif (( score >= 65 )); then
        echo -e "  ${YELLOW}B   基本正常，存在可检查项目${NC}"

    elif (( score >= 50 )); then
        echo -e "  ${YELLOW}C   多项配置需要检查${NC}"

    else
        echo -e "  ${RED}D   建议检查 TCP/network 配置${NC}"
    fi

    echo
    info "这是配置健康评分，不是 VPS 带宽/线路质量评分。"
    info "真实性能还取决于带宽、RTT、丢包、CPU、虚拟化、路由和对端。"
}


# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {
    title "TCP / VPS Network Diagnostic Tool"

    check_system
    check_interface
    check_congestion_control
    check_qdisc
    check_tcp_features
    check_buffers
    check_limits
    check_nic_health
    check_offload
    check_rps
    check_connectivity
    check_speed

    give_score

    echo
    echo -e "${GREEN}✔ TCP 网络诊断完成。未修改任何系统参数。${NC}"
    echo
}

main
