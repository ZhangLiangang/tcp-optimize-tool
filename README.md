# tcp-optimize-tool

面向 **Debian / Ubuntu VPS** 的自适应 TCP / Linux 网络栈优化工具。

项目目标不是简单堆叠大量 `sysctl` 参数，而是根据 VPS 的实际环境自动检测：

- Linux 内核与 BBR / BBRv2 支持
- CPU 核心数量
- 系统内存
- 默认路由网卡
- RX / TX Queue 数量
- 网卡多队列能力
- RPS / XPS 支持情况
- 当前 qdisc
- systemd 环境

然后应用相对保守、可验证、可回滚的优化配置。

主要功能包括：

- BBR / BBRv2 自动检测
- `fq` qdisc
- TCP Buffer 自适应配置
- TCP Receive Buffer Autotuning
- 自适应 `netdev_max_backlog`
- 自适应 `somaxconn`
- RPS / XPS 自动判断与 CPU Queue 分配
- systemd / NOFILE 限额配置
- 状态查看
- 配置自检
- 只读网络诊断
- 深度网络诊断
- 配置修复
- Baseline 备份
- 真正的配置回滚
- 完整卸载 / purge

---

# 支持平台

主要支持：

- Debian
- Ubuntu

建议：

- Debian 11 / 12 / 13
- Ubuntu 20.04 LTS+
- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS+

要求：

- Linux
- systemd
- root 权限或可使用 `sudo`
- 内核支持 BBR 或 BBRv2

其他 Debian 系发行版可能可以运行，但没有作为主要测试平台。

---

# 设计原则

## 1. 不盲目追求“大参数”

工具不会再把所有 VPS 都固定设置成：

```text
128 MiB TCP Buffer
250000 netdev_max_backlog
1048576 NOFILE
所有 Queue → 所有 CPU
```

而是根据：

```text
CPU
RAM
RX Queue
TX Queue
内核能力
```

自动决定配置。

---

## 2. BBR 是 apply 的最低要求

执行：

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh apply
```

时会首先检测：

```text
BBRv2
BBR
```

优先顺序：

```text
BBRv2
  ↓
BBR
  ↓
都不存在 → 中止 apply
```

如果当前内核没有提供 BBR / BBRv2，脚本不会继续写入完整优化配置。

---

## 3. Diagnose 永远不偷偷修改系统

以下命令：

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh diagnose
```

现在是 **只读诊断**。

不会：

- 修改 sysctl
- 修改 RPS / XPS
- 修改 qdisc
- 修改 GRO / GSO / TSO
- 修改 systemd
- 修改 limits

深度诊断：

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh "diagnose aggressive"
```

同样不会修改系统。

`aggressive` 的含义现在是：

> 执行更多、更深入的网络检查。

而不是“进行更激进的自动修改”。

---

## 4. 不再自动关闭 GRO / GSO / TSO

旧版本可能根据 loopback `iperf3` 性能推断 NIC offload 是否异常。

新版已经移除这一逻辑。

原因是：

```text
127.0.0.1 loopback
```

并不会经过真实 VPS 网卡的数据路径，因此不能用于判断：

```text
GRO
GSO
TSO
```

是否应该关闭。

新版仅报告 NIC offload 状态，不自动修改。

---

# 一键安装

## curl

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh)"
```

默认操作：

```text
apply
```

也就是：

```text
下载安装
    ↓
检查系统
    ↓
检查依赖
    ↓
检测 BBR
    ↓
生成自适应配置
    ↓
应用配置
    ↓
运行 selftest
```

---

## wget

如果系统已经安装 `wget`：

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh)"
```

---

# 推荐安装流程

```bash
# 1. 一键安装并应用优化

bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh)"


# 2. 重启一次

sudo reboot


# 3. 重启后检查配置

sudo /usr/local/sbin/vps-ultimate-net.sh selftest


# 4. 运行网络诊断

sudo /usr/local/sbin/vps-ultimate-net.sh diagnose


# 5. 如需要更多诊断信息

sudo /usr/local/sbin/vps-ultimate-net.sh "diagnose aggressive"


# 6. 查看当前状态

sudo /usr/local/sbin/vps-ultimate-net.sh status
```

---

# 手动安装

如果不想使用 `install.sh`：

```bash
sudo curl -fsSL \
https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/vps-ultimate-net.sh \
-o /usr/local/sbin/vps-ultimate-net.sh
```

添加执行权限：

```bash
sudo chmod +x /usr/local/sbin/vps-ultimate-net.sh
```

应用：

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh apply
```

然后建议：

```bash
sudo reboot
```

---

# 常用命令

## 应用优化

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh apply
```

执行：

- 系统检测
- BBR / BBRv2 检测
- CPU / RAM 检测
- 网卡检测
- Queue topology 检测
- Baseline 保存
- sysctl 配置
- RPS / XPS 配置
- limits 配置
- systemd 配置
- selftest

---

## 查看状态

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh status
```

用于查看：

- 当前拥塞控制算法
- qdisc
- TCP Buffer
- backlog
- somaxconn
- RPS
- XPS
- NOFILE
- 当前网卡状态

不会修改系统。

---

## Selftest

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh selftest
```

验证工具管理的配置是否真正生效。

如果存在关键失败项：

```text
exit code != 0
```

适合自动化部署后检查。

---

## 普通诊断

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh diagnose
```

只读检查：

- OS / Kernel
- CPU
- RAM
- 默认路由
- 主网卡
- NIC Driver
- RX / TX Queue
- BBR
- qdisc
- TCP Buffer
- RPS / XPS
- 当前 sysctl
- 网卡基础状态

不会自动修改系统。

---

## 深度诊断

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh "diagnose aggressive"
```

在普通诊断基础上增加更深入检查，例如：

- NIC offload 状态
- GRO
- GSO
- TSO
- Softnet statistics
- NIC RX / TX counters
- Queue topology
- RPS / XPS 分布

注意：

> aggressive 现在表示“更深入的诊断”，而不是“更激进地修改系统”。

不会自动关闭 GRO / GSO / TSO。

---

## Repair

如果配置文件被手动修改、删除或者系统状态发生漂移：

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh repair
```

用于重新应用本工具管理的配置。

建议优先：

```text
diagnose
    ↓
确认问题
    ↓
repair
```

而不是让 diagnose 自动修改系统。

---

# Rollback

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh rollback
```

新版 rollback 不再只是删除工具写入的文件。

第一次 `apply` 会保存 baseline：

```text
/var/backups/vps-ultimate-net/baseline-v2/
```

其中包括：

```text
files.tsv
sysctl.tsv
rps-xps.tsv
services.tsv
rootfs/
```

rollback 会尽可能恢复：

- apply 前的配置文件
- apply 前的 sysctl runtime 值
- apply 前的 RPS / XPS mask
- apply 前的 systemd service 状态

因此新版 rollback 是真正意义上的：

```text
恢复 apply 前状态
```

---

# Purge

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh purge
```

执行：

```text
rollback
    +
移除本工具产生的配置
    +
清理工具相关备份/状态
```

适用于不再使用本工具的情况。

---

# TCP Buffer 自适应策略

新版不会给每一台 VPS 强制使用相同 buffer。

大致策略：

| VPS RAM | TCP Buffer Max | netdev backlog | somaxconn |
|---:|---:|---:|---:|
| `< 1 GiB` | 16 MiB | 8192 | 8192 |
| `1–2 GiB` | 32 MiB | 16384 | 16384 |
| `2–8 GiB` | 64 MiB | 32768 | 32768 |
| `>= 8 GiB` | 128 MiB | 65536 | 65535 |

同时启用：

```text
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
```

使 Linux TCP Receive Buffer Autotuning 正常工作。

这些参数是容量上限，不代表每一个 TCP Connection 都会直接占用对应大小的内存。

---

# RPS / XPS 自适应策略

旧版会倾向于：

```text
每个 RX Queue → 所有 CPU
每个 TX Queue → 所有 CPU
```

新版会分析：

```text
CPU 数
RX Queue 数
TX Queue 数
```

再决定是否需要 RPS / XPS。

典型逻辑：

```text
CPU = 1
→ 不启用额外 RPS/XPS 分流
```

```text
RX Queue >= CPU
→ 通常依赖 RSS / multiqueue
→ 不强制开启 RPS
```

```text
RX Queue < CPU
→ 根据 Queue 数将 CPU 分组
→ 给不同 Queue 分配不同 CPU mask
```

```text
TX Queue = 1
→ 通常不配置 XPS
```

```text
TX Queue > 1
→ 根据 CPU / TX Queue topology 分组
```

这样可以减少无意义的：

```text
CPU migration
IPI
queue contention
```

---

# 默认路由网卡检测

新版优先根据：

```bash
ip route
```

查找真正的默认出口网卡。

例如：

```text
default via 192.0.2.1 dev eth0
```

则使用：

```text
eth0
```

而不是简单选择系统中“第一个有 IPv4 地址的网卡”。

这对存在以下设备的服务器尤其重要：

```text
eth0
eth1
wg0
tun0
docker0
veth*
tailscale0
private network
```

---

# sysctl 策略

新版仅管理与通用 VPS TCP / 网络栈优化关系比较明确的参数。

不会为了所谓“一键优化”无条件修改大量内核参数。

例如不再默认修改：

```text
net.ipv4.tcp_tw_reuse
net.ipv4.route.gc_timeout
net.ipv4.neigh.default.gc_thresh*
```

也不会为了追求“大数字”强制所有服务器：

```text
net.core.netdev_max_backlog = 250000
```

---

# 文件与目录

主要文件：

```text
/usr/local/sbin/vps-ultimate-net.sh
```

sysctl：

```text
/etc/sysctl.d/99-vps-ultimate-net.conf
```

limits：

```text
/etc/security/limits.d/99-vps-ultimate-net.conf
```

systemd Manager limits：

```text
/etc/systemd/system.conf.d/99-vps-ultimate-net.conf
```

RPS / XPS helper：

```text
/usr/local/sbin/vps-ultimate-net-rps-apply.sh
```

RPS / XPS systemd service：

```text
/etc/systemd/system/vps-ultimate-net-rps.service
```

备份：

```text
/var/backups/vps-ultimate-net/
```

---

# 关于重启

`apply` 后建议执行：

```bash
sudo reboot
```

主要原因不是 BBR 本身必须重启，而是：

- systemd Manager Limit
- 登录 Session
- NOFILE
- 服务启动环境
- 网络初始化顺序

在重启以后状态更加统一。

重启后建议：

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh selftest
```

然后：

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh diagnose
```

---

# 关于旧版本升级

如果 VPS 之前已经运行过旧版 `vps-ultimate-net.sh`：

```text
旧版本
    ↓
已经修改系统
    ↓
第一次运行 V2 apply
```

V2 保存的 baseline 是：

```text
运行 V2 之前的当前系统状态
```

因此如果旧版配置当时仍处于启用状态：

```text
V2 baseline
≈
旧版优化后的状态
```

而不是 VPS 最初安装 Debian / Ubuntu 时的原始状态。

这是有意设计：

> 新版本不会猜测服务器过去不存在记录的原始配置。

---

# 推荐使用方式

对于长期使用的 VPS，推荐：

```bash
# 安装

bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh)"


# 重启

sudo reboot


# 验证

sudo /usr/local/sbin/vps-ultimate-net.sh selftest


# 诊断

sudo /usr/local/sbin/vps-ultimate-net.sh diagnose


# 查看状态

sudo /usr/local/sbin/vps-ultimate-net.sh status
```

如果发现配置漂移：

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh repair
```

如果希望恢复安装前状态：

```bash
sudo /usr/local/sbin/vps-ultimate-net.sh rollback
```

---

# 安全说明

本工具不会主动修改：

- MTU
- iptables
- nftables
- SSH
- DNS
- IPv4 / IPv6 地址
- 默认路由
- 防火墙规则

也不会因为简单 benchmark 自动关闭：

- GRO
- GSO
- TSO

任何生产服务器在修改网络栈参数之前，仍建议保留：

- VPS Provider Console
- Serial Console
- Rescue Mode
- Snapshot / Backup

以避免因服务器自身环境差异造成不可预期问题。

---

# 项目文件

```text
install.sh
```

负责：

```text
环境检测
依赖安装
安全下载
版本更新
调用主程序
```

---

```text
vps-ultimate-net.sh
```

核心网络优化程序：

```text
apply
status
selftest
diagnose
diagnose aggressive
repair
rollback
purge
```

---

```text
tcp-diagnose.sh
```

独立只读 TCP / 网络诊断工具。

它不会修改系统配置，可用于：

```text
优化前检查
优化后验证
新 VPS 体检
网络故障分析
```

---

# License

请根据仓库实际 License 文件填写或保留对应许可说明。
