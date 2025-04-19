#!/bin/bash

echo -e "\033[1;34m🚀 自动 TCP 网络优化 + BBR 启用 + 参数检测 一键完成\033[0m"

# 启用 BBR + FQ
echo -e "\n[+] 设置 sysctl 配置..."
cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
fs.file-max = 1048576
EOF

sysctl --system

# 设置文件句柄限制
echo -e "\n[+] 配置文件句柄限制..."
LIMITS_CONF="/etc/security/limits.conf"
PAM_CONF="/etc/pam.d/common-session"

grep -q "nofile" $LIMITS_CONF || cat >> $LIMITS_CONF <<EOF
* soft nofile 1048576
* hard nofile 1048576
EOF

grep -q "pam_limits.so" $PAM_CONF || echo "session required pam_limits.so" >> $PAM_CONF

# 提示重启 systemd 的方式（可选）
mkdir -p /etc/systemd/system.conf.d
echo -e "[Manager]\nDefaultLimitNOFILE=1048576" > /etc/systemd/system.conf.d/limits.conf

# 下载并运行诊断脚本
echo -e "\n[+] 下载体检脚本并执行..."
curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/tcp-diagnose.sh -o /usr/local/bin/tcp-diagnose
chmod +x /usr/local/bin/tcp-diagnose

tcp-diagnose
