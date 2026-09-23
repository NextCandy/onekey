#!/usr/bin/env bash
#
# onekey —— Surge / Shadowrocket 一键部署脚本
#   Hysteria2（主力，UDP/QUIC + 端口跳跃 + 自动 ACME 证书）
#   Snell v5（备用，TCP，仅 Surge）
#   自动检测 VPS 带宽 / 自动开启 BBR / 修改 SSH 端口 / 禁用密码仅密钥登录
#
# 支持系统：Debian 10+ / Ubuntu 20.04+ / CentOS Stream / Rocky / Alma
# 项目地址：https://github.com/NextCandy/onekey
# 用法：bash install.sh [install|info|bandwidth|ssh-port|ssh-key|bbr|update|uninstall]

set -euo pipefail

SCRIPT_VERSION="1.0.0"
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
EOF
    chmod 600 "${ENV_FILE}"
}

# ============================================================
# BBR / 系统优化
# ============================================================

enable_bbr() {
    local kmaj kmin
    kmaj=$(uname -r | cut -d. -f1); kmin=$(uname -r | cut -d. -f2)
    if (( kmaj < 4 || (kmaj == 4 && kmin < 9) )); then
        warn "内核 $(uname -r) 低于 4.9，不支持 BBR，已跳过"
        return 0
    fi
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" >/etc/modules-load.d/onekey-bbr.conf
    cat >"${SYSCTL_FILE}" <<EOF
# QUIC 需要更大的 UDP 缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || true
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        ok "BBR 已开启（$(sysctl -n net.core.default_qdisc) + bbr），UDP 缓冲区已调大"
    else
        warn "BBR 开启失败，当前拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control)"
    fi
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
# 交互输入
# ============================================================

read_inputs() {
    SERVER_IP4=$(curl -s4m8 https://api.ipify.org || true)
    SERVER_IP6=$(curl -s6m8 https://api6.ipify.org || true)
    echo "本机 IPv4：${SERVER_IP4:-无}"
    echo "本机 IPv6：${SERVER_IP6:-无}"
    [[ -n "${SERVER_IP4}${SERVER_IP6}" ]] || die "无法获取本机公网 IP"

    echo
    echo "请先为域名添加解析：A 记录 -> ${SERVER_IP4:-（无）}${SERVER_IP6:+，AAAA 记录 -> ${SERVER_IP6}}"
    echo "Cloudflare 请关闭小黄云（仅 DNS）。"
    read -rp "请输入域名：" DOMAIN
    [[ -n "${DOMAIN}" ]] || die "域名不能为空"

    local a4 a6 good=0
    a4=$(resolve A "${DOMAIN}" || true)
    a6=$(resolve AAAA "${DOMAIN}" || true)
    echo "解析结果：A=${a4:-无}  AAAA=${a6:-无}"
    # Let's Encrypt 有 AAAA 记录时优先走 IPv6 验证，所以 AAAA 必须正确
    if [[ -n "${a6}" && "${a6}" != "${SERVER_IP6}" ]]; then
        warn "AAAA 记录与本机 IPv6 不一致，证书申请大概率失败"
    elif [[ -n "${a4}" && "${a4}" != "${SERVER_IP4}" ]]; then
        warn "A 记录与本机 IPv4 不一致"
    elif [[ -n "${a4}${a6}" ]]; then
        good=1
    else
        warn "域名没有解析记录"
    fi
    if [[ ${good} -eq 1 ]]; then
        ok "域名解析正确"
    else
        confirm "仍要继续吗？" || exit 1
    fi

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

    port_in_use tcp 80 && die "TCP 80 被占用（ACME 证书申请需要），请先停止占用 80 端口的服务（如 Nginx）"

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
    local tcp_ports=(80 "${SNELL_PORT}") udp_ports=("${HY2_PORT}" "${SNELL_PORT}")
    [[ -n "${HOP_RANGE}" ]] && udp_ports+=("${HOP_RANGE}")
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        for p in "${tcp_ports[@]}"; do ufw allow "${p/-/:}/tcp" >/dev/null; done
        for p in "${udp_ports[@]}"; do ufw allow "${p/-/:}/udp" >/dev/null; done
        ok "ufw 已放行端口"
    elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        for p in "${tcp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null; done
        for p in "${udp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/udp" >/dev/null; done
        firewall-cmd --reload >/dev/null
        ok "firewalld 已放行端口"
    fi
    warn "云服务商安全组请放行（IPv4/IPv6 都要）：80/tcp、${HY2_PORT}/udp、${SNELL_PORT}/tcp+udp${HOP_RANGE:+、${HOP_RANGE}/udp}"
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
        echo "  type: http"
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
    systemctl restart hysteria-server.service

    info "等待 ACME 证书签发..."
    local i
    for i in $(seq 1 30); do
        if journalctl -u hysteria-server --since "-2min" --no-pager 2>/dev/null | grep -q "server up and running"; then
            ok "Hysteria2 已启动（证书签发成功）"
            return 0
        fi
        sleep 2
    done
    warn "未确认 Hysteria2 启动成功，请执行 journalctl -u hysteria-server -e 查看日志"
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
    enable_bbr
    detect_bandwidth
    ask_client_down
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
    confirm "确认卸载 Hysteria2、Snell 和端口跳跃规则？（SSH 设置与 BBR 保持不变）" || exit 0
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
        echo "  3. 重新检测带宽并更新"
        echo "  ------------------------------------------------"
        echo "  4. 修改 SSH 端口"
        echo "  5. 禁用密码登录（仅允许密钥登录）"
        echo "  6. 开启 BBR"
        echo "  ------------------------------------------------"
        echo "  7. 更新 Hysteria2 / Snell"
        echo "  8. 卸载"
        echo "  0. 退出"
        echo
        read -rp "请选择 [0-8]：" n
        # 每个操作在子 shell 中执行：出错只结束当前操作，回到菜单
        case "${n}" in
            1) ( do_install ) || true ;;
            2) ( show_info ) || true ;;
            3) ( do_bandwidth ) || true ;;
            4) ( do_ssh_port ) || true ;;
            5) ( do_ssh_key ) || true ;;
            6) ( enable_bbr ) || true ;;
            7) ( do_update ) || true ;;
            8) ( do_uninstall ) || true ;;
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
        bandwidth) do_bandwidth ;;
        ssh-port)  do_ssh_port ;;
        ssh-key)   do_ssh_key ;;
        bbr)       enable_bbr ;;
        update)    do_update ;;
        uninstall) do_uninstall ;;
        "")        menu ;;
        *)         die "未知参数：$1（可用：install|info|bandwidth|ssh-port|ssh-key|bbr|update|uninstall）" ;;
    esac
}

main "$@"
