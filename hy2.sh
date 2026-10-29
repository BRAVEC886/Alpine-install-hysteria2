#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    apk add --no-cache bash
    exec bash "$0" "$@"
fi

set -e

CAP_HEX=$(awk '/^CapEff:/ {print $2}' /proc/self/status)
HAS_NET_ADMIN=0
if [ -n "$CAP_HEX" ] && (( (16#$CAP_HEX & 0x1000) != 0 )); then
    HAS_NET_ADMIN=1
    echo "当前进程具有 CAP_NET_ADMIN：将安装端口跳跃所需的网络工具，并允许输入端口范围。"
else
    echo "当前进程缺少 CAP_NET_ADMIN：跳过端口跳跃所需的网络工具，仅允许输入单个端口。"
fi

apk add --no-cache wget curl openssl openrc coreutils

if [ "$HAS_NET_ADMIN" -eq 1 ]; then
    apk add --no-cache iptables ip6tables
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) HY_ARCH="amd64" ;;
    aarch64 | arm64) HY_ARCH="arm64" ;;
    armv7l) HY_ARCH="armv7" ;;
    *)
        echo "------------------------------------------------------------------------"
        echo "错误：不支持的系统架构: $ARCH"
        echo "------------------------------------------------------------------------"
        exit 1
        ;;
esac

echo "检测到系统架构为: $ARCH，将下载 Hysteria 客户端 ($HY_ARCH)..."

mkdir -p /usr/local/bin
wget -O /usr/local/bin/hysteria \
    "https://download.hysteria.network/app/latest/hysteria-linux-$HY_ARCH"
chmod +x /usr/local/bin/hysteria

if ! /usr/local/bin/hysteria version >/dev/null 2>&1; then
    echo "错误：Hysteria 下载后未能通过版本检查，请检查下载文件和系统兼容性。"
    exit 1
fi
echo "Hysteria 下载完成。"

DEFAULT_PORT=$(shuf -i 10000-60000 -n 1)
while true; do
    if [ "$HAS_NET_ADMIN" -eq 1 ]; then
        read -r -p "请输入 Hysteria 2 监听端口或端口范围 [默认随机端口 $DEFAULT_PORT]（单端口示例：20000；端口范围示例：30000-40000）: " PORT_INPUT
    else
        read -r -p "请输入 Hysteria 2 单个监听端口 [默认随机端口 $DEFAULT_PORT]（例如：20000；当前不允许输入端口范围）: " PORT_INPUT
    fi

    PORT_INPUT=${PORT_INPUT:-$DEFAULT_PORT}

    if [ "$HAS_NET_ADMIN" -eq 0 ] && [[ "$PORT_INPUT" == *-* ]]; then
        echo "错误：当前进程缺少 CAP_NET_ADMIN，只允许输入单个端口，请重新输入。"
        continue
    fi

    if [[ "$PORT_INPUT" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?$ ]]; then
        START_PORT=$((10#${BASH_REMATCH[1]}))
        END_PORT=$START_PORT
        if [ -n "${BASH_REMATCH[3]:-}" ]; then
            END_PORT=$((10#${BASH_REMATCH[3]}))
        fi
        if (( START_PORT >= 1 && START_PORT <= 65535 &&
              END_PORT >= 1 && END_PORT <= 65535 &&
              START_PORT <= END_PORT )); then
            break
        fi
    fi
    echo "错误：端口格式无效。请输入 1-65535 范围内的端口，或合法的起止端口范围。"
done

FIRST_PORT="$START_PORT"

if [ -r /proc/sys/kernel/random/uuid ]; then
    GENPASS=$(cat /proc/sys/kernel/random/uuid)
else
    GENPASS=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' |
        sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/')
fi

mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -subj "/CN=bing.com" \
    -addext "subjectAltName = DNS:bing.com" \
    -days 36500
chmod 600 /etc/hysteria/server.key

cat > /etc/hysteria/config.yaml <<EOF
listen: :$PORT_INPUT

# 有域名时可改用 ACME/CA 证书
# acme:
#   domains:
#     - test.heybro.bid
#   email: xxx@gmail.com

# 使用自签名证书
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $GENPASS

masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true
EOF

cat > /etc/init.d/hysteria <<'EOF'
#!/sbin/openrc-run

name="hysteria"
description="Hysteria 2 server"

command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria.pid"

depend() {
    need net
    after networking
}
EOF

chmod +x /etc/init.d/hysteria
rc-update add hysteria default

if service hysteria restart; then
    :
else
    service hysteria start
fi

if ! service hysteria status; then
    echo "警告：Hysteria 服务状态检查未通过，请检查配置和日志。"
fi

get_ipv4() {
    local ip=""
    ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '%s' "$ip"
    fi
}

get_ipv6() {
    local ip=""
    ip=$(curl -6 -fsS --max-time 5 https://api6.ipify.org 2>/dev/null || true)
    if [[ "$ip" == *:* && "$ip" != *[!0-9a-fA-F:]* ]]; then
        printf '%s' "$ip"
    fi
}

SERVER_IPV4=$(get_ipv4 || true)
SERVER_IPV6=$(get_ipv6 || true)
CERT_SHA256=$(openssl x509 -in /etc/hysteria/server.crt -noout -fingerprint -sha256 |
    cut -d= -f2 | tr -d ':')

make_url() {
    local address="$1"
    local label="$2"
    local url_host="$address"
    if [[ "$address" == *:* ]]; then
        url_host="[$address]"
    fi
    printf 'hysteria2://%s@%s:%s?insecure=1&pinSHA256=%s&sni=bing.com#hysteria2-alpine-%s' \
        "$GENPASS" "$url_host" "$FIRST_PORT" "$CERT_SHA256" "$label"
}

echo "------------------------------------------------------------------------"
echo "Hysteria 2 安装配置完成"
echo "当前架构：$HY_ARCH"
echo "监听端口/范围：$PORT_INPUT"
if [ "$HAS_NET_ADMIN" -eq 1 ]; then
    echo "CAP_NET_ADMIN：具备"
else
    echo "CAP_NET_ADMIN：缺少"
fi
echo "UUID 密码：$GENPASS"
echo "SNI：bing.com"
echo "配置文件：/etc/hysteria/config.yaml"
echo ""

URL_COUNT=0
if [ -n "$SERVER_IPV4" ]; then
    echo "IPv4 链接："
    make_url "$SERVER_IPV4" "ipv4-$SERVER_IPV4"
    echo
    URL_COUNT=$((URL_COUNT + 1))
fi
if [ -n "$SERVER_IPV6" ]; then
    echo "IPv6 链接："
    make_url "$SERVER_IPV6" "ipv6-$SERVER_IPV6"
    echo
    URL_COUNT=$((URL_COUNT + 1))
fi
if [ "$URL_COUNT" -eq 0 ]; then
    echo "警告：未能自动获取公网 IPv4 或 IPv6 地址。"
    echo "请检查服务器网络和 curl 出站连通性，再手动替换 URL 中的服务器地址。"
fi

echo "自启动已配置（OpenRC default runlevel）。"
echo "查看状态：service hysteria status"
echo "重启服务：service hysteria restart"
echo "------------------------------------------------------------------------"
echo "自签名证书 /etc/hysteria/server.crt："
cat /etc/hysteria/server.crt
