#!/bin/bash

# 安装必要工具
apk add wget curl openssl openrc

# 动态获取系统架构并匹配 Hysteria 命名
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        HY_ARCH="amd64"
        ;;
    aarch64 | arm64)
        HY_ARCH="arm64"
        ;;
    armv7l)
        HY_ARCH="armv7"
        ;;
    *)
        echo "------------------------------------------------------------------------"
        echo "错误：不支持的系统架构: $ARCH"
        echo "------------------------------------------------------------------------"
        exit 1
        ;;
esac

echo "检测到系统架构为: $ARCH，将下载对应的 Hysteria 客户端..."

generate_random_password() {
  dd if=/dev/random bs=18 count=1 status=none | base64
}

GENPASS="$(generate_random_password)"

echo_hysteria_config_yaml() {
  cat << EOF
listen: :31061

#有域名，使用CA证书
#acme:
#  domains:
#    - test.heybro.bid #你的域名，需要先解析到服务器ip
#  email: xxx@gmail.com

#使用自签名证书
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
}

echo_hysteria_autoStart(){
  cat << EOF
#!/sbin/openrc-run

name="hysteria"

command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"

pidfile="/var/run/${name}.pid"

command_background="yes"

depend() {
        need networking
}

EOF
}

# 使用动态匹配的架构变量下载 Hysteria
wget -O /usr/local/bin/hysteria "https://download.hysteria.network/app/latest/hysteria-linux-$HY_ARCH" --no-check-certificate
chmod +x /usr/local/bin/hysteria

mkdir -p /etc/hysteria/

# 生成自签名证书
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=bing.com" -addext "subjectAltName = DNS:bing.com" -days 36500

# 写配置文件
echo_hysteria_config_yaml > "/etc/hysteria/config.yaml"

# 写自启动
echo_hysteria_autoStart > "/etc/init.d/hysteria"
chmod +x /etc/init.d/hysteria
# 启用自启动
rc-update add hysteria

# 启动服务
service hysteria start

# 3. 自动获取公网 IP 与证书 SHA256 指纹用于拼装 URL
SERVER_IP=$(curl -s ifconfig.me || wget -qO- ifconfig.me || echo "127.0.0.1")
CERT_SHA256=$(openssl x509 -in /etc/hysteria/server.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
HY_URL="hysteria2://$GENPASS@$SERVER_IP:31061?insecure=1&pinSHA256=$CERT_SHA256&sni=bing.com#hysteria2-alpine-$SERVER_IP"

echo "------------------------------------------------------------------------"
echo "hysteria2 已经安装完成"
echo "当前架构支持： $HY_ARCH"
echo "默认端口： 31061"
echo "密码为：   $GENPASS"
echo "SNI为：    bing.com"
echo "配置文件： /etc/hysteria/config.yaml"
echo ""
echo "url链接为："
echo "$HY_URL"
echo ""
echo "已经随系统自动启动"
echo "看状态 service hysteria status"
echo "重启 service hysteria restart"
echo "请享用。"
echo "------------------------------------------------------------------------"
