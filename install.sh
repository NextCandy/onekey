#!/usr/bin/env bash
#
# onekey —— Surge / Shadowrocket 一键部署脚本
#   Hysteria2（主力，UDP/QUIC + 端口跳跃 + 自动 ACME 证书）
#   Snell v5（备用，TCP，仅 Surge）
#   自动检测带宽 / 网络诊断与可回滚调优（BBR+fq+BDP 缓冲）/ 修改 SSH 端口 / 仅密钥登录
#
# 支持系统：Debian 10+ / Ubuntu 20.04+ / CentOS Stream / Rocky / Alma
# 项目地址：https://github.com/NextCandy/onekey
# 用法：bash install.sh [install|info|domain|bandwidth|diag|tune|tune-rollback|ssh-port|ssh-key|update|uninstall]

set -euo pipefail

SCRIPT_VERSION="1.2.0"
SNELL_VERSION="v5.0.1"

ONEKEY_DIR="/etc/onekey"
ENV_FILE="${ONEKEY_DIR}/onekey.env"
HY2_CONF="/etc/hysteria/config.yaml"
SNELL_DIR="/etc/snell"
SNELL_CONF="${SNELL_DIR}/snell-server.conf"
SNELL_BIN="/usr/local/bin/snell-server"
SNELL_SERVICE="/etc/systemd/system/snell.service"
HOP_SCRIPT="/usr/local/bin/hy2-porthop.sh"
HOP_SERVICE="/etc/systemd/system/hy2-porthop.service"
SYSCTL_FILE="/etc/sysctl.d/99-onekey.conf"
SSHD_CONF="/etc/ssh/sshd_config"
INFO_FILE="/root/onekey_client.txt"

Green="\033[32m"; Red="\033[31m"; Yellow="\033[33m"; Blue="\033[36m"; Font="\033[0m"
ok()   { echo -e "${Green}[OK]${Font} $*"; }
info() { echo -e "${Blue}[..]${Font} $*"; }
warn() { echo -e "${Yellow}[!]${Font} $*"; }
die()  { echo -e "${Red}[ERR]${Font} $*" >&2; exit 1; }

rand_str() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}" || true; }
confirm()  { local yn; read -rp "$1 [y/N] " yn; [[ "${yn}" =~ ^[Yy]$ ]]; }
is_port()  { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# ============================================================
# 环境检查
# ============================================================

check_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 用户运行"
}

check_system() {
    [[ -f /etc/os-release ]] || die "无法识别系统"
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID}" in
        debian|ubuntu)
            PKG_UPDATE="apt-get update -y"
            PKG_INSTALL="apt-get install -y"
            ;;
        centos|rocky|almalinux|rhel|fedora)
            if command -v dnf >/dev/null; then
                PKG_UPDATE="dnf makecache -y"; PKG_INSTALL="dnf install -y"
            else
                PKG_UPDATE="yum makecache -y"; PKG_INSTALL="yum install -y"
            fi
            ;;
        *) die "不支持的系统：${ID}" ;;
    esac
    command -v systemctl >/dev/null || die "需要 systemd"
    ok "系统：${PRETTY_NAME}"
}

check_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   SNELL_ARCH="amd64" ;;
        aarch64|arm64)  SNELL_ARCH="aarch64" ;;
        armv7l)         SNELL_ARCH="armv7l" ;;
        i386|i686)      SNELL_ARCH="i386" ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
}

install_deps() {
    info "安装依赖..."
    $PKG_UPDATE >/dev/null
    $PKG_INSTALL curl unzip ca-certificates iptables iproute2 >/dev/null 2>&1 \
        || $PKG_INSTALL curl unzip ca-certificates iptables iproute >/dev/null
    command -v dig >/dev/null \
        || $PKG_INSTALL dnsutils >/dev/null 2>&1 || $PKG_INSTALL bind-utils >/dev/null 2>&1 || true
    command -v qrencode >/dev/null || $PKG_INSTALL qrencode >/dev/null 2>&1 || true
    command -v jq >/dev/null || $PKG_INSTALL jq >/dev/null 2>&1 || true
    command -v openssl >/dev/null || $PKG_INSTALL openssl >/dev/null 2>&1 || true
    command -v tracepath >/dev/null || $PKG_INSTALL iputils-tracepath >/dev/null 2>&1 || $PKG_INSTALL iputils >/dev/null 2>&1 || true
    ok "依赖安装完成"
}

port_in_use() {
    # $1=tcp|udp  $2=port
    local flag="-lnt"; [[ $1 == udp ]] && flag="-lnu"
    ss $flag 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$2\$"
}

resolve() {
    # $1=A|AAAA  $2=domain
    if command -v dig >/dev/null; then
        dig +short "$1" "$2" | grep -v '\.$' | tail -1
    elif [[ $1 == A ]]; then
        getent ahostsv4 "$2" | awk 'NR==1{print $1}'
    else
        getent ahostsv6 "$2" | awk 'NR==1{print $1}'
    fi
}

default_iface() {
    local dev
    dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "${dev}" ]] || dev=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    echo "${dev}"
}

# 从已有的 Hysteria2 / Snell 配置导入参数（兼容旧版脚本或手动安装），避免重装导致密码变化
import_existing() {
    [[ -f "${ENV_FILE}" ]] && return 0
    [[ -f "${HY2_CONF}" ]] || return 1
    DOMAIN=$(awk '/^ *domains:/{getline; print $2; exit}' "${HY2_CONF}")
    [[ -n "${DOMAIN}" ]] || return 1
    HY2_PORT=$(awk '/^listen:/{n=split($2, a, ":"); print a[n]; exit}' "${HY2_CONF}")
    HY2_PORT=${HY2_PORT:-443}
    HY2_PASS=$(awk '/^auth:/{f=1} f && /password:/{print $2; exit}' "${HY2_CONF}")
    BW_UP=$(awk '/^bandwidth:/{f=1} f && /up:/{print $2; exit}' "${HY2_CONF}")
    BW_DOWN=$(awk '/^bandwidth:/{f=1} f && /down:/{print $2; exit}' "${HY2_CONF}")
    BW_UP=${BW_UP:-100}; BW_DOWN=${BW_DOWN:-100}
    OBFS_PASS=$(awk '/^obfs:/{f=1} f && /password:/{print $2; exit}' "${HY2_CONF}")
    MASQ_URL=$(awk '/^masquerade:/{f=1} f && /url:/{print $2; exit}' "${HY2_CONF}")
    HOP_RANGE=""; HOP_INTERVAL="30"
    [[ -f "${HOP_SCRIPT}" ]] && HOP_RANGE=$(awk -F'"' '/^RANGE=/{gsub(":", "-", $2); print $2; exit}' "${HOP_SCRIPT}")
    SNELL_PORT=""; SNELL_PSK=""
    if [[ -f "${SNELL_CONF}" ]]; then
        SNELL_PORT=$(awk '/^listen/{n=split($3, a, ":"); print a[n]; exit}' "${SNELL_CONF}")
        SNELL_PSK=$(awk '/^psk/{print $3; exit}' "${SNELL_CONF}")
    fi
    CLIENT_DOWN=$(grep -ohE 'download-bandwidth=[0-9]+' /root/surge_proxy.conf "${INFO_FILE}" 2>/dev/null | head -1 | cut -d= -f2 || true)
    CLIENT_DOWN=${CLIENT_DOWN:-$(( BW_UP < 500 ? BW_UP : 500 ))}
    NODE_NAME=$(echo "${DOMAIN%%.*}" | tr '[:lower:]' '[:upper:]')
    ACME_TYPE=$(awk '/^acme:/{f=1} f && /^  type:/{print $2; exit}' "${HY2_CONF}")
    ACME_TYPE=${ACME_TYPE:-http}
    CF_TOKEN=$(awk '/cloudflare_api_token:/{print $2; exit}' "${HY2_CONF}")
    SERVER_IP4=$(curl -s4m8 https://api.ipify.org || true)
    SERVER_IP6=$(curl -s6m8 https://api6.ipify.org || true)
    save_env
    ok "已从现有配置导入安装信息（域名 ${DOMAIN}），密码保持不变"
}

load_env() {
    [[ -f "${ENV_FILE}" ]] || import_existing || die "未找到安装信息，请先执行安装"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
}

save_env() {
    mkdir -p "${ONEKEY_DIR}"
    cat >"${ENV_FILE}" <<EOF
NODE_NAME="${NODE_NAME}"
DOMAIN="${DOMAIN}"
SERVER_IP4="${SERVER_IP4}"
SERVER_IP6="${SERVER_IP6}"
HY2_PORT="${HY2_PORT}"
HY2_PASS="${HY2_PASS}"
HOP_RANGE="${HOP_RANGE}"
HOP_INTERVAL="${HOP_INTERVAL}"
OBFS_PASS="${OBFS_PASS}"
MASQ_URL="${MASQ_URL}"
SNELL_PORT="${SNELL_PORT}"
SNELL_PSK="${SNELL_PSK}"
BW_UP="${BW_UP}"
BW_DOWN="${BW_DOWN}"
CLIENT_DOWN="${CLIENT_DOWN}"
ACME_TYPE="${ACME_TYPE:-http}"
CF_TOKEN="${CF_TOKEN:-}"
EOF
    chmod 600 "${ENV_FILE}"
}

# ============================================================
# 网络诊断 / 调优（先测量、有依据才改、可回滚）
# ============================================================

# 国内三网探测目标（只发小 ICMP 包；部分服务商会丢弃大 ICMP 包）
CN_TARGETS4=("202.96.209.133:电信" "219.158.3.1:联通" "211.136.192.6:移动" "202.97.1.1:电信骨干")
CN_TARGETS6=("240e:e9:6002:15c::1:电信" "2408:8899::8:联通" "2409:8088::a:移动")
TUNE_KEYS="net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_notsent_lowat net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing"

# $1=4|6 $2=ip  输出 "丢包% 平均RTT"，不通输出空
ping_stat() {
    # ping 不通时返回非 0，在 pipefail 下会中断调用方，这里吞掉退出码
    { ping -"$1" -c 20 -i 0.2 -W 1 "$2" 2>/dev/null || true; } | awk -F'[ /,%]+' '
        /packet loss/ {for (i = 1; i <= NF; i++) if ($i == "packet") loss = $(i - 1)}
        /^rtt|^round-trip/ {avg = $8}
        END {if (avg != "") printf "%s %s\n", loss, avg}'
}

fmt_ping() {
    if [[ -n "$1" ]]; then echo "丢包 ${1% *}%  RTT ${1#* } ms"; else echo "不响应 ICMP（不代表不通）"; fi
}

# 到国内的中位 RTT（毫秒，整数）；全部不通时输出 0
china_rtt() {
    local t ip r rtts=()
    for t in "${CN_TARGETS4[@]}"; do
        ip=${t%%:*}; r=$(ping_stat 4 "${ip}")
        [[ -n "${r}" ]] && rtts+=("${r#* }")
    done
    if (( ${#rtts[@]} == 0 )); then
        for t in "${CN_TARGETS6[@]}"; do
            ip=${t%:*}; r=$(ping_stat 6 "${ip}")
            [[ -n "${r}" ]] && rtts+=("${r#* }")
        done
    fi
    (( ${#rtts[@]} > 0 )) || { echo 0; return; }
    printf '%s\n' "${rtts[@]}" | sort -n | awk '{a[NR] = $1} END {printf "%d\n", a[int((NR + 1) / 2)]}'
}

# 输出：TcpOutSegs TcpRetransSegs UdpRcvbufErrors(含v6) UdpSndbufErrors(含v6)
counters() {
    nstat -az 2>/dev/null | awk '{v[$1] = $2} END {printf "%d %d %d %d\n", v["TcpOutSegs"], v["TcpRetransSegs"],
        v["UdpRcvbufErrors"] + v["Udp6RcvbufErrors"], v["UdpSndbufErrors"] + v["Udp6SndbufErrors"]}'
}

root_qdisc() { tc qdisc show dev "$1" root 2>/dev/null | awk 'NR==1{print $2}'; }

# 让已存在的网卡队列也切换到 fq（default_qdisc 只对新建队列生效）
apply_fq() {
    local dev q
    dev=$(default_iface); [[ -n "${dev}" ]] || return 0
    q=$(root_qdisc "${dev}")
    case "${q}" in
        fq) ;;
        mq) tc qdisc del dev "${dev}" root 2>/dev/null || true ;;   # 删除后内核按 default_qdisc 重建 mq + fq 子队列
        *)  tc qdisc replace dev "${dev}" root fq 2>/dev/null || warn "无法把 ${dev} 的队列切换为 fq" ;;
    esac
    echo "   ${dev} 队列：${q:-未知} -> $(root_qdisc "${dev}")"
}

do_diag() {
    local dev t ip r a b d1 d2 o1 o2
    dev=$(default_iface)
    echo
    info "网络诊断（只读，不修改任何配置）"
    echo "== 系统"
    echo "   内核 $(uname -r) | CPU $(nproc) 核 | 内存 $(free -m | awk '/Mem:/{print $2}') MB | 网卡 ${dev} MTU $(cat /sys/class/net/"${dev}"/mtu 2>/dev/null)"
    echo "== TCP / 队列"
    echo "   拥塞控制 $(sysctl -n net.ipv4.tcp_congestion_control)（可用：$(sysctl -n net.ipv4.tcp_available_congestion_control)）"
    echo "   default_qdisc $(sysctl -n net.core.default_qdisc) | 网卡实际队列 $(root_qdisc "${dev}")"
    echo "   tcp_rmem [$(sysctl -n net.ipv4.tcp_rmem | tr '\t' ' ')] | tcp_wmem [$(sysctl -n net.ipv4.tcp_wmem | tr '\t' ' ')]"
    echo "   rmem_max $(sysctl -n net.core.rmem_max) | wmem_max $(sysctl -n net.core.wmem_max) | mtu_probing $(sysctl -n net.ipv4.tcp_mtu_probing)"
    [[ "$(root_qdisc "${dev}")" == "$(sysctl -n net.core.default_qdisc)" || "$(root_qdisc "${dev}")" == mq ]] \
        || warn "网卡实际队列与 default_qdisc 不一致（可通过「网络调优」修正）"

    echo "== 国内三网延迟 / 丢包（20 个小包）"
    for t in "${CN_TARGETS4[@]}"; do
        ip=${t%%:*}; r=$(ping_stat 4 "${ip}")
        printf "   IPv4 %-8s %-16s %s\n" "${t##*:}" "${ip}" "$(fmt_ping "${r}")"
    done
    if [[ -n "$(ip -6 route show default 2>/dev/null)" ]]; then
        for t in "${CN_TARGETS6[@]}"; do
            ip=${t%:*}; r=$(ping_stat 6 "${ip}")
            printf "   IPv6 %-8s %-24s %s\n" "${t##*:}" "${ip}" "$(fmt_ping "${r}")"
        done
    fi
    echo "   说明：中间路由器丢包多为 ICMP 限速，以终点为准；丢包在跨境路径上时，本机调参无法解决"

    echo "== PMTU"
    echo "   tracepath 1.1.1.1：$(tracepath -n -m 15 1.1.1.1 2>/dev/null | grep -oE 'pmtu [0-9]+' | tail -1 || echo 未知)"
    if [[ -n "$(ip -6 route show default 2>/dev/null)" ]]; then
        echo "   tracepath IPv6：$(tracepath -6 -n -m 15 2606:4700:4700::1111 2>/dev/null | grep -oE 'pmtu [0-9]+' | tail -1 || echo 未知)"
    fi

    echo "== 10 秒计数器增量（反映当前真实流量）"
    a=$(counters)
    d1=$(tc -s qdisc show dev "${dev}" | awk '/dropped/{gsub(",", ""); s += $7} END{print s + 0}')
    sleep 10
    b=$(counters)
    d2=$(tc -s qdisc show dev "${dev}" | awk '/dropped/{gsub(",", ""); s += $7} END{print s + 0}')
    read -r o1 x1 y1 z1 <<<"${a}"; read -r o2 x2 y2 z2 <<<"${b}"
    echo "   TCP 发送 $((o2 - o1)) 段，重传 $((x2 - x1)) 段 | 网卡队列丢包 $((d2 - d1)) | UDP 收/发缓冲错误 $((y2 - y1))/$((z2 - z1))"
    echo "   判断：队列丢包为 0 而重传高 → 路径/对端问题；UDP 缓冲错误增长 → 需要调大 UDP 缓冲"
    echo
    echo "提示：要测真实下载方向，请在国内设备上用 iperf3 或测速网站走代理测试"
}

# 备份当前 sysctl 配置与运行时的值（用于回滚）
tune_backup() {
    local dir k
    dir="${ONEKEY_DIR}/tune-backup/$(date +%Y%m%d%H%M%S)"
    mkdir -p "${dir}/sysctl.d"
    cp -a /etc/sysctl.d/. "${dir}/sysctl.d/" 2>/dev/null || true
    [[ -f /etc/sysctl.conf ]] && cp -a /etc/sysctl.conf "${dir}/"
    for k in ${TUNE_KEYS}; do echo "${k} = $(sysctl -n "${k}" 2>/dev/null | tr '\t' ' ')"; done >"${dir}/runtime.conf"
    echo "$(root_qdisc "$(default_iface)")" >"${dir}/qdisc"
    echo "${dir}"
}

do_tune() {
    local kmaj kmin rtt bw mem_mb bdp buf cap bak legacy dev
    kmaj=$(uname -r | cut -d. -f1); kmin=$(uname -r | cut -d. -f2)
    if (( kmaj < 4 || (kmaj == 4 && kmin < 9) )); then
        warn "内核 $(uname -r) 低于 4.9，不支持 BBR，已跳过网络调优"
        return 0
    fi
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr || { warn "内核未提供 BBR，已跳过"; return 0; }

    # ---- 测量 ----
    info "测量到国内的 RTT..."
    rtt=$(china_rtt); (( rtt > 0 )) || { rtt=200; warn "国内目标均不响应 ICMP，按 200ms 估算"; }
    bw=${BW_UP:-}
    if [[ -z "${bw}" ]]; then
        if [[ -f "${ENV_FILE}" ]]; then bw=$(. "${ENV_FILE}"; echo "${BW_UP:-}"); fi
    fi
    [[ -n "${bw}" ]] || { detect_bandwidth; bw=${BW_UP}; }
    mem_mb=$(free -m | awk '/Mem:/{print $2}')

    # ---- 计算 TCP 缓冲上限：2 × BDP，限制在 8MB~64MB，且不超过内存的 1/16 ----
    bdp=$(( bw * 1000000 / 8 * rtt / 1000 ))
    buf=$(( bdp * 2 ))
    cap=$(( mem_mb * 1024 * 1024 / 16 ))
    (( buf > 67108864 )) && buf=67108864
    (( buf > cap )) && buf=${cap}
    (( buf < 8388608 )) && buf=8388608
    buf=$(( (buf + 1048575) / 1048576 * 1048576 ))   # 取整到 MB

    echo
    echo "   测量依据：VPS 上行 ${bw} Mbps × 国内 RTT ${rtt} ms → BDP $((bdp / 1048576)) MB；内存 ${mem_mb} MB"
    echo "   计划写入 ${SYSCTL_FILE}："
    echo "     BBR + fq（并把网卡现有队列切换为 fq）"
    echo "     TCP 缓冲上限 $((buf / 1048576)) MB（原 tcp_wmem 上限 $(( $(sysctl -n net.ipv4.tcp_wmem | awk '{print $3}') / 1048576 )) MB）"
    echo "     UDP 缓冲 16 MB（Hysteria2 / QUIC）"
    echo "     tcp_notsent_lowat 128KB、tcp_slow_start_after_idle 0、tcp_mtu_probing 1"
    echo "   不修改：MTU、网卡限速（TBF/HTB）、netdev_max_backlog —— 无测量证据支持"
    if [[ -z "${ONEKEY_TUNE_YES:-}" ]]; then
        local yn
        read -rp "确认应用？会先备份，可通过「回滚网络调优」恢复 [Y/n] " yn
        [[ "${yn:-Y}" =~ ^[Yy]$ ]] || { warn "已取消"; return 0; }
    fi

    # ---- 备份并写入 ----
    bak=$(tune_backup)
    # 旧版脚本写入的同类文件会与本文件产生顺序冲突，移入备份目录
    for legacy in /etc/sysctl.d/99-surge-proxy.conf; do
        [[ -f "${legacy}" ]] && grep -q "QUIC 需要更大的 UDP 缓冲区" "${legacy}" && mv "${legacy}" "${bak}/moved-$(basename "${legacy}")"
    done
    echo "tcp_bbr" >/etc/modules-load.d/onekey-bbr.conf
    cat >"${SYSCTL_FILE}" <<EOF
# onekey 网络调优（落地机：用户 -> VPS -> 互联网；关键方向 VPS 出口 -> 用户下载）
# 生成时间：$(date '+%F %T')  依据：VPS 上行 ${bw} Mbps，国内 RTT ${rtt} ms，内存 ${mem_mb} MB
# 备份：${bak}

# BBR + fq：fq 为 BBR 提供 pacing 与流间公平
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 缓冲上限 = 2 × BDP（8~64MB，且不超过内存 1/16），影响 Snell 等 TCP 协议的单连接速度
net.ipv4.tcp_rmem = 4096 131072 ${buf}
net.ipv4.tcp_wmem = 4096 16384 ${buf}
# socket 缓冲上限；Hysteria2（QUIC）需要至少 16MB 的 UDP 缓冲
net.core.rmem_max = $(( buf > 16777216 ? buf : 16777216 ))
net.core.wmem_max = $(( buf > 16777216 ? buf : 16777216 ))

# 限制未发送数据在 socket 中堆积，降低大缓冲带来的排队延迟
net.ipv4.tcp_notsent_lowat = 131072
# 代理长连接空闲后不重新慢启动（Snell reuse=true）
net.ipv4.tcp_slow_start_after_idle = 0
# 仅在检测到 PMTU 黑洞时启用 MTU 探测（部分服务商丢弃 ICMP）
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl --system >/dev/null 2>&1 || true
    apply_fq

    # ---- 回读 ----
    echo "   生效值："
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
        net.core.rmem_max net.core.wmem_max net.ipv4.tcp_notsent_lowat net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_mtu_probing 2>/dev/null | sed 's/^/     /'

    cat >"${SYSCTL_FILE%.conf}.profile.md" <<EOF
# onekey 网络调优说明

- 时间：$(date '+%F %T')
- 角色：落地机（用户 -> VPS -> 互联网），关键方向：VPS 出口 -> 用户下载
- 协议：Hysteria2（UDP/QUIC）、Snell v5（TCP）
- 测量：VPS 上行 ${bw} Mbps（Cloudflare 测速，代表端口能力上限）；国内三网中位 RTT ${rtt} ms；内存 ${mem_mb} MB
- 选择：BBR + fq；TCP 缓冲上限 $((buf / 1048576)) MB（2 × BDP）；UDP 缓冲 ≥16MB；notsent_lowat 128KB；slow_start_after_idle 0；mtu_probing 1
- 未改动：MTU、TBF/HTB、netdev_max_backlog（无队列丢包等证据）
- 注意：TCP 缓冲只影响 Snell 等 TCP 协议；跨境路径丢包无法通过本机调参解决
- 备份：${bak}
- 回滚：bash install.sh tune-rollback
EOF
    ok "网络调优已应用，说明文件：${SYSCTL_FILE%.conf}.profile.md，备份：${bak}"
}

do_tune_rollback() {
    local base dir k v dev q
    base="${ONEKEY_DIR}/tune-backup"
    dir=$(ls -1d "${base}"/*/ 2>/dev/null | sort | head -1 || true)
    [[ -n "${dir}" ]] || die "没有找到网络调优备份"
    dir=${dir%/}
    echo "将恢复到最早的备份（调优前的原始状态）：${dir}"
    confirm "确认回滚？" || return 0
    rm -f "${SYSCTL_FILE}" "${SYSCTL_FILE%.conf}.profile.md" /etc/modules-load.d/onekey-bbr.conf
    cp -a "${dir}/sysctl.d/." /etc/sysctl.d/
    [[ -f "${dir}/sysctl.conf" ]] && cp -a "${dir}/sysctl.conf" /etc/sysctl.conf
    # sysctl --system 不会还原已删除的键，按备份的运行时值逐项恢复
    local line
    while IFS= read -r line; do
        k=${line%% = *}; v=${line#* = }
        [[ -n "${k}" && -n "${v}" ]] && { sysctl -w "${k}=${v}" >/dev/null 2>&1 || true; }
    done <"${dir}/runtime.conf"
    sysctl --system >/dev/null 2>&1 || true
    dev=$(default_iface); q=$(cat "${dir}/qdisc" 2>/dev/null || true)
    if [[ -n "${dev}" && -n "${q}" && "${q}" != "$(root_qdisc "${dev}")" && "${q}" != mq ]]; then
        tc qdisc replace dev "${dev}" root "${q}" 2>/dev/null || true
    fi
    ok "已回滚。当前：$(sysctl -n net.ipv4.tcp_congestion_control) + $(root_qdisc "${dev}")，tcp_wmem [$(sysctl -n net.ipv4.tcp_wmem | tr '\t' ' ')]"
}

# ============================================================
# 带宽检测
# ============================================================

# $1=down|up  输出 Mbps
measure_bw() {
    local dir=$1 dev stat a b i dur=10 threads=8
    dev=$(default_iface)
    [[ -n "${dev}" && -r "/sys/class/net/${dev}/statistics/rx_bytes" ]] || { echo 0; return; }
    [[ ${dir} == down ]] && stat=rx_bytes || stat=tx_bytes

    for ((i = 0; i < threads; i++)); do
        if [[ ${dir} == down ]]; then
            timeout 15 bash -c 'while :; do curl -s -o /dev/null -m 15 "https://speed.cloudflare.com/__down?bytes=50000000" || sleep 1; done' &
        else
            timeout 15 bash -c 'while :; do head -c 50000000 /dev/zero | curl -s -o /dev/null -m 15 -X POST --data-binary @- https://speed.cloudflare.com/__up || sleep 1; done' &
        fi
    done
    sleep 3
    a=$(<"/sys/class/net/${dev}/statistics/${stat}")
    sleep ${dur}
    b=$(<"/sys/class/net/${dev}/statistics/${stat}")
    wait || true
    echo $(( (b - a) * 8 / dur / 1000000 ))
}

detect_bandwidth() {
    info "正在检测 VPS 带宽（Cloudflare 测速，约 40 秒）..."
    BW_DOWN=$(measure_bw down)
    BW_UP=$(measure_bw up)
    # 取整到 10 Mbps
    BW_DOWN=$(( BW_DOWN / 10 * 10 )); BW_UP=$(( BW_UP / 10 * 10 ))
    if (( BW_UP < 10 || BW_DOWN < 10 )); then
        warn "带宽检测失败（下行 ${BW_DOWN} / 上行 ${BW_UP} Mbps），使用默认值 100 Mbps"
        (( BW_UP < 10 )) && BW_UP=100
        (( BW_DOWN < 10 )) && BW_DOWN=100
    fi
    ok "VPS 带宽：下行 ${BW_DOWN} Mbps / 上行 ${BW_UP} Mbps"
    echo "   说明：VPS 上行 = 你的下载速度上限，VPS 下行 = 你的上传速度上限"
}

ask_client_down() {
    local def=$(( BW_UP < 500 ? BW_UP : 500 ))
    echo
    echo "Surge 的 download-bandwidth 应填「你本地宽带的下行带宽」，且不高于 VPS 上行 ${BW_UP} Mbps。"
    echo "跨境线路丢包严重时填高了反而更慢，建议先保守再逐步调高。"
    read -rp "你本地的下行带宽 Mbps（默认 ${def}）：" CLIENT_DOWN
    CLIENT_DOWN=${CLIENT_DOWN:-${def}}
    [[ "${CLIENT_DOWN}" =~ ^[0-9]+$ ]] || die "请输入数字"
    (( CLIENT_DOWN > BW_UP )) && { warn "超过 VPS 上行，已调整为 ${BW_UP}"; CLIENT_DOWN=${BW_UP}; }
    return 0
}

do_bandwidth() {
    load_env
    detect_bandwidth
    ask_client_down
    save_env
    write_hy2_conf
    systemctl restart hysteria-server.service
    write_info
    ok "带宽已更新，Hysteria2 已重启。请把 Surge 中 download-bandwidth 改为 ${CLIENT_DOWN}"
}

# ============================================================
# 域名解析 / 证书
# ============================================================

detect_ips() {
    SERVER_IP4=$(curl -s4m8 https://api.ipify.org || true)
    SERVER_IP6=$(curl -s6m8 https://api6.ipify.org || true)
    echo "本机 IPv4：${SERVER_IP4:-无}"
    echo "本机 IPv6：${SERVER_IP6:-无}"
    [[ -n "${SERVER_IP4}${SERVER_IP6}" ]] || die "无法获取本机公网 IP"
}

# 通过 DoH 查询公共 DNS，避免本机 DNS 缓存导致误判。$1=A|AAAA  $2=domain
doh_query() {
    local out re='^[0-9.]+$'
    [[ $1 == AAAA ]] && re=':'
    if out=$(curl -s -m 8 -H 'accept: application/dns-json' \
            "https://cloudflare-dns.com/dns-query?name=$2&type=$1" 2>/dev/null) && [[ -n "${out}" ]]; then
        echo "${out}" | grep -oE '"data":"[^"]*"' | cut -d'"' -f4 | grep -E "${re}" | tail -1 || true
    else
        resolve "$1" "$2" || true
    fi
}

# 返回 0 表示解析正确，并打印当前解析结果
check_dns() {
    local a4 a6
    a4=$(doh_query A "${DOMAIN}"); a6=$(doh_query AAAA "${DOMAIN}")
    echo "   当前解析：A=${a4:-无}  AAAA=${a6:-无}"
    [[ -n "${a4}${a6}" ]] || return 1
    # Let's Encrypt 有 AAAA 记录时优先走 IPv6 验证，所以 AAAA 如果存在必须正确
    [[ -z "${a6}" || "${a6}" == "${SERVER_IP6}" ]] || return 1
    [[ -z "${a4}" || "${a4}" == "${SERVER_IP4}" ]] || return 1
    # 本机有 IPv4 时必须有 A 记录（客户端默认走 IPv4）
    [[ -z "${SERVER_IP4}" || -n "${a4}" ]] || return 1
    return 0
}

cf_api() {
    # $1=METHOD $2=PATH [$3=JSON]
    curl -s -m 15 -X "$1" "https://api.cloudflare.com/client/v4$2" \
        -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" ${3:+--data "$3"}
}

cf_zone_id() {
    local d=${DOMAIN} zid
    while [[ "${d}" == *.* ]]; do
        zid=$(cf_api GET "/zones?name=${d}" | jq -r '.result[0].id // empty' 2>/dev/null || true)
        [[ -n "${zid}" ]] && { echo "${zid}"; return 0; }
        d=${d#*.}
    done
    return 1
}

# $1=zone_id $2=A|AAAA $3=ip
cf_upsert() {
    local rid data res
    rid=$(cf_api GET "/zones/$1/dns_records?type=$2&name=${DOMAIN}" | jq -r '.result[0].id // empty' 2>/dev/null || true)
    data=$(jq -nc --arg t "$2" --arg n "${DOMAIN}" --arg c "$3" '{type:$t,name:$n,content:$c,ttl:120,proxied:false}')
    if [[ -n "${rid}" ]]; then
        res=$(cf_api PUT "/zones/$1/dns_records/${rid}" "${data}")
    else
        res=$(cf_api POST "/zones/$1/dns_records" "${data}")
    fi
    if [[ "$(echo "${res}" | jq -r '.success' 2>/dev/null)" == "true" ]]; then
        ok "Cloudflare：$2 ${DOMAIN} -> $3（仅 DNS）"
    else
        warn "Cloudflare：$2 记录设置失败：$(echo "${res}" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null)"
        return 1
    fi
}

cf_setup_records() {
    command -v jq >/dev/null || { warn "缺少 jq，无法使用 Cloudflare API"; return 1; }
    echo "需要一个 Cloudflare API Token，权限：Zone → DNS → Edit，Zone → Zone → Read"
    echo "创建地址：https://dash.cloudflare.com/profile/api-tokens（可用「Edit zone DNS」模板）"
    read -rsp "请输入 Cloudflare API Token（输入不显示）：" CF_TOKEN; echo
    [[ -n "${CF_TOKEN}" ]] || return 1
    local zid
    if ! zid=$(cf_zone_id); then
        warn "找不到 ${DOMAIN} 所在的 Cloudflare 区域，请检查 Token 权限和域名"
        CF_TOKEN=""
        return 1
    fi
    ok "找到 Cloudflare 区域"
    if [[ -n "${SERVER_IP4}" ]]; then cf_upsert "${zid}" A "${SERVER_IP4}" || return 1; fi
    if [[ -n "${SERVER_IP6}" ]]; then cf_upsert "${zid}" AAAA "${SERVER_IP6}" || return 1; fi
    return 0
}

# 等待解析生效；返回 0=继续 1=重新输入域名
wait_dns() {
    local i n
    while true; do
        info "检查 ${DOMAIN} 解析（每 10 秒一次，最长 5 分钟）..."
        for i in $(seq 1 30); do
            if check_dns; then ok "域名解析已生效"; return 0; fi
            sleep 10
        done
        warn "解析仍未生效或与本机 IP 不一致"
        echo "  1. 继续等待   2. 重新输入域名   3. 忽略并继续（证书申请可能失败）"
        read -rp "请选择（默认 1）：" n
        case "${n:-1}" in
            2) return 1 ;;
            3) return 0 ;;
            *) ;;
        esac
    done
}

# 交互式设置域名：输入域名 -> 添加解析（手动 / Cloudflare 自动）-> 等待生效 -> 选择证书验证方式
setup_domain() {
    local n def
    CF_TOKEN=${CF_TOKEN:-}
    while true; do
        echo
        read -rp "请输入域名（如 hy.example.com）：" DOMAIN
        DOMAIN=$(echo "${DOMAIN}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
        if ! [[ "${DOMAIN}" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
            warn "域名格式不正确"; continue
        fi

        echo
        echo "需要的解析记录（Cloudflare 必须关闭小黄云，设为「仅 DNS」）："
        [[ -n "${SERVER_IP4}" ]] && echo "   A     ${DOMAIN}  ->  ${SERVER_IP4}"
        [[ -n "${SERVER_IP6}" ]] && echo "   AAAA  ${DOMAIN}  ->  ${SERVER_IP6}"
        echo
        if check_dns; then
            ok "解析已正确，无需修改"
        else
            echo "  1. 我自己去 DNS 后台添加（添加后脚本自动检测）"
            echo "  2. 使用 Cloudflare API Token 自动添加"
            read -rp "请选择（默认 1）：" n
            if [[ "${n}" == 2 ]]; then
                cf_setup_records || warn "自动添加失败，请手动添加上面的记录"
            else
                read -rp "添加完成后按回车开始检测..." _
            fi
            wait_dns || continue
        fi
        break
    done

    # 证书验证方式
    def=1; [[ -n "${CF_TOKEN}" ]] && def=2
    echo
    echo "证书申请方式（Let's Encrypt，到期前自动续期）："
    echo "  1. HTTP 验证（需要 80 端口空闲并对外开放）"
    echo "  2. DNS 验证（仅限 Cloudflare 托管的域名，不需要 80 端口）"
    read -rp "请选择（默认 ${def}）：" n
    n=${n:-${def}}
    if [[ "${n}" == 2 ]]; then
        if [[ -z "${CF_TOKEN}" ]]; then
            read -rsp "请输入 Cloudflare API Token（输入不显示）：" CF_TOKEN; echo
        fi
        [[ -n "${CF_TOKEN}" ]] || die "Token 不能为空"
        ACME_TYPE="dns"
    else
        ACME_TYPE="http"; CF_TOKEN=""
        # 允许 80 端口被 Hysteria 自己占用（续期时），其余占用则无法 HTTP 验证
        if port_in_use tcp 80 && ! ss -lntp 2>/dev/null | grep -E '[:.]80 ' | grep -q hysteria; then
            die "TCP 80 被占用，无法 HTTP 验证。请停止占用 80 端口的服务（如 Nginx），或选择 DNS 验证"
        fi
    fi
    ok "域名：${DOMAIN}，证书验证方式：${ACME_TYPE^^}"
}

cert_file() {
    local home
    home=$(getent passwd hysteria | cut -d: -f6 || true)
    find /var/lib/hysteria /etc/hysteria ${home:+"${home}"} -name "${DOMAIN}.crt" -path '*certificates*' 2>/dev/null | head -1 || true
}

cert_status() {
    local f end days
    f=$(cert_file)
    if [[ -z "${f}" ]]; then
        warn "未找到 ${DOMAIN} 的证书"
        return 1
    fi
    end=$(openssl x509 -in "${f}" -noout -enddate | cut -d= -f2)
    days=$(( ( $(date -d "${end}" +%s) - $(date +%s) ) / 86400 ))
    echo "   域名：${DOMAIN}"
    echo "   签发：$(openssl x509 -in "${f}" -noout -issuer | sed 's/^issuer=//')"
    echo "   到期：${end}（剩余 ${days} 天，到期前自动续期）"
    echo "   方式：${ACME_TYPE^^} 验证"
}

# 重启 Hysteria2 并等待证书就绪
restart_and_wait_cert() {
    local since i log
    since=$(date '+%F %T')
    systemctl restart hysteria-server.service
    info "正在申请/加载证书（最长 2 分钟）..."
    for i in $(seq 1 60); do
        log=$(journalctl -u hysteria-server --since "${since}" --no-pager 2>/dev/null || true)
        if echo "${log}" | grep -q "server up and running"; then
            ok "证书就绪，Hysteria2 已启动"
            cert_status || true
            return 0
        fi
        if echo "${log}" | grep -qiE "fatal|failed to (load|obtain)"; then
            break
        fi
        sleep 2
    done
    warn "证书申请失败或超时，最近日志："
    journalctl -u hysteria-server --since "${since}" --no-pager 2>/dev/null | tail -8 || true
    echo "常见原因：解析未生效 / 80 端口未开放（HTTP 验证）/ Token 权限不足（DNS 验证）/ 申请过于频繁被限流"
    return 1
}

do_domain() {
    load_env
    local n old f
    echo
    echo "  1. 查看证书状态"
    echo "  2. 更换域名并申请证书"
    echo "  3. 强制重新申请证书"
    read -rp "请选择：" n
    case "${n}" in
        1) cert_status || true ;;
        2)
            old=${DOMAIN}
            detect_ips
            setup_domain
            save_env
            write_hy2_conf
            if [[ "${ACME_TYPE}" == http ]]; then OPEN_80_ONLY=1 open_firewall || true; fi
            restart_and_wait_cert || true
            write_info
            ok "域名已从 ${old} 更换为 ${DOMAIN}"
            warn "客户端配置中的域名 / sni 已变化，请通过菜单「查看客户端配置」重新导入"
            ;;
        3)
            confirm "将删除 ${DOMAIN} 的现有证书并重新申请，确定？" || return 0
            f=$(cert_file)
            [[ -n "${f}" ]] && rm -rf "$(dirname "${f}")"
            restart_and_wait_cert || true
            ;;
        *) warn "无效选项" ;;
    esac
}

# ============================================================
# 交互输入
# ============================================================

read_inputs() {
    detect_ips
    setup_domain

    echo
    read -rp "Hysteria2 监听 UDP 端口（默认 443）：" HY2_PORT
    HY2_PORT=${HY2_PORT:-443}
    is_port "${HY2_PORT}" || die "端口无效"
    port_in_use udp "${HY2_PORT}" && die "UDP ${HY2_PORT} 已被占用"

    local yn
    read -rp "启用端口跳跃？[Y/n] " yn
    HOP_RANGE=""; HOP_INTERVAL="30"
    if [[ "${yn:-Y}" =~ ^[Yy]$ ]]; then
        read -rp "跳跃端口范围（默认 20000-50000）：" HOP_RANGE
        HOP_RANGE=${HOP_RANGE:-20000-50000}
        [[ "${HOP_RANGE}" =~ ^[0-9]+-[0-9]+$ ]] || die "端口范围格式错误，应为 起始-结束"
        read -rp "跳跃间隔秒数（默认 30）：" HOP_INTERVAL
        HOP_INTERVAL=${HOP_INTERVAL:-30}
    fi

    OBFS_PASS=""
    if confirm "启用 Salamander 混淆？（需较新版 Surge，启用后伪装网站失效，默认否）"; then
        OBFS_PASS=$(rand_str 24)
    fi

    MASQ_URL=""
    if [[ -z "${OBFS_PASS}" ]]; then
        read -rp "伪装网站（默认 https://www.bing.com/）：" MASQ_URL
        MASQ_URL=${MASQ_URL:-https://www.bing.com/}
    fi

    read -rp "Snell TCP 端口（默认随机 10000-19999）：" SNELL_PORT
    SNELL_PORT=${SNELL_PORT:-$((RANDOM % 10000 + 10000))}
    is_port "${SNELL_PORT}" || die "端口无效"
    port_in_use tcp "${SNELL_PORT}" && die "TCP ${SNELL_PORT} 已被占用"

    local def_name
    def_name=$(echo "${DOMAIN%%.*}" | tr '[:lower:]' '[:upper:]')
    read -rp "节点名称，可带国旗 emoji，如 🇺🇸 US（默认 ${def_name}）：" NODE_NAME
    NODE_NAME=${NODE_NAME:-${def_name}}
    NODE_NAME=${NODE_NAME//\"/}

    HY2_PASS=$(rand_str 24)
    SNELL_PSK=$(rand_str 32)
    return 0
}

open_firewall() {
    # 只放行端口，不关闭防火墙
    local p
    local tcp_ports=() udp_ports=()
    [[ "${ACME_TYPE:-http}" == http ]] && tcp_ports+=(80)
    if [[ -z "${OPEN_80_ONLY:-}" ]]; then
        tcp_ports+=("${SNELL_PORT}"); udp_ports+=("${HY2_PORT}" "${SNELL_PORT}")
        [[ -n "${HOP_RANGE}" ]] && udp_ports+=("${HOP_RANGE}")
    fi
    (( ${#tcp_ports[@]} + ${#udp_ports[@]} > 0 )) || return 0
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        for p in "${tcp_ports[@]+"${tcp_ports[@]}"}"; do ufw allow "${p/-/:}/tcp" >/dev/null; done
        for p in "${udp_ports[@]+"${udp_ports[@]}"}"; do ufw allow "${p/-/:}/udp" >/dev/null; done
        ok "ufw 已放行端口"
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        for p in "${tcp_ports[@]+"${tcp_ports[@]}"}"; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null; done
        for p in "${udp_ports[@]+"${udp_ports[@]}"}"; do firewall-cmd --permanent --add-port="${p}/udp" >/dev/null; done
        firewall-cmd --reload >/dev/null
        ok "firewalld 已放行端口"
    fi
    [[ -n "${OPEN_80_ONLY:-}" ]] && return 0
    local p80=""; [[ "${ACME_TYPE:-http}" == http ]] && p80="80/tcp、"
    warn "云服务商安全组请放行（IPv4/IPv6 都要）：${p80}${HY2_PORT}/udp、${SNELL_PORT}/tcp+udp${HOP_RANGE:+、${HOP_RANGE}/udp}"
}

# ============================================================
# 端口跳跃
# ============================================================

setup_port_hopping() {
    [[ -n "${HOP_RANGE}" ]] || return 0

    cat >"${HOP_SCRIPT}" <<EOF
#!/usr/bin/env bash
# Hysteria2 端口跳跃：把 UDP ${HOP_RANGE} 重定向到 ${HY2_PORT}（IPv4 + IPv6）
RANGE="${HOP_RANGE/-/:}"
TARGET="${HY2_PORT}"
CHAIN="HY2_PORTHOP"

apply() {
    local ipt=\$1 iface=\$2
    \$ipt -t nat -N \$CHAIN 2>/dev/null || \$ipt -t nat -F \$CHAIN
    \$ipt -t nat -A \$CHAIN -p udp --dport \$RANGE -j REDIRECT --to-ports \$TARGET
    \$ipt -t nat -C PREROUTING -i "\$iface" -j \$CHAIN 2>/dev/null \\
        || \$ipt -t nat -A PREROUTING -i "\$iface" -j \$CHAIN
}

remove() {
    local ipt=\$1
    while read -r iface; do
        \$ipt -t nat -D PREROUTING -i "\$iface" -j \$CHAIN 2>/dev/null
    done < <(\$ipt -t nat -S PREROUTING 2>/dev/null | awk -v c="\$CHAIN" '\$0 ~ "-j "c"\$" {for(i=1;i<=NF;i++) if(\$i=="-i") print \$(i+1)}')
    \$ipt -t nat -F \$CHAIN 2>/dev/null
    \$ipt -t nat -X \$CHAIN 2>/dev/null
}

IF4=\$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") {print \$(i+1); exit}}')
IF6=\$(ip -6 route show default | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") {print \$(i+1); exit}}')

case "\$1" in
    start)
        [[ -n "\$IF4" ]] && apply iptables "\$IF4"
        [[ -n "\$IF6" ]] && { apply ip6tables "\$IF6" || echo "ip6tables NAT 不可用，IPv6 端口跳跃未生效" >&2; }
        ;;
    stop)
        remove iptables
        remove ip6tables
        ;;
esac
exit 0
EOF
    chmod 755 "${HOP_SCRIPT}"

    cat >"${HOP_SERVICE}" <<EOF
[Unit]
Description=Hysteria2 UDP port hopping rules
After=network-online.target
Wants=network-online.target
Before=hysteria-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HOP_SCRIPT} start
ExecStop=${HOP_SCRIPT} stop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hy2-porthop.service >/dev/null 2>&1
    systemctl restart hy2-porthop.service
    if iptables -t nat -S HY2_PORTHOP >/dev/null 2>&1; then
        ok "端口跳跃已启用：UDP ${HOP_RANGE} -> ${HY2_PORT}"
    else
        warn "端口跳跃规则未生效，请检查 iptables"
    fi
    if [[ -n "${SERVER_IP6}" ]] && ! ip6tables -t nat -S HY2_PORTHOP >/dev/null 2>&1; then
        warn "IPv6 端口跳跃未生效（内核可能不支持 ip6tables NAT）"
    fi
}

# ============================================================
# Hysteria2
# ============================================================

write_hy2_conf() {
    {
        echo "listen: :${HY2_PORT}"
        echo
        echo "acme:"
        echo "  domains:"
        echo "    - ${DOMAIN}"
        echo "  email: admin@${DOMAIN}"
        echo "  ca: letsencrypt"
        if [[ "${ACME_TYPE:-http}" == dns ]]; then
            echo "  type: dns"
            echo "  dns:"
            echo "    name: cloudflare"
            echo "    config:"
            echo "      cloudflare_api_token: ${CF_TOKEN}"
        else
            echo "  type: http"
        fi
        echo
        echo "auth:"
        echo "  type: password"
        echo "  password: ${HY2_PASS}"
        echo
        echo "# 服务端视角：up = 客户端下载上限，down = 客户端上传上限（自动检测）"
        echo "bandwidth:"
        echo "  up: ${BW_UP} mbps"
        echo "  down: ${BW_DOWN} mbps"
        echo
        if [[ -n "${OBFS_PASS}" ]]; then
            echo "obfs:"
            echo "  type: salamander"
            echo "  salamander:"
            echo "    password: ${OBFS_PASS}"
        else
            echo "masquerade:"
            echo "  type: proxy"
            echo "  proxy:"
            echo "    url: ${MASQ_URL}"
            echo "    rewriteHost: true"
        fi
    } >"${HY2_CONF}"
    chmod 640 "${HY2_CONF}"
    chown root:hysteria "${HY2_CONF}" 2>/dev/null || true
}

install_hysteria() {
    info "安装 Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1
    command -v hysteria >/dev/null || die "Hysteria2 安装失败"
    write_hy2_conf
    systemctl enable hysteria-server.service >/dev/null 2>&1
    restart_and_wait_cert || warn "可稍后通过菜单「域名与证书」重新申请"
}

# ============================================================
# Snell
# ============================================================

download_snell() {
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL -o "${tmp}/snell.zip" \
        "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${SNELL_ARCH}.zip" \
        || { rm -rf "${tmp}"; die "Snell 下载失败"; }
    unzip -o -q "${tmp}/snell.zip" -d "${tmp}"
    install -m 755 "${tmp}/snell-server" "${SNELL_BIN}"
    rm -rf "${tmp}"
}

install_snell() {
    info "安装 Snell ${SNELL_VERSION}..."
    download_snell

    id snell >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin snell
    mkdir -p "${SNELL_DIR}"
    cat >"${SNELL_CONF}" <<EOF
[snell-server]
listen = ::0:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = true
EOF
    chown -R root:snell "${SNELL_DIR}"
    chmod 640 "${SNELL_CONF}"

    cat >"${SNELL_SERVICE}" <<EOF
[Unit]
Description=Snell Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=snell
Group=snell
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=${SNELL_BIN} -c ${SNELL_CONF}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable snell.service >/dev/null 2>&1
    systemctl restart snell.service
    sleep 1
    if systemctl is-active --quiet snell.service; then
        ok "Snell ${SNELL_VERSION} 已启动"
    else
        warn "Snell 启动失败，请执行 journalctl -u snell -e 查看日志"
    fi
}

# ============================================================
# 客户端配置输出
# ============================================================

urlencode() { local s=$1 o="" c i; for ((i = 0; i < ${#s}; i++)); do c=${s:i:1}; case "$c" in [a-zA-Z0-9.~_-]) o+="$c" ;; *) o+=$(printf '%%%02X' "'$c") ;; esac; done; echo "$o"; }

write_info() {
    local hy2="hysteria2, ${DOMAIN}, ${HY2_PORT}, password=${HY2_PASS}, sni=${DOMAIN}, download-bandwidth=${CLIENT_DOWN}"
    [[ -n "${HOP_RANGE}" ]] && hy2+=", port-hopping=\"${HOP_RANGE}\", port-hopping-interval=${HOP_INTERVAL}"
    [[ -n "${OBFS_PASS}" ]] && hy2+=", salamander-password=${OBFS_PASS}"
    local snell="snell, ${DOMAIN}, ${SNELL_PORT}, psk=${SNELL_PSK}, version=5, reuse=true"

    local q="sni=${DOMAIN}&peer=${DOMAIN}&insecure=0"
    [[ -n "${HOP_RANGE}" ]] && q+="&mport=${HOP_RANGE}"
    if [[ -n "${OBFS_PASS}" ]]; then q+="&obfs=salamander&obfs-password=${OBFS_PASS}"; else q+="&obfs=none"; fi
    SR_V4=""; SR_V6=""
    [[ -n "${SERVER_IP4}" ]] && SR_V4="hysteria2://${HY2_PASS}@${SERVER_IP4}:${HY2_PORT}?${q}#$(urlencode "HY2-IPv4")"
    [[ -n "${SERVER_IP6}" ]] && SR_V6="hysteria2://${HY2_PASS}@[${SERVER_IP6}]:${HY2_PORT}?${q}#$(urlencode "HY2-IPv6")"

    {
        echo "#################### Surge ####################"
        echo "# 生成时间：$(date '+%F %T')"
        echo "# VPS 带宽：下行 ${BW_DOWN} Mbps / 上行 ${BW_UP} Mbps"
        echo "# 使用 IPv6 线路需在 [General] 中设置 ipv6 = true"
        echo
        echo "[Proxy]"
        if [[ -n "${SERVER_IP4}" ]]; then
            echo "${NODE_NAME} HY2 = ${hy2}, ip-version=v4-only"
            echo "${NODE_NAME} Snell = ${snell}, ip-version=v4-only"
        fi
        if [[ -n "${SERVER_IP6}" ]]; then
            echo "${NODE_NAME} HY2 v6 = ${hy2}, ip-version=v6-only"
            echo "${NODE_NAME} Snell v6 = ${snell}, ip-version=v6-only"
        fi
        echo
        echo "[Proxy Group]"
        echo "# 把下面的组名加入你的 Proxy 选择组；组内 Hysteria2 优先，UDP 不通时自动回落 Snell"
        [[ -n "${SERVER_IP4}" ]] && echo "${NODE_NAME} = fallback, \"${NODE_NAME} HY2\", \"${NODE_NAME} Snell\", interval=300, timeout=5"
        [[ -n "${SERVER_IP6}" ]] && echo "${NODE_NAME} IPv6 = fallback, \"${NODE_NAME} HY2 v6\", \"${NODE_NAME} Snell v6\", interval=300, timeout=5"
        echo
        echo "################# Shadowrocket #################"
        echo "# Shadowrocket 不支持 Snell v5，仅提供 Hysteria2"
        [[ -n "${SR_V4}" ]] && { echo "# IPv4"; echo "${SR_V4}"; }
        [[ -n "${SR_V6}" ]] && { echo "# IPv6"; echo "${SR_V6}"; }
    } >"${INFO_FILE}"
    chmod 600 "${INFO_FILE}"
}

show_info() {
    load_env
    NODE_NAME=${NODE_NAME:-VPS}
    write_info
    echo
    cat "${INFO_FILE}"
    if command -v qrencode >/dev/null; then
        [[ -n "${SR_V4}" ]] && { echo; echo "Shadowrocket 扫码（IPv4）："; qrencode -t ANSIUTF8 "${SR_V4}"; }
        [[ -n "${SR_V6}" ]] && { echo; echo "Shadowrocket 扫码（IPv6）："; qrencode -t ANSIUTF8 "${SR_V6}"; }
    fi
    echo
    echo "提示："
    echo "  - 设置了 port-hopping 后，Surge 会忽略主端口，在跳跃范围内轮换"
    echo "  - 本地网络是否有 IPv6 可在 https://test-ipv6.com 检测"
    echo "  - 以上内容保存在：${INFO_FILE}，请勿公开分享"
}

# ============================================================
# SSH：修改端口 / 仅密钥登录
# ============================================================

sshd_bin() { command -v sshd || echo /usr/sbin/sshd; }

ssh_current_ports() { "$(sshd_bin)" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | xargs; }

# 在 sshd_config 顶部写入/替换一个标记块（sshd 对多数配置项采用"首次出现生效"）
# $1=块名  其余参数=配置行
ssh_set_block() {
    local name=$1; shift
    local tmp
    sed -i "/^# >>> onekey-${name}\$/,/^# <<< onekey-${name}\$/d" "${SSHD_CONF}"
    if (( $# > 0 )); then
        tmp=$(mktemp)
        { echo "# >>> onekey-${name}"; printf '%s\n' "$@"; echo "# <<< onekey-${name}"; cat "${SSHD_CONF}"; } >"${tmp}"
        cat "${tmp}" >"${SSHD_CONF}"
        rm -f "${tmp}"
    fi
}

ssh_backup() {
    local bak="${SSHD_CONF}.onekey.$(date +%Y%m%d%H%M%S)"
    cp -a "${SSHD_CONF}" "${bak}"
    mkdir -p "${ONEKEY_DIR}/sshd_config.d.bak"
    cp -a /etc/ssh/sshd_config.d/. "${ONEKEY_DIR}/sshd_config.d.bak/" 2>/dev/null || true
    echo "${bak}"
}

ssh_restore() {
    cp -a "$1" "${SSHD_CONF}"
    cp -a "${ONEKEY_DIR}/sshd_config.d.bak/." /etc/ssh/sshd_config.d/ 2>/dev/null || true
    warn "已恢复 SSH 配置备份"
}

ssh_apply() {
    # 端口变化需要 restart；Ubuntu 22.10+ 使用 ssh.socket 监听，需要 daemon-reload 后重启 socket
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl daemon-reload
        systemctl restart ssh.socket
        systemctl restart ssh.service 2>/dev/null || true
    elif systemctl list-unit-files sshd.service >/dev/null 2>&1 && systemctl is-enabled sshd.service >/dev/null 2>&1; then
        systemctl restart sshd.service
    else
        systemctl restart ssh.service
    fi
}

ssh_firewall_allow() {
    local p=$1
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${p}/tcp" >/dev/null && ok "ufw 已放行 ${p}/tcp"
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null && firewall-cmd --reload >/dev/null && ok "firewalld 已放行 ${p}/tcp"
    fi
    if command -v getenforce >/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
        if command -v semanage >/dev/null; then
            semanage port -a -t ssh_port_t -p tcp "${p}" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "${p}" 2>/dev/null || true
            ok "SELinux 已允许 SSH 使用端口 ${p}"
        else
            warn "SELinux 处于 Enforcing 但未安装 semanage，请先安装 policycoreutils-python-utils"
            return 1
        fi
    fi
}

do_ssh_port() {
    local cur new bak p
    cur=$(ssh_current_ports)
    echo "当前 SSH 端口：${cur:-22}"
    read -rp "请输入新的 SSH 端口（建议 10000-65535）：" new
    is_port "${new}" || die "端口无效"
    [[ " ${cur} " == *" ${new} "* ]] && die "新端口与当前端口相同"
    port_in_use tcp "${new}" && die "TCP ${new} 已被占用"

    bak=$(ssh_backup)
    ssh_firewall_allow "${new}" || die "请处理 SELinux 后重试"

    # 注释掉所有已有 Port 行，由顶部标记块统一管理；过渡期新旧端口同时监听
    sed -i -E 's/^([[:space:]]*[Pp]ort[[:space:]]+[0-9]+)/#\1/' "${SSHD_CONF}"
    sed -i -E 's/^([[:space:]]*[Pp]ort[[:space:]]+[0-9]+)/#\1/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
    local lines=()
    for p in ${cur:-22}; do lines+=("Port ${p}"); done
    lines+=("Port ${new}")
    ssh_set_block port "${lines[@]}"

    if ! "$(sshd_bin)" -t 2>/dev/null; then
        ssh_restore "${bak}"; die "SSH 配置校验失败，已回滚"
    fi
    ssh_apply
    sleep 1
    if ! port_in_use tcp "${new}"; then
        ssh_restore "${bak}"; ssh_apply; die "SSH 未能监听新端口 ${new}，已回滚"
    fi
    ok "SSH 已同时监听：${cur:-22} 和 ${new}"
    echo
    warn "请不要关闭当前窗口！新开一个终端测试：ssh -p ${new} root@${SERVER_IP4:-你的IP}"
    warn "同时确认云服务商安全组已放行 ${new}/tcp"
    if confirm "新端口登录成功了吗？输入 y 关闭旧端口 ${cur:-22}（输入 n 保留新旧两个端口）"; then
        ssh_set_block port "Port ${new}"
        "$(sshd_bin)" -t || { ssh_restore "${bak}"; ssh_apply; die "配置校验失败，已回滚"; }
        ssh_apply
        ok "SSH 端口已改为 ${new}，旧端口已关闭"
    else
        warn "已保留新旧两个端口。确认没问题后可再次运行本选项关闭旧端口"
    fi
}

do_ssh_key() {
    local user home ak key n bak kbd
    read -rp "要设置密钥登录的用户（默认 root）：" user
    user=${user:-root}
    id "${user}" >/dev/null 2>&1 || die "用户 ${user} 不存在"
    home=$(getent passwd "${user}" | cut -d: -f6)
    ak="${home}/.ssh/authorized_keys"
    install -d -m 700 -o "${user}" -g "$(id -gn "${user}")" "${home}/.ssh"
    touch "${ak}"; chmod 600 "${ak}"; chown "${user}:$(id -gn "${user}")" "${ak}"

    echo
    echo "当前已授权的公钥数量：$(grep -cE '^(ssh-|ecdsa-|sk-)' "${ak}" || true)"
    echo "  1. 粘贴我自己的公钥（推荐，私钥只在你的电脑上）"
    echo "  2. 在服务器上生成新密钥对（会显示私钥，请立即保存）"
    echo "  3. 使用已有的公钥（authorized_keys 中已有公钥时）"
    read -rp "请选择：" n
    case "${n}" in
        1)
            read -rp "粘贴公钥（ssh-ed25519 / ssh-rsa 开头的一整行）：" key
            echo "${key}" | ssh-keygen -l -f - >/dev/null 2>&1 || die "公钥格式无效"
            grep -qxF "${key}" "${ak}" || echo "${key}" >>"${ak}"
            ok "公钥已添加"
            ;;
        2)
            local tmpk
            tmpk=$(mktemp -u)
            ssh-keygen -q -t ed25519 -N "" -C "${user}@$(hostname)-onekey" -f "${tmpk}"
            cat "${tmpk}.pub" >>"${ak}"
            echo
            warn "=========== 私钥（请完整复制保存为文件，如 id_ed25519）==========="
            cat "${tmpk}"
            warn "================================================================="
            echo "本地使用前请设置权限：chmod 600 id_ed25519；登录：ssh -i id_ed25519 -p 端口 ${user}@服务器"
            shred -u "${tmpk}" 2>/dev/null || rm -f "${tmpk}"
            rm -f "${tmpk}.pub"
            read -rp "已保存私钥后按回车继续..." _
            ;;
        3)
            grep -qE '^(ssh-|ecdsa-|sk-)' "${ak}" || die "authorized_keys 中没有公钥"
            ;;
        *) die "无效选项" ;;
    esac

    echo
    warn "请不要关闭当前窗口！新开一个终端，确认用密钥可以登录 ${user}。"
    confirm "已确认密钥登录成功，现在禁用密码登录？" || { warn "已取消，密码登录保持不变"; return 0; }

    bak=$(ssh_backup)
    kbd="KbdInteractiveAuthentication no"
    "$(sshd_bin)" -T 2>/dev/null | grep -q '^kbdinteractiveauthentication' || kbd="ChallengeResponseAuthentication no"
    ssh_set_block keyonly \
        "PubkeyAuthentication yes" \
        "PasswordAuthentication no" \
        "${kbd}" \
        "PermitRootLogin prohibit-password"
    if ! "$(sshd_bin)" -t 2>/dev/null; then
        ssh_restore "${bak}"; die "SSH 配置校验失败，已回滚"
    fi
    systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service 2>/dev/null || ssh_apply
    echo
    "$(sshd_bin)" -T 2>/dev/null | grep -E '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin) ' || true
    ok "已禁用密码登录，仅允许密钥登录"
}

# ============================================================
# 安装 / 更新 / 卸载
# ============================================================

do_install() {
    if [[ -f "${ENV_FILE}" ]]; then
        warn "检测到已安装。重新安装会生成新的密码，旧的客户端配置将失效"
        confirm "确定重新安装？" || exit 0
    fi
    check_system
    check_arch
    install_deps
    read_inputs
    detect_bandwidth
    ask_client_down
    do_tune
    open_firewall
    setup_port_hopping
    install_hysteria
    install_snell
    save_env
    show_info
}

do_update() {
    check_arch
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1
    systemctl restart hysteria-server.service
    ok "Hysteria2 已更新：$(hysteria version 2>/dev/null | grep -m1 Version | awk '{print $2}' || true)"
    if [[ -f "${SNELL_CONF}" ]]; then
        download_snell
        systemctl restart snell.service
        ok "Snell 已更新至 ${SNELL_VERSION}"
    fi
}

do_uninstall() {
    confirm "确认卸载 Hysteria2、Snell 和端口跳跃规则？（SSH 设置与网络调优保持不变，调优可单独回滚）" || exit 0
    systemctl disable --now hy2-porthop.service >/dev/null 2>&1 || true
    rm -f "${HOP_SERVICE}" "${HOP_SCRIPT}"
    bash <(curl -fsSL https://get.hy2.sh/) --remove >/dev/null 2>&1 || true
    rm -rf /etc/hysteria
    systemctl disable --now snell.service >/dev/null 2>&1 || true
    rm -f "${SNELL_SERVICE}" "${SNELL_BIN}"
    rm -rf "${SNELL_DIR}"
    userdel snell >/dev/null 2>&1 || true
    rm -f "${ENV_FILE}" "${INFO_FILE}"
    systemctl daemon-reload
    ok "卸载完成"
}

menu() {
    local n
    while true; do
        clear 2>/dev/null || true
        echo
        echo -e "  ${Green}onekey${Font} v${SCRIPT_VERSION} —— Hysteria2 + Snell for Surge / Shadowrocket"
        echo "  ------------------------------------------------"
        import_existing >/dev/null 2>&1 || true
        if [[ -f "${ENV_FILE}" ]]; then
            local st_h st_s
            st_h=$(systemctl is-active hysteria-server 2>/dev/null || true)
            st_s=$(systemctl is-active snell 2>/dev/null || true)
            echo -e "  状态：Hysteria2 ${st_h:-未知} | Snell ${st_s:-未知} | BBR $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | SSH 端口 $(ssh_current_ports)"
        else
            echo -e "  状态：${Yellow}未安装${Font} | BBR $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | SSH 端口 $(ssh_current_ports)"
        fi
        echo "  ------------------------------------------------"
        echo "  1. 安装 Hysteria2 + Snell"
        echo "  2. 查看客户端配置（Surge / Shadowrocket 二维码）"
        echo "  3. 域名与证书（查看 / 更换域名 / 重新申请）"
        echo "  4. 重新检测带宽并更新"
        echo "  ------------------------------------------------"
        echo "  5. 网络诊断（只读：三网延迟丢包 / PMTU / 重传）"
        echo "  6. 网络调优（BBR + fq + 按 BDP 计算缓冲，可回滚）"
        echo "  7. 回滚网络调优"
        echo "  ------------------------------------------------"
        echo "  8. 修改 SSH 端口"
        echo "  9. 禁用密码登录（仅允许密钥登录）"
        echo "  ------------------------------------------------"
        echo " 10. 更新 Hysteria2 / Snell"
        echo " 11. 卸载"
        echo "  0. 退出"
        echo
        read -rp "请选择 [0-11]：" n
        # 每个操作在子 shell 中执行：出错只结束当前操作，回到菜单
        case "${n}" in
            1) ( do_install ) || true ;;
            2) ( show_info ) || true ;;
            3) ( do_domain ) || true ;;
            4) ( do_bandwidth ) || true ;;
            5) ( do_diag ) || true ;;
            6) ( do_tune ) || true ;;
            7) ( do_tune_rollback ) || true ;;
            8) ( do_ssh_port ) || true ;;
            9) ( do_ssh_key ) || true ;;
            10) ( do_update ) || true ;;
            11) ( do_uninstall ) || true ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac
        echo
        read -rp "按回车返回主菜单..." _
    done
}

main() {
    check_root
    case "${1:-}" in
        install)   do_install ;;
        info)      show_info ;;
        domain)    do_domain ;;
        bandwidth) do_bandwidth ;;
        ssh-port)  do_ssh_port ;;
        ssh-key)   do_ssh_key ;;
        diag)      do_diag ;;
        tune|bbr)  do_tune ;;
        tune-rollback) do_tune_rollback ;;
        update)    do_update ;;
        uninstall) do_uninstall ;;
        "")        menu ;;
        *)         die "未知参数：$1（可用：install|info|domain|bandwidth|diag|tune|tune-rollback|ssh-port|ssh-key|update|uninstall）" ;;
    esac
}

main "$@"
