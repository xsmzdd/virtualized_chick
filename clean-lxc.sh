#!/bin/bash

set -u

echo "开始检测所有 LXC 容器..."

if ! command -v lxc >/dev/null 2>&1; then
    echo "错误：未找到 lxc 命令"
    exit 1
fi

containers=$(lxc list --format csv -c n)

if [ -z "$containers" ]; then
    echo "没有检测到任何容器"
    exit 0
fi

for ct in $containers; do
    echo "========================================"
    echo "准备清理容器：$ct"
    echo "========================================"

    state=$(lxc info "$ct" | awk -F': ' '/^Status:/ {print $2}')
    started_by_script=0

    if [ "$state" != "Running" ]; then
        echo "容器 $ct 当前不是运行状态，正在启动..."
        lxc start "$ct"

        echo "等待容器启动..."
        sleep 5

        started_by_script=1
    fi

    echo "开始清理容器：$ct"

    lxc exec "$ct" -- bash -c '
        set -e

        echo "[1/6] 清理 /var/lib/apt/lists/"
        rm -rf /var/lib/apt/lists/*

        echo "[2/6] 清理 /var/cache/apt/archives/"
        rm -rf /var/cache/apt/archives/*

        echo "[3/6] 清理 journal 日志到 20M"
        if command -v journalctl >/dev/null 2>&1; then
            journalctl --vacuum-size=20M || true
        else
            echo "journalctl 不存在，跳过"
        fi

        echo "[4/6] apt clean"
        apt clean

        echo "[5/6] 修复 dpkg 配置"
        dpkg --configure -a

        echo "[6/6] apt update"
        apt update

        echo "容器内部清理完成"
    '

    if [ $? -eq 0 ]; then
        echo "容器 $ct 清理成功"
    else
        echo "容器 $ct 清理失败"
    fi

    if [ "$started_by_script" -eq 1 ]; then
        echo "容器 $ct 原本是停止状态，正在关闭..."
        lxc stop "$ct"
    fi

    echo
done

echo "所有容器清理完成"
