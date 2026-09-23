# onekey

Surge / Shadowrocket 一键部署脚本：**Hysteria2 + Snell v5**，交互式菜单，开箱即用。

- **交互式添加域名**：可手动解析，或填 Cloudflare API Token **自动添加 A/AAAA 记录**；自动等待解析生效
- **自动申请证书**：Let's Encrypt，支持 HTTP 验证或 Cloudflare DNS 验证（无需 80 端口），自动续期
- **Hysteria2**（主力）：UDP/QUIC，支持**端口跳跃**、伪装网站、可选 Salamander 混淆
- **Snell v5**（备用）：TCP，Surge 官方协议，UDP 被限速/阻断时自动回落
- **IPv4 / IPv6 双线路**：默认 IPv4，可在客户端切换 IPv6
- **自动检测 VPS 带宽**并写入 Hysteria2 服务端配置
- **网络诊断（只读）**：国内三网延迟/丢包、PMTU、重传与队列丢包增量
- **有依据的网络调优**：BBR + fq（并修正网卡实际队列），TCP 缓冲按实测 BDP 计算；先展示计划再确认，自动备份，**一键回滚**
- **修改 SSH 端口**（新旧端口过渡，确认可登录后再关闭旧端口）
- **禁用密码登录，仅允许密钥登录**（支持粘贴公钥 / 服务器生成密钥对）
- 自动输出 **Surge 配置**和 **Shadowrocket 链接 + 终端二维码**

## 一键安装

以 root 用户执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/NextCandy/onekey/main/install.sh)
```

> 请使用 `bash <(curl ...)` 的形式运行，不要用 `curl ... | bash`，否则交互输入无法使用。

## 菜单

```
  onekey v1.2.0 —— Hysteria2 + Snell for Surge / Shadowrocket
  ------------------------------------------------
  状态：Hysteria2 active | Snell active | BBR bbr | SSH 端口 22
  ------------------------------------------------
  1. 安装 Hysteria2 + Snell
  2. 查看客户端配置（Surge / Shadowrocket 二维码）
  3. 域名与证书（查看 / 更换域名 / 重新申请）
  4. 重新检测带宽并更新
  ------------------------------------------------
  5. 网络诊断（只读：三网延迟丢包 / PMTU / 重传）
  6. 网络调优（BBR + fq + 按 BDP 计算缓冲，可回滚）
  7. 回滚网络调优
  ------------------------------------------------
  8. 修改 SSH 端口
  9. 禁用密码登录（仅允许密钥登录）
  ------------------------------------------------
 10. 更新 Hysteria2 / Snell
 11. 卸载
  0. 退出
```

每个操作完成后会回到主菜单。也可以直接带参数执行单个功能：

```bash
bash install.sh install     # 安装
bash install.sh info        # 查看客户端配置
bash install.sh domain      # 域名与证书
bash install.sh bandwidth   # 重新检测带宽
bash install.sh diag        # 网络诊断（只读）
bash install.sh tune        # 网络调优
bash install.sh tune-rollback  # 回滚网络调优
bash install.sh ssh-port    # 修改 SSH 端口
bash install.sh ssh-key     # 禁用密码登录
bash install.sh update      # 更新
bash install.sh uninstall   # 卸载
```

## 安装前准备

1. 一台 VPS：Debian 10+ / Ubuntu 20.04+ / CentOS Stream / Rocky / Alma，x86_64 或 ARM64
2. 一个域名。安装时脚本会交互式引导：
   - 显示需要添加的记录（A → VPS IPv4，AAAA → VPS IPv6），**Cloudflare 必须关闭小黄云（仅 DNS）**
   - 可以自己去 DNS 后台添加，也可以填 **Cloudflare API Token 由脚本自动添加**
   - 脚本通过 DoH 查询公共 DNS，**自动等待解析生效**后再申请证书

3. 云服务商安全组放行（IPv4/IPv6 都要）：

   | 端口 | 协议 | 用途 |
   |---|---|---|
   | 80 | TCP | 证书申请与续期（选 DNS 验证则不需要） |
   | 443 | UDP | Hysteria2 |
   | 20000-50000 | UDP | Hysteria2 端口跳跃 |
   | Snell 端口 | TCP + UDP | Snell v5 |

   系统防火墙（ufw / firewalld）脚本会自动放行，**不会关闭防火墙**。

## 客户端配置

安装完成后会输出，也可随时通过菜单 `2` 查看，保存在 `/root/onekey_client.txt`。

### Surge

```ini
[General]
ipv6 = true   # 使用 IPv6 线路时需要

[Proxy]
US HY2 = hysteria2, hy.example.com, 443, password=xxx, sni=hy.example.com, download-bandwidth=500, port-hopping="20000-50000", port-hopping-interval=30, ip-version=v4-only
US Snell = snell, hy.example.com, 12345, psk=xxx, version=5, reuse=true, ip-version=v4-only
US HY2 v6 = hysteria2, ..., ip-version=v6-only
US Snell v6 = snell, ..., ip-version=v6-only

[Proxy Group]
US = fallback, "US HY2", "US Snell", interval=300, timeout=5
US IPv6 = fallback, "US HY2 v6", "US Snell v6", interval=300, timeout=5
```

把 `US` / `US IPv6` 加入你原有的 `Proxy` 选择组即可，原有规则无需修改。

### Shadowrocket

脚本会输出 `hysteria2://` 链接和终端二维码（IPv4、IPv6 各一个），复制链接或扫码即可导入。Shadowrocket 不支持 Snell v5，只提供 Hysteria2。

## 域名与证书

| 证书验证方式 | 要求 | 说明 |
|---|---|---|
| HTTP 验证（默认） | 80/tcp 空闲且对外开放 | 适用于任何 DNS 服务商 |
| DNS 验证 | 域名托管在 Cloudflare | 不需要 80 端口，适合 80 端口被封或被占用的机器 |

Cloudflare API Token 在 <https://dash.cloudflare.com/profile/api-tokens> 创建，使用「Edit zone DNS」模板即可（权限：Zone → DNS → Edit）。Token 保存在服务器上权限为 600 的文件中，用于自动续期。

证书到期前由 Hysteria2 自动续期。菜单 `3` 可以查看证书状态、更换域名（重新引导解析并申请证书）、强制重新申请。

## 带宽说明

- 安装时用 Cloudflare 测速自动检测 VPS 上下行带宽，写入 Hysteria2 服务端 `bandwidth`
- VPS **上行** = 你的**下载**速度上限，VPS **下行** = 你的**上传**速度上限
- Surge 的 `download-bandwidth` 请填**你本地宽带的下行带宽**。跨境线路丢包严重时填得过高反而更慢，建议从较低值开始逐步调高
- 带宽检测对象是 Cloudflare，结果代表 **VPS 端口能力上限**，不代表到国内的真实速度
- 更换网络或 VPS 升级后，可通过菜单 `4` 重新检测

## 网络诊断与调优

原则：**先测量，有证据才改，所有改动可回滚**。不预设 `MTU=1440`、`TBF`、`256MB 缓冲` 这类"万能参数"。

**诊断（菜单 5，只读）**：内核/网卡/队列/缓冲现状，国内三网（IPv4/IPv6）延迟与丢包，PMTU，10 秒内 TCP 重传、网卡队列丢包、UDP 缓冲错误的**增量**。

判断方法：

| 现象 | 结论 |
|---|---|
| 网卡队列丢包为 0，但重传高 | 路径 / 上游 / 对端问题，本机调参和限速无法解决 |
| UDP 缓冲错误持续增长 | 需要调大 UDP 缓冲（影响 Hysteria2） |
| 网卡实际队列不是 fq | `default_qdisc` 只对新建队列生效，需要调优修正 |
| 中间路由器 ICMP 丢包高、终点不丢 | ICMP 限速，不是真实丢包 |

**调优（菜单 6）**：先测国内 RTT，结合 VPS 带宽和内存计算，**展示计划并确认后**才写入：

| 项目 | 取值 | 依据 |
|---|---|---|
| 拥塞控制 / 队列 | BBR + fq，并把网卡现有队列切换为 fq | 内核支持 BBR 时 |
| TCP 缓冲上限 | 2 × BDP，限制在 8–64MB 且 ≤ 内存 1/16 | 带宽 × 国内 RTT（影响 Snell 等 TCP 协议） |
| UDP 缓冲 | ≥ 16MB | Hysteria2 / QUIC |
| `tcp_notsent_lowat` | 128KB | 降低大缓冲带来的排队延迟 |
| `tcp_slow_start_after_idle` | 0 | 代理长连接空闲后不重新慢启动 |
| `tcp_mtu_probing` | 1 | 仅在 PMTU 黑洞时生效（部分服务商丢弃 ICMP） |
| MTU / TBF / HTB | **不修改** | 没有 PMTU 异常或本机队列丢包证据时不动 |

改动写入 `/etc/sysctl.d/99-onekey.conf`，说明文件 `/etc/sysctl.d/99-onekey.profile.md`，修改前的配置和运行时参数备份在 `/etc/onekey/tune-backup/`。菜单 `7` 可恢复到调优前的原始状态（文件、运行时参数、网卡队列）。

> Hysteria2 走 UDP，不受 TCP 缓冲影响；跨境线路丢包严重时，调低客户端 `download-bandwidth` 或改用 IPv6 线路往往比调内核参数更有效。
> 测真实下载方向，请在国内设备上用 iperf3 或测速网站走代理测试。

## SSH 安全选项

**修改 SSH 端口**：先让新旧端口同时监听，提示你用新端口测试登录，确认成功后才关闭旧端口；配置校验失败会自动回滚。兼容 Ubuntu 22.10+ 的 `ssh.socket`、SELinux。

**禁用密码登录**：先添加公钥（粘贴 / 服务器生成 / 沿用已有），提示你确认密钥可以登录后，才关闭密码登录。

> 操作 SSH 时**不要关闭当前窗口**，新开一个终端测试。修改前的配置会备份为 `/etc/ssh/sshd_config.onekey.<时间>`。

## 已有安装

如果 VPS 上已经用其他方式装好了 Hysteria2（`/etc/hysteria/config.yaml`）和 Snell（`/etc/snell/snell-server.conf`），脚本会自动导入现有配置，**不会更改密码**，可直接查看客户端配置、重新检测带宽。

## 文件位置

| 路径 | 说明 |
|---|---|
| `/etc/hysteria/config.yaml` | Hysteria2 服务端配置 |
| `/etc/snell/snell-server.conf` | Snell 配置 |
| `/etc/onekey/onekey.env` | 安装参数（含密码，权限 600） |
| `/root/onekey_client.txt` | 客户端配置（含密码，权限 600） |
| `/usr/local/bin/hy2-porthop.sh` | 端口跳跃 iptables 规则 |
| `/etc/sysctl.d/99-onekey.conf` | 网络调优参数 |
| `/etc/sysctl.d/99-onekey.profile.md` | 调优依据说明 |
| `/etc/onekey/tune-backup/` | 调优前备份（用于回滚） |

## 开发进度

进度、测试结论和待办事项见 [docs/PROGRESS.md](docs/PROGRESS.md)。

## 致谢

- [apernet/hysteria](https://github.com/apernet/hysteria)
- [Snell](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell) by Surge Networks

## License

MIT
