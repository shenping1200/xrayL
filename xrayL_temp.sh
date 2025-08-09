#!/bin/bash

# ==================== 默认配置 ====================
DEFAULT_START_PORT=20000                         #默认起始端口
DEFAULT_SOCKS_USERNAME="userb"                   #默认socks账号
DEFAULT_SOCKS_PASSWORD="passwordb"               #默认socks密码
DEFAULT_WS_PATH="/ws"                            #默认ws路径
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid) #默认随机UUID

# ==================== 功能函数 ====================
get_ip_addresses() {
    IP_ADDRESSES=()
    while read -r ip_address; do
        if [[ ! "$ip_address" =~ ^(127\.|10\.|172\.|192\.|::1|fe80) ]]; then
            IP_ADDRESSES+=("$ip_address")
        fi
    done < <(ip -4 addr show | awk '/inet / {print $2}' | cut -d/ -f1; ip -6 addr show | awk '/inet6 / {print $2}' | cut -d/ -f1)
}

cleanup() {
    echo "清理旧的 Xray 服务和文件..."
    systemctl stop xrayL.service &>/dev/null
    systemctl disable xrayL.service &>/dev/null
    rm -f /etc/systemd/system/xrayL.service &>/dev/null
    rm -rf /etc/xrayL &>/dev/null
    rm -f /usr/local/bin/xrayL &>/dev/null
}

add_and_ping_ips_and_route() {
    echo "正在添加IP地址、路由并ping网关..."
    GATEWAY_IPV6="2602:fd37:109:a1::1"
    IPV6_TO_ADD=(
        "2602:fd37:109:a1:e544:6966:45fb:e548"
        "2602:fd37:109:a1:4151:81e5:a0d2:8013"
        "2602:fd37:109:a1:836f:9a62:b5d0:73ca"
        "2602:fd37:109:a1:5d3b:f9b7:1a26:9c00"
        "2602:fd37:109:a1:aa3a:416e:2ba7:a90d"
        "2602:fd37:109:a1:7630:a25d:bacb:f78f"
        "2602:fd37:109:a1:6e34:a1c0:34b9:c3ca"
        "2602:fd37:109:a1:2a2e:ea26:7e85:8058"
        "2602:fd37:109:a1:83c2:e5fb:e091:4122"
        "2602:fd37:109:a1:53d8:5bcf:718f:cb51"
    )
    
    # 清除旧的IPv6地址
    sudo ip -6 addr flush dev eth0 &>/dev/null
    
    # 逐个添加IP、路由并ping网关
    for ip in "${IPV6_TO_ADD[@]}"; do
        echo "添加IP和路由: $ip"
        sudo ip addr add "$ip"/64 dev eth0 &>/dev/null
        sudo ip -6 route add default via "$GATEWAY_IPV6" dev eth0 onlink &>/dev/null
        sudo ping6 -c 3 -I "$ip" "$GATEWAY_IPV6" &>/dev/null
    done
    
    echo "IP地址、路由添加和激活完成。"
}

install_xray() {
    echo "安装 Xray..."
    cleanup 
    
    apt-get install unzip -y || yum install unzip -y
    
    mkdir -p /tmp/xray_install
    cd /tmp/xray_install
    
    wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
    unzip Xray-linux-64.zip
    
    mv xray /usr/local/bin/xrayL
    chmod +x /usr/local/bin/xrayL
    
    cat > /etc/systemd/system/xrayL.service <<EOF
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
    
    # 使用 < /dev/tty 强制从终端读取输入
    read -p "起始端口 (默认 $DEFAULT_START_PORT): " START_PORT < /dev/tty
    START_PORT=${START_PORT:-$DEFAULT_START_PORT}
    if [ "$config_type" == "socks" ]; then
        read -p "SOCKS 账号 (默认 $DEFAULT_SOCKS_USERNAME): " SOCKS_USERNAME < /dev/tty
        SOCKS_USERNAME=${SOCKS_USERNAME:-$DEFAULT_SOCKS_USERNAME}
        read -p "SOCKS 密码 (默认 $DEFAULT_SOCKS_PASSWORD): " SOCKS_PASSWORD < /dev/tty
        SOCKS_PASSWORD=${SOCKS_PASSWORD:-$DEFAULT_SOCKS_PASSWORD}
    elif [ "$config_type" == "vmess" ]; then
        read -p "UUID (默认随机): " UUID < /dev/tty
        UUID=${UUID:-$DEFAULT_UUID}
        read -p "WebSocket 路径 (默认 $DEFAULT_WS_PATH): " WS_PATH < /dev/tty
        WS_PATH=${WS_PATH:-$DEFAULT_WS_PATH}
    fi
    
    config_content=""
    local num_ips=${#IP_ADDRESSES[@]}
    for ((i = 0; i < num_ips; i++)); do
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
            config_content+="[inbounds.streamSettings]\n"
            config_content+="network = \"ws\"\n"
            config_content+="[inbounds.streamSettings.wsSettings]\n"
            config_content+="path = \"$WS_PATH\"\n\n"
        fi
        config_content+="[[outbounds]]\n"
        config_content+="sendThrough = \"${IP_ADDRESSES[i]}\"\n"
        config_content+="protocol = \"freedom\"\n"
        config_content+="tag = \"tag_$((i + 1))\"\n\n"
        config_content+="[[routing.rules]]\n"
        config_content+="type = \"field\"\n"
        config_content+="inboundTag = \"tag_$((i + 1))\"\n"
        config_content+="outboundTag = \"tag_$((i + 1))\"\n\n\n"
    done
    
    echo -e "$config_content" >/etc/xrayL/config.toml
    systemctl restart xrayL.service
    systemctl --no-pager status xrayL.service
    
    echo ""
    echo "生成 $config_type 配置完成"
    echo "起始端口:$START_PORT"
    echo "结束端口:$(($START_PORT + num_ips - 1))"
    if [ "$config_type" == "socks" ]; then
        echo "socks账号:$SOCKS_USERNAME"
        echo "socks密码:$SOCKS_PASSWORD"
    elif [ "$config_type" == "vmess" ]; then
        echo "UUID:$UUID"
        echo "ws路径:$WS_PATH"
    fi
    echo ""
}

main() {
    cleanup
    add_and_ping_ips_and_route
    get_ip_addresses
    
    if [ -x "$(command -v xrayL)" ] ; then
        echo "XrayL已安装，跳过安装步骤。"
    else
        install_xray
    fi

    if [ $# -eq 1 ]; then
        config_type="$1"
    else
        read -p "选择生成的节点类型 (socks/vmess): " config_type < /dev/tty
    fi
    
    if [ "$config_type" == "vmess" ]; then
        config_xray "vmess"
    elif [ "$config_type" == "socks" ]; then
        config_xray "socks"
    else
        echo "未正确选择类型，使用默认sokcs配置."
        config_xray "socks"
    fi
}

main "$@"
