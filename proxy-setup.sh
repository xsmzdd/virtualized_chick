#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 检查root权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误：该脚本必须以root权限运行！${NC}"
    exit 1
fi

# 安装依赖函数
install_deps() {
    echo -e "${YELLOW}[+] 正在安装依赖...${NC}"
    apt update > /dev/null 2>&1
    apt install -y git libevent-dev build-essential iptables-persistent curl > /dev/null 2>&1
}

# 获取网卡名称
get_interface() {
    default_route=$(ip route | grep default | awk '{print $5}' | head -n 1)
    echo $default_route
}

# 配置redsocks
configure_redsocks() {
    cat > redsocks.conf <<EOF
base {
    log_debug = off;
    log_info = on;
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 0.0.0.0;
    local_port = 12345;
    ip = ${proxy_ip};
    port = ${proxy_port};
    type = socks5;
EOF

    if [ "$need_auth" = "y" ]; then
        echo "    login = \"${proxy_user}\";" >> redsocks.conf
        echo "    password = \"${proxy_pass}\";" >> redsocks.conf
    fi

    cat >> redsocks.conf <<EOF
}

redudp {
    local_ip = 0.0.0.0;
    local_port = 10053;
    ip = ${proxy_ip};
    port = ${proxy_port};
    dest_ip = 8.8.8.8;
    dest_port = 53;
    udp_timeout = 30;
    udp_timeout_stream = 180;
}
EOF
}

# 主菜单
main_menu() {
    clear
    echo -e "${GREEN}=== LXD一键全局代理配置脚本 ===${NC}"
    echo "1. 安装配置"
    echo "2. 还原配置"
    echo -n "请选择操作 [1-2]: "
    read choice

    case $choice in
        1)
            install_proxy
            ;;
        2)
            uninstall_proxy
            ;;
        *)
            echo -e "${RED}无效选择！${NC}"
            exit 1
            ;;
    esac
}

# 安装流程
install_proxy() {
    # 输入代理信息
    echo -n "请输入SOCKS5服务器IP: "
    read proxy_ip
    echo -n "请输入SOCKS5服务器端口: "
    read proxy_port
    echo -n "需要认证吗？(y/n): "
    read need_auth

    if [ "$need_auth" = "y" ]; then
        echo -n "请输入用户名: "
        read proxy_user
        echo -n "请输入密码: "
        read -s proxy_pass
        echo
    fi

    # 安装依赖
    install_deps

    # 克隆编译redsocks
    echo -e "${YELLOW}[+] 正在编译redsocks...${NC}"
    git clone https://github.com/darkk/redsocks.git > /dev/null 2>&1
    cd redsocks
    make > /dev/null 2>&1

    # 生成配置文件
    configure_redsocks

    # 获取网卡名称
    interface=$(get_interface)
    echo -e "${YELLOW}[+] 检测到主网卡为：${interface}${NC}"

    # 生成iptables规则脚本
    cat > proxy-rules.sh <<EOF
#!/bin/bash
iptables -t nat -F
iptables -t nat -N REDSOCKS

# 排除私有地址和代理服务器
iptables -t nat -A REDSOCKS -d ${proxy_ip} -j RETURN
iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 169.254.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN

# 重定向流量
iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345
iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
iptables -t nat -A PREROUTING -i ${interface} -p tcp -j REDSOCKS
EOF

    # 应用iptables规则
    echo -e "${YELLOW}[+] 正在应用iptables规则...${NC}"
    chmod +x proxy-rules.sh
    ./proxy-rules.sh > /dev/null 2>&1

    # 持久化规则
    echo -e "${YELLOW}[+] 持久化iptables规则...${NC}"
    netfilter-persistent save > /dev/null 2>&1
    netfilter-persistent reload > /dev/null 2>&1

    # 创建systemd服务
    echo -e "${YELLOW}[+] 创建系统服务...${NC}"
    cat > /etc/systemd/system/redsocks.service <<EOF
[Unit]
Description=Redsocks Transparent Proxy
After=network.target

[Service]
Type=simple
ExecStart=$(pwd)/redsocks -c $(pwd)/redsocks.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable redsocks > /dev/null 2>&1
    systemctl start redsocks

    # 验证配置
    echo -e "${YELLOW}[+] 正在验证代理配置..."
    detected_ip=$(curl -s http://ip.sb)
    echo -e "当前检测IP: ${detected_ip}"
    echo -n "是否显示为代理服务器IP？(y/n): "
    read result

    if [ "$result" = "y" ]; then
        echo -e "${GREEN}✓ 代理配置成功！${NC}"
    else
        echo -e "${RED}✗ 代理配置失败，请检查日志！${NC}"
    fi
}

# 卸载流程
uninstall_proxy() {
    echo -e "${YELLOW}[+] 正在还原配置...${NC}"
    
    # 清除iptables规则
    iptables -t nat -F
    netfilter-persistent save > /dev/null 2>&1
    netfilter-persistent reload > /dev/null 2>&1

    # 停止服务
    systemctl stop redsocks > /dev/null 2>&1
    systemctl disable redsocks > /dev/null 2>&1
    rm -f /etc/systemd/system/redsocks.service

    # 删除文件
    rm -rf $(pwd)/redsocks
    rm -f proxy-rules.sh

    echo -e "${GREEN}✓ 配置已成功还原！${NC}"
}

# 执行主菜单
main_menu
