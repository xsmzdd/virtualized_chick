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

    local state
    local started_by_script=0

    state=$("$cmd" list "$ct" --format csv -c s 2>/dev/null | head -n1 | tr '[:upper:]' '[:lower:]')

    if [ -z "$state" ]; then
        echo "无法获取容器 $ct 的状态，跳过"
        return 1
    fi

    if [ "$state" != "running" ]; then
        echo "容器 $ct 当前状态为：$state，正在启动..."

        local start_output
        local start_code

        start_output=$("$cmd" start "$ct" 2>&1)
        start_code=$?

        if [ "$start_code" -ne 0 ]; then
            if echo "$start_output" | grep -qi "already running"; then
                echo "容器 $ct 实际已经在运行，继续清理..."
            else
                echo "$start_output"
                echo "容器 $ct 启动失败，跳过"
                return 1
            fi
        else
            echo "等待容器启动..."
            sleep 5
            started_by_script=1
        fi
    else
        echo "容器 $ct 当前正在运行，直接清理..."
    fi

    echo "开始清理容器：$ct"

    if "$cmd" exec "$ct" -- bash -s <<'EOF'
set -u

echo "[1/7] 清理 apt lists"
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

echo "[2/7] 清理 apt archives"
rm -rf /var/cache/apt/archives/* 2>/dev/null || true
rm -rf /var/cache/apt/archives/partial/* 2>/dev/null || true

echo "[3/7] 清理 apt cache"
if command -v apt-get >/dev/null 2>&1; then
    apt-get clean || true
else
    echo "apt-get 不存在，跳过"
fi

echo "[4/7] 清理 journal 日志到 20M"
if command -v journalctl >/dev/null 2>&1; then
    journalctl --vacuum-size=20M || true
else
    echo "journalctl 不存在，跳过"
fi

echo "[5/7] 删除 apt/dpkg 锁文件"
rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
rm -f /var/lib/dpkg/lock 2>/dev/null || true
rm -f /var/cache/apt/archives/lock 2>/dev/null || true
rm -f /var/lib/apt/lists/lock 2>/dev/null || true

echo "[6/7] 清理临时文件"
rm -rf /tmp/* 2>/dev/null || true
rm -rf /var/tmp/* 2>/dev/null || true

echo "[7/7] 清理旧日志文件"
find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
find /var/log -type f -name "*.1" -delete 2>/dev/null || true
find /var/log -type f -name "*.old" -delete 2>/dev/null || true
find /var/log -type f -name "*.log.*" -delete 2>/dev/null || true

echo "容器内部清理完成"
EOF
    then
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

    containers=$("$cmd" list --format csv -c n 2>/dev/null)

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
