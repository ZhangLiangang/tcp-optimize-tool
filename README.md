# tcp-optimize-tool

开箱即用的 VPS 网络与 I/O 性能增强 脚本，支持一键安装、自检、诊断、自动修复与回滚。
默认启用（若内核支持）：BBR/BBRv2、fq qdisc、合理的 sysctl 阈值、RPS/XPS、多核中断分流、limits & systemd 限额提升。
提供 diagnose（安全）与 "diagnose aggressive"（进取）两种自动调优模式。

【一键安装与运行（需要 root 或可使用 sudo 的账号）】
curl 版本：
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh)"

wget 版本：
bash -c "$(wget -qO- https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh)"

默认动作是 apply（安装并应用优化 + 自检）。
也可以在后面传子命令：apply / diagnose / "diagnose aggressive" / status / selftest / rollback / purge

示例：
# 仅安装并立即执行“安全诊断 + 自动修复”
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh)" -s -- diagnose

# 进取诊断（可能关闭 GRO/GSO/TSO，自动持久化；可 rollback）
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh)" -s -- "diagnose aggressive"

【手动安装（可选）】
sudo curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/vps-ultimate-net.sh -o /usr/local/sbin/vps-ultimate-net.sh
sudo chmod +x /usr/local/sbin/vps-ultimate-net.sh
sudo /usr/local/sbin/vps-ultimate-net.sh apply

【常用命令】
sudo /usr/local/sbin/vps-ultimate-net.sh status           # 查看状态
sudo /usr/local/sbin/vps-ultimate-net.sh selftest         # 自检（失败退出码非 0）
sudo /usr/local/sbin/vps-ultimate-net.sh diagnose         # 安全诊断 + 自动修复
sudo /usr/local/sbin/vps-ultimate-net.sh "diagnose aggressive"  # 进取诊断 + 必要时关闭 offload
sudo /usr/local/sbin/vps-ultimate-net.sh rollback         # 回滚所有改动
sudo /usr/local/sbin/vps-ultimate-net.sh purge            # 回滚并删除备份

【设计取舍】
- 安全优先：不强改 MTU/防火墙；offload 仅在“进取模式 + 明显异常 + 驱动不在白名单”时才动。
- 可回滚：rollback 会移除 sysctl/limits/systemd 单元与持久化 offload 服务。
- 可验证：selftest 和 status 可随时验证生效情况。

【支持平台】
- Debian/Ubuntu 系（systemd 环境）。其他系统大多也能跑，但未全面测试。

- 建议的执行顺序：
``
# 1) 一键安装并应用
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh)"

# 2) 重启一次（让 systemd 限额完全继承）
sudo reboot

# 3) 开机后做安全诊断（会自动修复安全项）
sudo /usr/local/sbin/vps-ultimate-net.sh diagnose

# 如需更激进的 NIC 优化（满足条件才会动 offload）
sudo /usr/local/sbin/vps-ultimate-net.sh "diagnose aggressive"

# 4) 查看当前状态
sudo /usr/local/sbin/vps-ultimate-net.sh status

``
