#!/bin/bash

set -e

echo "开始检测公网 IP..."

IP1=$(curl -s --max-time 5 ipinfo.io || true)
IP2=$(curl -s --max-time 5 ip.sb || true)

if [[ -n "$IP1" || -n "$IP2" ]]; then
    echo "已检测到 IP，脚本终止"
    exit 0
fi

echo "未检测到 IP，开始执行后续操作..."

########################################
# 1. lsof 安装检测
########################################
if command -v lsof >/dev/null 2>&1; then
    echo "lsof 已安装，跳过安装步骤"
else
    echo "lsof 未安装，开始安装..."

    if command -v apt >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y lsof
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y lsof
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y lsof
    else
        echo "无法识别系统包管理器，请手动安装 lsof"
        exit 1
    fi

    echo "lsof 安装完成"
fi

########################################
# 2. 杀掉占用 12345 端口的进程
########################################
PID=$(sudo lsof -i :12345 -t || true)

if [[ -n "$PID" ]]; then
    sudo kill "$PID"
    echo "进程 $PID 已停止"
else
    echo "未找到占用 12345 端口的进程"
fi

########################################
# 3. 清空 nat 表
########################################
echo "清空 iptables nat 表..."
sudo iptables -t nat -F

########################################
# 4. 停止 redsocks
########################################
echo "停止 redsocks 服务..."
sudo systemctl stop redsocks || true

########################################
# 5. 执行 redsocks 相关命令
########################################
echo "执行 redsocks 相关配置..."

cd redsocks
chmod +x proxy-rules.sh
sudo ./proxy-rules.sh
sudo netfilter-persistent save
sudo netfilter-persistent reload
sudo ./redsocks -c redsocks.conf
sudo systemctl daemon-reload
sudo systemctl enable redsocks
sudo systemctl start redsocks

echo "所有操作执行完成"
