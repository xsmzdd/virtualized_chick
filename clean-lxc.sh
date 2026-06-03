#!/bin/bash

set -u

echo "开始检测 Incus / LXC 容器..."

BACKENDS=()

if command -v incus >/dev/null 2>&1; then
    BACKENDS+=("incus")
fi

if command -v lxc >/dev/null 2>&1; then
    BACKENDS+=("lxc")
fi

if [ "${#BACKENDS[@]}" -eq 0 ]; then
    echo "错误：未找到 incus 或 lxc 命令"
    exit 1
fi

clean_container() {
    local cmd="$1"
    local ct="$2"

    echo "========================================"
    echo "准备清理 [$cmd] 容器：$ct"
    echo "========================================"

    state=$("$cmd" info "$ct" | awk -F': ' '/^Status:/ {print $2}')
    started_by_script=0

    if [ "$state" != "Running" ]; then
        echo "容器 $ct 当前不是运行状态，正在启动..."
        if ! "$cmd" start "$ct"; then
            echo "容器 $ct 启动失败，跳过"
            return 1
        fi

        echo "等待容器启动..."
        sleep 5
        started_by_script=1
    fi

    echo "开始清理容器：$ct"

    if "$cmd" exec "$ct" -- bash -c '
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
        if command -v apt >/dev/null 2>&1; then
            apt clean
        else
            echo "apt 不存在，跳过"
        fi

        echo "[5/6] 修复 dpkg 配置"
        if command -v dpkg >/dev/null 2>&1; then
            dpkg --configure -a
        else
            echo "dpkg 不存在，跳过"
        fi

        echo "[6/6] apt update"
        if command -v apt >/dev/null 2>&1; then
            apt update
        else
            echo "apt 不存在，跳过"
        fi

        echo "容器内部清理完成"
    '; then
        echo "容器 $ct 清理成功"
    else
        echo "容器 $ct 清理失败"
    fi

    if [ "$started_by_script" -eq 1 ]; then
        echo "容器 $ct 原本是停止状态，正在关闭..."
        "$cmd" stop "$ct" || echo "警告：容器 $ct 关闭失败，请手动检查"
    fi

    echo
}

for cmd in "${BACKENDS[@]}"; do
    echo "========================================"
    echo "正在检测 $cmd 容器..."
    echo "========================================"

    containers=$("$cmd" list --format csv -c n)

    if [ -z "$containers" ]; then
        echo "$cmd 没有检测到任何容器"
        echo
        continue
    fi

    while IFS= read -r ct; do
        [ -z "$ct" ] && continue
        clean_container "$cmd" "$ct"
    done <<< "$containers"
done

echo "所有 Incus / LXC 容器清理完成"
