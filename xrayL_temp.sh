#!/bin/bash

#====================================================
# x-ray install and config
#====================================================

DEFAULT_START_PORT=30000                         #默认起始端口
DEFAULT_SOCKS_USERNAME="120"                   #默认socks账号
DEFAULT_SOCKS_PASSWORD="120"               #默认socks密码
DEFAULT_WS_PATH="/ws"                            #默认ws路径
DEFAULT_UUID=$(cat /proc/sys/kernel/random/uuid) #默认随机UUID

IP_ADDRESSES=($(ip -6 addr show dev eth0 | grep "inet6" | awk '{print $2}' | cut -d'/' -f1 | grep -vE '^fe80|^::1$'))
IPV4_ADDRESS=$(hostname -I | awk '{print $1}')

install_xray() {
	echo "安装 Xray..."
	# 安装unzip
	if ! command -v unzip &> /dev/null; then
		if command -v apt-get &> /dev/null; then
			apt-get update -y > /dev/null
			apt-get install unzip -y
		elif command -v yum &> /dev/null; then
			yum install unzip -y
		fi
	fi
	wget https://github.com/XTLS/Xray-core/releases/download/v1.8.3/Xray-linux-64.zip
	unzip Xray-linux-64.zip
	mv xray /usr/local/bin/xrayL
	chmod +x /usr/local/bin/xrayL
	cat <<EOF >/etc/systemd/system/xrayL.service
[Unit]
Description=XrayL Service
After=network.target

[Service]
ExecStart=/usr/local/bin/xrayL -c /etc/xrayL/config.json
Restart=on-failure
User=nobody
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable xrayL.service
	systemctl start xrayL.service
	echo "Xray 安装完成."
}

config_xray() {
    config_type=$1
    mkdir -p /etc/xrayL
    
    if [ "$config_type" != "socks" ] && [ "$config_type" != "vmess" ] && [ "$config_type" != "single" ] && [ "$config_type" != "socks-ipv4" ]; then
        echo "类型错误！仅支持socks, vmess, single和socks-ipv4."
        exit 1
    fi
	
    if [ "$config_type" == "socks" ] || [ "$config_type" == "single" ] || [ "$config_type" == "socks-ipv4" ]; then
        read -p "起始端口 (默认 $DEFAULT_START_PORT): " START_PORT
        START_PORT=${START_PORT:-$DEFAULT_START_PORT}
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
    
    config_content=""

    if [ "$config_type" == "single" ]; then
        inbounds_config='{"listen": "'"$IPV4_ADDRESS"'", "port": '$START_PORT', "protocol": "socks", "tag": "inbound-main", "settings": {"auth": "password", "udp": true, "accounts": [{"user": "'"$SOCKS_USERNAME"'", "pass": "'"$SOCKS_PASSWORD"'"}]}}'
        
        outbounds_json=""
        outbound_selectors=""

        for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
            if [ $i -gt 0 ]; then
                outbounds_json+=","
                outbound_selectors+=","
            fi
            outbounds_json+='{"protocol": "freedom", "settings": {"sendThrough": "'"${IP_ADDRESSES[i]}"'"}, "tag": "out-ipv6-'$((i + 1))'"}'
            outbound_selectors+='"out-ipv6-'$((i + 1))'"'
        done
        
        config_content='
        {
          "log": {
            "loglevel": "warning"
          },
          "inbounds": [
            '$inbounds_config'
          ],
          "outbounds": [
            '$outbounds_json'
          ],
          "routing": {
            "domainStrategy": "AsIs",
            "rules": [
              {
                "type": "field",
                "inboundTag": ["inbound-main"],
                "outboundTag": "outbound-balancer"
              }
            ],
            "balancers": [
                {
                  "tag": "outbound-balancer",
                  "selector": [
                    '$outbound_selectors'
                  ]
                }
              ]
          }
        }
        '
        echo "$config_content" > /etc/xrayL/config.json
        sed -i 's/\-c \/etc\/xrayL\/config\.toml/\-c \/etc\/xrayL\/config\.json/g' /etc/systemd/system/xrayL.service
    else
        config_file_name="config.toml"
        
        for ((i = 0; i < ${#IP_ADDRESSES[@]}; i++)); do
            config_content+="[[inbounds]]\n"
            if [ "$config_type" == "socks-ipv4" ]; then
                config_content+="listen = \"$IPV4_ADDRESS\"\n"
            else
                config_content+="listen = \"${IP_ADDRESSES[i]}\"\n"
            fi
            
            config_content+="port = $((START_PORT + i))\n"
            config_content+="protocol = \"socks\"\n"
            config_content+="tag = \"tag_$((i + 1))\"\n"
            config_content+="[inbounds.settings]\n"
            config_content+="auth = \"password\"\n"
            config_content+="udp = true\n"
            config_content+="[[inbounds.settings.accounts]]\n"
            config_content+="user = \"$SOCKS_USERNAME\"\n"
            config_content+="pass = \"$SOCKS_PASSWORD\"\n"
            config_content+="[[outbounds]]\n"
            config_content+="sendThrough = \"${IP_ADDRESSES[i]}\"\n"
            config_content+="protocol = \"freedom\"\n"
            config_content+="tag = \"tag_$((i + 1))\"\n\n"
            config_content+="[[routing.rules]]\n"
            config_content+="type = \"field\"\n"
            config_content+="inboundTag = \"tag_$((i + 1))\"\n"
            config_content+="outboundTag = \"tag_$((i + 1))\"\n\n\n"
        done
        
        echo -e "$config_content" >/etc/xrayL/$config_file_name
        sed -i 's/\-c \/etc\/xrayL\/config\.json/\-c \/etc\/xrayL\/config\.toml/g' /etc/systemd/system/xrayL.service
    fi

	systemctl daemon-reload
	systemctl restart xrayL.service
	systemctl --no-pager status xrayL.service
	echo ""
	echo "生成 $config_type 配置完成"
	if [ "$config_type" == "single" ]; then
		echo "代理主机:$IPV4_ADDRESS"
		echo "代理端口:$START_PORT"
		echo "socks账号:$SOCKS_USERNAME"
		echo "socks密码:$SOCKS_PASSWORD"
		echo "已成功绑定 '$((${#IP_ADDRESSES[@]}))' 个 IPv6 地址。"
	else
		echo "起始端口:$START_PORT"
		echo "结束端口:$(($START_PORT + ${#IP_ADDRESSES[@]} - 1))"
		if [ "$config_type" == "socks" ] || [ "$config_type" == "socks-ipv4" ]; then
			echo "socks账号:$SOCKS_USERNAME"
			echo "socks密码:$SOCKS_PASSWORD"
		elif [ "$config_type" == "vmess" ]; then
			echo "UUID:$UUID"
			echo "ws路径:$WS_PATH"
		fi
	fi
	echo ""
}

main() {
	[ -x "$(command -v xrayL)" ] || install_xray
	if [ $# -eq 1 ]; then
		config_type="$1"
	else
		read -p "选择生成的节点类型 (socks/vmess/single/socks-ipv4): " config_type
	fi
	if [ "$config_type" == "vmess" ]; then
		config_xray "vmess"
	elif [ "$config_type" == "socks" ]; then
		config_xray "socks"
	elif [ "$config_type" == "single" ]; then
		config_xray "single"
	elif [ "$config_type" == "socks-ipv4" ]; then
		config_xray "socks-ipv4"
	else
		echo "未正确选择类型，使用默认sokcs配置."
		config_xray "socks"
	fi
}
main "$@"
