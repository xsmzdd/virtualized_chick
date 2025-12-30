#!/bin/bash
set -euo pipefail

# 更新软件包列表
sudo apt update

# 安装必要的软件包
sudo apt install -y git libevent-dev build-essential iptables-persistent

# 克隆 redsocks 源码仓库
git clone https://github.com/darkk/redsocks.git

# 进入 redsocks 目录并编译
cd redsocks || exit
make

# 创建 redsocks 目录（如果尚未存在）
sudo mkdir -p /root/redsocks

# 下载配置文件和脚本 到 /root/redsocks
sudo curl -fsSL -o /root/redsocks/redsocks.conf \
  https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/redsocks.conf

sudo curl -fsSL -o /root/redsocks/proxy-rules.sh \
  https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/proxy-rules.sh

sudo curl -fsSL -o /etc/systemd/system/redsocks.service \
  https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/redsocks.service

# 下载 stop_services.sh（放两份）
sudo curl -fsSL -o /root/redsocks/stop_services.sh \
  https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/stop_services.sh

sudo curl -fsSL -o /root/stop_services.sh \
  https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/stop_services.sh

# ================= 新增内容开始 =================

# 下载 check_ip_and_run.sh 到 /root/redsocks
sudo curl -fsSL -o /root/redsocks/check_ip_and_run.sh \
  https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/check_ip_and_run.sh

# 赋予执行权限
sudo chmod +x /root/redsocks/check_ip_and_run.sh

# cron 每 5 分钟执行一次（日志仅保留最近一次）
CRON_JOB="*/5 * * * * /root/redsocks/check_ip_and_run.sh > /var/log/check_ip_and_run.log 2>&1"

( crontab -l 2>/dev/null | grep -Fv "check_ip_and_run.sh" ; echo "$CRON_JOB" ) | crontab -

# ================= 新增内容结束 =================

# 赋予下载的文件执行权限
sudo chmod +x /root/redsocks/proxy-rules.sh || true
sudo chmod +x /etc/systemd/system/redsocks.service || true
sudo chmod +x /root/redsocks/stop_services.sh || true
sudo chmod +x /root/stop_services.sh || true

# 返回 root 目录
cd ~

echo "安装完成，redsocks 已准备就绪！"
echo "check_ip_and_run.sh 已设置为每 5 分钟自动运行"
echo "日志文件（仅保留最近一次）：/var/log/check_ip_and_run.log"
