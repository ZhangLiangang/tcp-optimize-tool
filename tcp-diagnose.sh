#!/bin/bash

green='\033[0;32m'
red='\033[0;31m'
yellow='\033[1;33m'
blue='\033[1;34m'
nc='\033[0m'

score=0

function print_title() {
    echo -e "\n${blue}🧪 TCP 性能体检工具（含评分） - By cosloc.net${nc}"
}

function check_param() {
    echo -e "\n${yellow}▶️ 系统 TCP 参数检查:${nc}"
    algo=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [[ $algo == "bbr" || $algo == "bbr2" ]]; then
        echo -e "  🚀 拥塞控制算法: ${green}$algo ✅${nc}"
        ((score+=20))
    else
        echo -e "  🚀 拥塞控制算法: ${red}$algo ❌${nc}"
    fi

    qdisc=$(sysctl -n net.core.default_qdisc)
    if [[ "$qdisc" == "fq" ]]; then
        echo -e "  📶 队列算法 fq: ${green}$qdisc ✅${nc}"
        ((score+=10))
    else
        echo -e "  📶 队列算法 fq: ${red}$qdisc ❌${nc}"
    fi

    rmem=$(sysctl -n net.ipv4.tcp_rmem | awk '{print $3}')
    if (( rmem >= 67108864 )); then
        echo -e "  📥 tcp_rmem: ${green}$rmem ✅${nc}"
        ((score+=10))
    else
        echo -e "  📥 tcp_rmem: ${yellow}$rmem ⚠️（建议 ≥ 67108864）${nc}"
    fi

    wmem=$(sysctl -n net.ipv4.tcp_wmem | awk '{print $3}')
    if (( wmem >= 67108864 )); then
        echo -e "  📤 tcp_wmem: ${green}$wmem ✅${nc}"
        ((score+=10))
    else
        echo -e "  📤 tcp_wmem: ${yellow}$wmem ⚠️（建议 ≥ 67108864）${nc}"
    fi
}

function check_limits() {
    echo -e "\n${yellow}▶️ 文件句柄限制:${nc}"
    max=$(sysctl -n fs.file-max)
    ulimit_n=$(ulimit -n)
    if [[ $max -ge 1048576 ]]; then
        echo -e "  🧠 fs.file-max: ${green}$max ✅${nc}"
        ((score+=10))
    else
        echo -e "  🧠 fs.file-max: ${red}$max ❌${nc}"
    fi

    if [[ $ulimit_n -ge 1048576 ]]; then
        echo -e "  🧠 ulimit -n: ${green}$ulimit_n ✅${nc}"
        ((score+=10))
    else
        echo -e "  🧠 ulimit -n: ${yellow}$ulimit_n ⚠️（建议 ≥ 1048576）${nc}"
    fi
}

function check_latency_speed() {
    echo -e "\n${yellow}▶️ 网络握手 RTT + 下载速度测试:${nc}"
    result=$(curl -o /dev/null -s -w "%{time_namelookup} %{time_connect} %{speed_download}" https://www.google.com)
    if [[ $? -eq 0 ]]; then
        set -- $result
        echo -e "  ⏱️  time_namelookup:  $1 s"
        echo -e "  ⏳  time_connect:     $2 s"
        echo -e "  🚀  download_speed:   $3 B/s"
        ((score+=10))
    else
        echo -e "  ❌ curl 测试失败，可能被墙"
    fi
}

function check_bandwidth() {
    echo -e "\n${yellow}▶️ 带宽测试 (iperf3 可选):${nc}"
    echo -e "  若你有一台客户端可以连接此 VPS，请运行："
    echo -e "    ${green}iperf3 -c <你的-VPS-IP> -t 30${nc}"
    echo -e "  并在本机运行："
    echo -e "    ${green}iperf3 -s${nc}（如未安装：apt install iperf3）"
}

function give_score() {
    echo -e "\n${blue}🏁 评分结果：$score / 70${nc}"
    if (( score >= 65 )); then
        echo -e "${green}✅ 等级：A+ - 全绿配置，强力落地，中转无忧！${nc}"
    elif (( score >= 50 )); then
        echo -e "${yellow}⚠️ 等级：B - 有提升空间，建议调整参数${nc}"
    else
        echo -e "${red}❌ 等级：C - 未达标，请立即优化！${nc}"
    fi
}

function run_all() {
    print_title
    check_param
    check_limits
    check_latency_speed
    check_bandwidth
    give_score
    echo -e "\n${green}✅ 检查完成。建议每次新 VPS 部署后运行此脚本确认 TCP 优化状态。${nc}"
}

run_all
