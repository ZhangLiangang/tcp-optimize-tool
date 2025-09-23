TCP Optimize All-in-One Script

A powerful, one-click TCP optimizer for VPS and server environments.

This script performs full TCP stack tuning for modern congestion control algorithms like **BBR**, **FQ**, and improves Linux networking performance by modifying `sysctl`, `limits.conf`, and `systemd` settings. After optimization, it runs a live diagnostic and scoring report.

---

## 🚀 Quick Install (One-Liner)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ZhangLiangang/tcp-optimize-tool/main/install.sh) apply --profile=auto


```

---

## 🔧 What it does:

✅ Enables **BBR** congestion control  
✅ Enables **FQ** (Fair Queueing) queuing discipline  
✅ Writes best-practice **sysctl** tuning for TCP performance  
✅ Enlarges system and per-process file descriptor limits  
✅ Adds `pam_limits.so` to PAM config if missing  
✅ Writes `DefaultLimitNOFILE=1048576` to `systemd` manager config  
✅ Downloads and runs [`tcp-diagnose`](tcp-diagnose.sh) to generate a live report and score

---

## 🧪 Example Output

```
🚀 自动 TCP 网络优化 + BBR 启用 + 参数检测 一键完成

[+] 设置 sysctl 配置...
[+] 配置文件句柄限制...
[+] 下载体检脚本并执行...

🧪 TCP Diagnose Tool - By cosloc.net

▶️ TCP Parameters:
  ✅ Congestion Control: bbr
  ✅ Queuing Discipline: fq
  ✅ tcp_rmem: 67108864
  ✅ tcp_wmem: 67108864

▶️ File Descriptors:
  ✅ fs.file-max: 1048576
  ✅ ulimit -n: 1048576

▶️ Network Test:
  ⏱️  time_connect: 0.064s
  🚀  download_speed: 83 KB/s

🏁 Score: 70 / 70
✅ Grade: A+ - Fully optimized for high performance proxy usage!
```

---

## 📥 Recommended Use Cases

- Before launching proxy/V2Ray/Xray/relay nodes
- After provisioning a new VPS
- Airport or middlebox optimization
- Automated baseline network hardening

---

## 📜 License

MIT © 2024 liangang 
