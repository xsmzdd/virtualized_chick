#!/usr/bin/env bash

# redsocks 自动检测与拉起脚本
# 每分钟检测一次 redsocks 进程
# 如果 redsocks 没有运行，则自动执行代理规则和启动命令

LOG_FILE="/var/log/check_redsocks.log"
REDSOCKS_DIR="/root/redsocks"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行，或使用 sudo 执行。"
    exit 1
fi

log "redsocks 检测脚本启动，每 60 秒检测一次。"

while true; do
    if pgrep -x "redsocks" >/dev/null 2>&1; then
        log "redsocks 正在运行。"
    else
        log "检测到 redsocks 未运行，开始重新启动..."

        if [ ! -d "$REDSOCKS_DIR" ]; then
            log "错误：目录不存在：$REDSOCKS_DIR"
            sleep 60
            continue
        fi

        cd "$REDSOCKS_DIR" || {
            log "错误：无法进入目录：$REDSOCKS_DIR"
            sleep 60
            continue
        }

        chmod +x proxy-rules.sh

        log "执行 proxy-rules.sh..."
        ./proxy-rules.sh >> "$LOG_FILE" 2>&1

        log "保存 netfilter-persistent..."
        netfilter-persistent save >> "$LOG_FILE" 2>&1

        log "重载 netfilter-persistent..."
        netfilter-persistent reload >> "$LOG_FILE" 2>&1

        log "启动 redsocks..."
        ./redsocks -c redsocks.conf >> "$LOG_FILE" 2>&1 &

        log "重载 systemd..."
        systemctl daemon-reload >> "$LOG_FILE" 2>&1

        log "设置 redsocks 开机自启..."
        systemctl enable redsocks >> "$LOG_FILE" 2>&1

        log "启动 redsocks systemd 服务..."
        systemctl start redsocks >> "$LOG_FILE" 2>&1

        cd ~ || true

        sleep 3

        if pgrep -x "redsocks" >/dev/null 2>&1; then
            log "redsocks 已成功重新启动。"
        else
            log "错误：redsocks 启动失败，请检查 redsocks.conf 或 systemd 服务。"
        fi
    fi

    sleep 60
done
