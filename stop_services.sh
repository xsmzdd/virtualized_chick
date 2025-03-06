#!/bin/bash

# 清空 NAT 规则
sudo iptables -t nat -F

# 停止 redsocks 服务
sudo systemctl stop redsocks

# 查找占用 12345 端口的进程，并杀死它
PID=$(sudo lsof -i :12345 -t)
if [[ ! -z "$PID" ]]; then
    sudo kill "$PID"
    echo "进程 $PID 已停止"
else
    echo "未找到占用 12345 端口的进程"
fi
