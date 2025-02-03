#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # 没有颜色

# 主菜单
main_menu() {
    clear
    echo "==============================================="
    echo "   Redsocks + iptables 配置全局 SOCKS5 代理   "
    echo "              作者: 你的名字                   "
    echo "==============================================="
    echo ""
    echo "[ 操作选项 ]"
    echo " 1) 开始安装"
    echo " 2) 启动代理"
    echo " 3) 还原配置"
    echo " 4) 卸载 Redsocks"
    echo " 5) 退出程序"
    echo ""
    echo "==============================================="
    read -rp "➜ 请输入选择 [1-5]: " choice

    case $choice in
        1) install_function ;;
        2) start_proxy ;;
        3) restore_config ;;
        4) uninstall_redsocks ;;
        5) exit_program ;;
        *) 
            echo -e "${RED}无效输入，请输入 1-5${NC}"
            sleep 2
            main_menu
            ;;
    esac
}

# 安装 Redsocks
install_function() {
    echo -e "${GREEN}更新系统并安装必要依赖...${NC}"
    sudo apt update
    sudo apt install -y git libevent-dev build-essential iptables-persistent curl

    echo -e "${GREEN}克隆并编译 Redsocks...${NC}"
    cd /root || exit
    if [ -d "redsocks" ]; then
        rm -rf redsocks
    fi
    git clone https://github.com/darkk/redsocks.git
    cd redsocks || exit
    make 2>/dev/null  # 忽略编译警告

    echo -e "${GREEN}配置 Redsocks...${NC}"
    curl -o /root/redsocks/redsocks.conf https://raw.githubusercontent.com/xsmzdd/virtualized_chick/main/redsocks.conf

    # 让用户输入代理 IP 和端口
    read -rp "请输入 SOCKS5 代理服务器 IP: " proxy_ip
    read -rp "请输入 SOCKS5 代理服务器端口: " proxy_port

    # 修改 redsocks.conf 里的默认代理 IP 和端口
    sed -i "s/ip = 10.212.251.1;/ip = ${proxy_ip};/" /root/redsocks/redsocks.conf
    sed -i "s/port = 17888;/port = ${proxy_port};/" /root/redsocks/redsocks.conf

    echo -e "${GREEN}检测网卡并配置 iptables 规则...${NC}"
    default_iface=$(ip route | grep default | awk '{print $5}')
    echo "检测到的默认网卡: $default_iface"

    curl -o /root/redsocks/proxy-rules.sh https://raw.githubusercontent.com/xsmzdd/virtualized_chick/main/proxy-setup.sh

    # 修改 proxy-rules.sh，将 enp0s6 替换为实际网卡名称
    sed -i "s/enp0s6/${default_iface}/g" /root/redsocks/proxy-rules.sh
    chmod +x /root/redsocks/proxy-rules.sh

    curl -o /etc/systemd/system/redsocks.service https://raw.githubusercontent.com/xsmzdd/virtualized_chick/main/redsocks.service

    echo -e "${GREEN}赋予 Redsocks 及相关脚本执行权限...${NC}"
    chmod +x /root/redsocks/redsocks
    chmod +x /root/redsocks/redsocks.conf

    echo -e "${GREEN}安装完成！可以使用 systemctl start redsocks 启动 Redsocks 代理。${NC}"
    sleep 2
    main_menu
}

# 启动代理
start_proxy() {
    echo -e "${GREEN}正在启动代理...${NC}"
    
    # 确保路径正确
    cd /root/redsocks || exit

    echo -e "${GREEN}执行 iptables 规则脚本...${NC}"
    sudo /root/redsocks/proxy-rules.sh

    echo -e "${GREEN}保存并重新加载 netfilter 规则...${NC}"
    sudo netfilter-persistent save
    sudo netfilter-persistent reload

    echo -e "${GREEN}启动 Redsocks 进程...${NC}"
    sudo /root/redsocks/redsocks -c /root/redsocks/redsocks.conf &

    echo -e "${GREEN}配置 Redsocks 为 systemd 服务...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl enable redsocks
    sudo systemctl start redsocks

    echo -e "${GREEN}代理已成功启动！${NC}"
    sleep 2
    main_menu
}

# 还原配置
restore_config() {
    echo -e "${GREEN}正在还原配置...${NC}"

    # 清除 iptables 规则
    echo -e "${GREEN}清除 iptables 规则...${NC}"
    sudo iptables -t nat -F
    sudo netfilter-persistent save
    sudo netfilter-persistent reload

    # 停止 Redsocks 服务
    echo -e "${GREEN}停止 Redsocks 服务...${NC}"
    sudo systemctl stop redsocks
    sudo systemctl disable redsocks
    sudo systemctl daemon-reload

    # 查找 Redsocks 进程并终止
    redsocks_pid=$(pgrep -f redsocks)
    if [ -n "$redsocks_pid" ]; then
        echo -e "${GREEN}检测到 Redsocks 进程 (PID: $redsocks_pid)，正在终止...${NC}"
        sudo kill -9 "$redsocks_pid"
    else
        echo -e "${GREEN}没有检测到 Redsocks 进程，无需终止。${NC}"
    fi

    echo -e "${GREEN}还原完成！${NC}"
    sleep 2
    main_menu
}

# 卸载 Redsocks
uninstall_redsocks() {
    echo -e "${GREEN}正在卸载 Redsocks...${NC}"

    # 先运行还原配置
    restore_config

    # 删除 Redsocks 相关文件
    echo -e "${GREEN}删除 Redsocks 配置文件...${NC}"
    rm -f /root/redsocks/redsocks.conf
    rm -f /root/redsocks/proxy-rules.sh
    rm -f /etc/systemd/system/redsocks.service

    # 删除 Redsocks 目录
    echo -e "${GREEN}删除 Redsocks 目录...${NC}"
    rm -rf /root/redsocks

    echo -e "${GREEN}卸载 Redsocks 依赖...${NC}"
    sudo apt remove -y libevent-dev build-essential iptables-persistent

    echo -e "${GREEN}卸载完成！${NC}"
    sleep 2
    main_menu
}

# 退出程序
exit_program() {
    echo -e "${GREEN}程序已退出。${NC}"
    exit 0
}

# 运行主菜单
main_menu