#!/bin/bash

DEFAULT_START_PORT=20000                         #默认起始端口
DEFAULT_SOCKS_USERNAME="userb"                   #默认socks账号
DEFAULT_SOCKS_PASSWORD="passwordb"               #默认socks密码
DEFAULT_WS_PATH="/ws"                            #默认ws路径
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid) #默认随机UUID

# 这行代码已更新为最稳定的方法，用于获取所有 IPv4 和 IPv6 地址，并排除内部和回环地址
get_ip_addresses() {
    IP_ADDRESSES=()
    while read -r ip_address; do
        # 忽略回环地址和私有地址 (10.x.x.x, 172.16.x.x, 192.168.x.x)
        if [[ ! "$ip_address" =~ ^(127\.|10\.|172\.|192\.|::1) ]]; then 
            IP_ADDRESSES+=("$ip_address")
        fi
    done < <(ip -4 addr show | awk '/inet / {print $2}' | cut -d/ -f1; ip -6 addr show | awk '/inet6 / {print $2}' | cut -d/ -f1)
}
get_ip_addresses

cleanup() {
    echo "清理旧的 Xray 服务和文件..."
    systemctl stop xrayL.service &>/dev/null
    systemctl disable xrayL.service &>/dev/null
    rm -f /etc/systemd/system/xrayL.service &>/dev/null
    rm -rf /etc/xrayL &>/dev/null
    rm -f /usr/local/bin/xrayL &>/dev/null
    rm -rf /tmp/xray_temp &>/dev/null
}

install_xray() {
    echo "安装 Xray..."
    cleanup # 在安装前先进行清理
    
    mkdir -p /tmp/xray_temp
    cd /tmp/xray_temp
    
    apt-get install unzip -y || yum install unzip -y
    wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
    unzip Xray-linux-64.zip
    
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL
    
    cat <<EOF >/etc/systemd/system/xrayL.service
[Unit]
Description=XrayL Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayL -c /etc/xrayL/config.toml
Restart=on-failure
User=nobody
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl start xrayL.service
    echo "Xray 安装完成."
}

config_xray() {
    config_type=$1
    mkdir -p /etc/xrayL
    if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ]; then
        echo "类型错误！仅支持socks和vmess."
        exit 1
    fi

    read -p "起始端口 (默认 $DEFAULT_START_PORT): " START_PORT
    START_PORT=${START_PORT:-$DEFAULT_START_PORT}
    if [ "$config_type" == "socks" ]; then
        read -p "SOCKS 账号 (默认 $DEFAULT_SOCKS_USERNAME): " SOCKS_USERNAME
        SOCKS_USERNAME=${SOCKS_USERNAME:-$DEFAULT_SOCKS_USERNAME}

        read -p "SOCKS 密码 (默认 $DEFAULT_SOCKS_PASSWORD): " SOCKS_PASSWORD
        SOCKS_PASSWORD=${SOCKS_PASSWORD:-$DEFAULT_SOCKS_PASSWORD}
    elif [ "$config_type" == "vmess" ]; then
        read -p "UUID (默认随机): " UUID
        UUID=${UUID:-$DEFAULT_UUID}
        read -p "WebSocket 路径 (默认 $DEFAULT_WS_PATH): " WS_PATH
        WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
    fi
    
    config_content="" # 重置变量
    for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
        config_content+="[[inbounds]]\n"
        config_content+="port = $((START_PORT + i))\n"
        config_content+="protocol = \"$config_type\"\n"
        config_content+="tag = \"tag_$((i + 1))\"\n"
        config_content+="[inbounds.settings]\n"
        if [ "$config_type" == "socks" ]; then
            config_content+="auth = \"password\"\n"
            config_content+="udp = true\n"
            config_content+="ip = \"${IP_ADDRESSES[i]}\"\n"
            config_content+="[[inbounds.settings.accounts]]\n"
            config_content+="user = \"$SOCKS_USERNAME\"\n"
            config_content+="pass = \"$SOCKS_PASSWORD\"\n"
        elif [ "$config_type" == "vmess" ]; then
            config_content+="[[inbounds.settings.clients]]\n"
            config_content+="id = \"$UUID\"\n"
            config_
