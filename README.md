# onekey

Surge / Shadowrocket 一键部署脚本：**Hysteria2 + Snell v5**，交互式菜单，开箱即用。

- **Hysteria2**（主力）：UDP/QUIC，自动申请 Let's Encrypt 证书，支持**端口跳跃**、伪装网站、可选 Salamander 混淆
- **Snell v5**（备用）：TCP，Surge 官方协议，UDP 被限速/阻断时自动回落
- **IPv4 / IPv6 双线路**：默认 IPv4，可在客户端切换 IPv6
- **自动检测 VPS 带宽**并写入 Hysteria2 服务端配置
- **自动开启 BBR**，调大 UDP 缓冲区
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
  onekey v1.0.0 —— Hysteria2 + Snell for Surge / Shadowrocket
  ------------------------------------------------
  状态：Hysteria2 active | Snell active | BBR bbr | SSH 端口 22
  ------------------------------------------------
  1. 安装 Hysteria2 + Snell
  2. 查看客户端配置（Surge / Shadowrocket 二维码）
  3. 重新检测带宽并更新
  ------------------------------------------------
  4. 修改 SSH 端口
  5. 禁用密码登录（仅允许密钥登录）
  6. 开启 BBR
  ------------------------------------------------
  7. 更新 Hysteria2 / Snell
  8. 卸载
  0. 退出
```

每个操作完成后会回到主菜单。也可以直接带参数执行单个功能：

```bash
bash install.sh install     # 安装
bash install.sh info        # 查看客户端配置
bash install.sh bandwidth   # 重新检测带宽
bash install.sh ssh-port    # 修改 SSH 端口
bash install.sh ssh-key     # 禁用密码登录
bash install.sh bbr         # 开启 BBR
bash install.sh update      # 更新
bash install.sh uninstall   # 卸载
```

## 安装前准备

1. 一台 VPS：Debian 10+ / Ubuntu 20.04+ / CentOS Stream / Rocky / Alma，x86_64 或 ARM64
2. 一个域名，添加解析记录（**Cloudflare 请关闭小黄云，设为「仅 DNS」**）：

   | 类型 | 主机记录 | 值 |
   |---|---|---|
   | A | `hy` | VPS 的 IPv4 |
   | AAAA | `hy` | VPS 的 IPv6（没有 IPv6 可不加） |

3. 云服务商安全组放行（IPv4/IPv6 都要）：

   | 端口 | 协议 | 用途 |
   |---|---|---|
   | 80 | TCP | 证书申请与续期 |
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

## 带宽说明

- 安装时用 Cloudflare 测速自动检测 VPS 上下行带宽，写入 Hysteria2 服务端 `bandwidth`
- VPS **上行** = 你的**下载**速度上限，VPS **下行** = 你的**上传**速度上限
- Surge 的 `download-bandwidth` 请填**你本地宽带的下行带宽**。跨境线路丢包严重时填得过高反而更慢，建议从较低值开始逐步调高
- 更换网络或 VPS 升级后，可通过菜单 `3` 重新检测

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
| `/etc/sysctl.d/99-onekey.conf` | BBR 与 UDP 缓冲区 |

## 致谢

- [apernet/hysteria](https://github.com/apernet/hysteria)
- [Snell](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell) by Surge Networks

## License

MIT
