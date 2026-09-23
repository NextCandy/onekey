# 进度与交接

> 最后更新：2026-09-23 ｜ 当前版本：v1.2.0
> 本文件记录开发进度、测试结论和待办事项，方便在其他设备继续。
> **公开仓库：这里不记录任何密码、私钥、真实 IP 或域名。** 服务器用别名 `us-hy` 指代。

## 当前部署（us-hy）

| 项目 | 状态 |
|---|---|
| 服务器 | 美国 VPS，KVM，3 核 / 4.9G，Ubuntu 26.04，内核 7.0，单队列 virtio 网卡，IPv4 + IPv6 双栈 |
| 角色 | 落地机：用户 → us-hy → 互联网（无中转） |
| 服务 | Hysteria2 UDP 443 + 端口跳跃 20000-50000（IPv4/IPv6），Snell v5 TCP |
| 证书 | Let's Encrypt，HTTP 验证，到期 2026-12-22，自动续期 |
| 安装方式 | **旧版脚本安装**（早于 onekey）。运行 onekey 会自动导入现有配置，密码不变。**不要选「1. 安装」**，会重新生成密码 |
| 服务端带宽 | `bandwidth: up 1000 mbps / down 200 mbps`（按用户要求手动设置） |
| 客户端 | Surge：`download-bandwidth=1000`，`ipv6 = true`；Shadowrocket：hysteria2 链接（含 `mport`） |
| 网络调优 | **尚未应用 v1.2.0 调优**，当前仍是旧配置（见下方检查结果） |

客户端配置（含密码）只保存在原设备本地和服务器 `/root/surge_proxy.conf`，不在仓库中。新设备上可在服务器执行 `bash install.sh info` 重新查看。

## 网络检查测试结论（2026-09-23，只读，未改配置）

方法参考"先测量、有证据才改、可回滚"的 VPS 调优原则。

**检查发现（有证据）：**

1. 网卡实际队列是 `pfifo_fast`，不是 fq —— `default_qdisc=fq` 只对新建队列生效
2. `tcp_wmem` 上限 4MB，国内 RTT 190–250ms → Snell（TCP）单连接理论上限约 140Mbps
3. IPv4 上 >约 1000 字节的 ICMP 被服务商丢弃（与 DF 无关）；tracepath 与真实 TCP 连接 PMTU 均为 1500 → 不是 MTU 问题，但有 PMTU 黑洞风险
4. UDP 缓冲 16MB，测试期间无 UDP 缓冲错误；网卡队列无丢包

**测试数据：**

| 测试 | 结果 |
|---|---|
| 国内三网 IPv4 | 联通 ~191ms 丢包 0%；电信 ~231ms 丢包 10–30%（波动）；移动 ~250ms 丢包 0–15% |
| 国内 IPv6（移动） | ~250ms 丢包 0% |
| TCP P1 → 东京测试机 | 163–179 Mbps，重传 0–0.03% |
| TCP P4 → 东京测试机 | 110 Mbps，重传 18%，**本机队列丢包 0** |
| Hysteria2 BBR / Brutal 500 / Brutal 1000 | 124 / 140 / 145 Mbps，队列丢包 0，UDP 错误 0 |
| VPS 端口带宽（Cloudflare） | 下行 740–2000 / 上行 1300–1900 Mbps |

**结论：**

- 本机未发现瓶颈。东京测试机自身约 170M 封顶（MSS 1320，有隧道），多流重传来自对端/路径，不能据此改全局配置
- 到国内的主要问题是**电信 IPv4 跨境丢包**，本机调参无法解决 → 优先 IPv6 线路或调低 `download-bandwidth`
- 不建议改：MTU、TBF/HTB、netdev_max_backlog、RPS（无证据）

## 待办

### 需要用户操作 / 确认

- [ ] **更换 SSH 密钥**：旧私钥曾在对话中出现。用菜单 `9` 添加新公钥并禁用密码登录；本地 `~/.ssh/config` 配置别名 `us-hy`，以后只提供别名
- [ ] **国内方向实测**（最关键，尚无数据）：国内设备上 Surge 分别选 IPv4 / IPv6 策略组测速；或在 us-hy 临时起 iperf3（需安全组放行端口）后执行 `iperf3 -c <服务器> -R -P 1` 和 `-P 4`
- [ ] 根据国内实测结果决定 `download-bandwidth`（IPv4 线路可能需要降到 300–500）和默认线路（IPv4 / IPv6）
- [ ] 是否在 us-hy 应用菜单 `6` 网络调优。预计计划：队列 pfifo_fast → fq；TCP 缓冲上限 4MB → 64MB（1460Mbps × 194ms，BDP≈33MB）；notsent_lowat 128KB、slow_start_after_idle 0、mtu_probing 1。预期提升 Snell 单连接上限，对 Hysteria2 影响不大

### 脚本待验证

- [ ] 全新 VPS 上完整跑一遍安装流程（各组件已单独实测，整体流程未跑过）
- [ ] Cloudflare API 自动添加解析 + DNS 验证申请证书（需要有效 Token）
- [ ] SSH 改端口、禁用密码登录的真实执行（目前只在 sshd 配置副本上 `sshd -t` 验证过）
- [ ] 调优在真实 VPS 上应用 + 回滚（目前只在 WSL 中验证过应用与回滚）
- [ ] RHEL 系（Rocky / Alma）上的 firewalld、SELinux 分支

### 可能的改进

- [ ] 诊断中增加可选 iperf3 服务端（限时自动关闭），方便国内设备直接测
- [ ] 带宽检测增加国内方向参考（目前只测 Cloudflare，代表端口上限）
- [ ] Snell v6 正式发布后评估升级（目前 v6 为 beta，Surge 5.20+ / Mac 6.7+ 支持）

## 在其他设备继续

```bash
git clone https://github.com/NextCandy/onekey.git
cd onekey
```

- 服务器上运行最新脚本：`bash <(curl -fsSL https://raw.githubusercontent.com/NextCandy/onekey/main/install.sh)`
- 用 Claude Code 继续：在仓库目录启动，`CLAUDE.md` 已记录项目约定；告诉它 SSH 别名（如 `ssh us-hy`）即可，不要粘贴私钥
- 提交请使用 GitHub 隐藏邮箱（仓库级配置，不改全局）：
  ```bash
  git config user.name "NextCandy"
  git config user.email "20787873+NextCandy@users.noreply.github.com"
  ```

## 版本记录

| 版本 | 内容 |
|---|---|
| v1.0.0 | Hysteria2 + Snell v5、端口跳跃、IPv4/IPv6 双线路、带宽检测、BBR、SSH 改端口 / 仅密钥登录、交互式菜单、导入已有安装 |
| v1.1.0 | 交互式添加域名、Cloudflare API 自动解析、DoH 等待生效、HTTP / DNS 证书验证、域名与证书菜单 |
| v1.2.0 | 网络诊断（只读）、按 BDP 计算的可回滚调优、修正 default_qdisc 不作用于已有队列、ping pipefail 修复 |
