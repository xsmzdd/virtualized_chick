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
    echo "lsof 已安装"
else
    echo "lsof 未安装，开始安装..."
    if command -v apt >/dev/null 2>&1; then
        apt update && apt install -y lsof
    elif command -v yum >/dev/null 2>&1; then
        yum install -y lsof
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y lsof
    else
        echo "无法识别包管理器"
        exit 1
    fi
fi

########################################
# 2. 强制清理 12345 端口（修复点）
########################################
echo "检测并清理 12345 端口..."

LSOF_BIN=$(command -v lsof || echo "/usr/bin/lsof")

PIDS=$($LSOF_BIN -t -i TCP:12345 || true)

if [[ -n "$PIDS" ]]; then
    echo "发现占用端口的进程：$PIDS"
    kill -9 $PIDS
    echo "端口已释放"
else
    echo "端口未被占用"
fi

########################################
# 3. 停止 redsocks（避免重复）
########################################
echo "停止 redsocks 服务..."
systemctl stop redsocks 2>/dev/null || true

########################################
# 4. 清空 nat 表（可选，按你原逻辑）
########################################
echo "清空 iptables nat 表..."
iptables -t nat -F

########################################
# 5. 重新加载规则 + 启动 redsocks
########################################
echo "执行 redsocks 配置..."

cd /root/redsocks
chmod +x proxy-rules.sh
./proxy-rules.sh
netfilter-persistent save
netfilter-persistent reload

systemctl daemon-reload
systemctl enable redsocks
systemctl restart redsocks

echo "所有操作执行完成"
