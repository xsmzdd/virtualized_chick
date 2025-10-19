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

# 下载 stop_services.sh（放两份：/root/redsocks/ 和 /root/）
sudo curl -fsSL -o /root/redsocks/stop_services.sh \
  https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/stop_services.sh

# 额外把 stop_services.sh 保存到 /root 下（你特别要求的）
sudo curl -fsSL -o /root/stop_services.sh \
  https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/stop_services.sh

# 赋予下载的文件执行权限
# 注意：配置文件通常不需要可执行权限，但按你的原脚本保留可执行位（如需调整，可去掉）
sudo chmod +x /root/redsocks/proxy-rules.sh || true
sudo chmod +x /etc/systemd/system/redsocks.service || true
sudo chmod +x /root/redsocks/stop_services.sh || true
sudo chmod +x /root/stop_services.sh || true

# 返回 root 目录
cd ~

echo "安装完成，redsocks 已准备就绪！"
echo "停止Redsocks脚本已下载并设为可执行。"
