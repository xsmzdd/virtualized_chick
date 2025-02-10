#!/bin/bash

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

# 下载配置文件和脚本
sudo curl -o /root/redsocks/redsocks.conf https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/redsocks.conf
sudo curl -o /root/redsocks/proxy-rules.sh https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/proxy-rules.sh
sudo curl -o /etc/systemd/system/redsocks.service https://raw.githubusercontent.com/xsmzdd/virtualized_chick/refs/heads/main/redsocks.service

# 赋予下载的文件执行权限
sudo chmod +x /root/redsocks/redsocks.conf
sudo chmod +x /root/redsocks/proxy-rules.sh
sudo chmod +x /etc/systemd/system/redsocks.service

echo "安装完成，redsocks 已准备就绪！"