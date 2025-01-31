#!/bin/bash

# 清空现有规则
iptables -t nat -F

# 创建 REDSOCKS 链
iptables -t nat -N REDSOCKS

# 排除代理服务器自身 IP 和私有网段
iptables -t nat -A REDSOCKS -d 10.212.251.1 -j RETURN
iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 169.254.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN

# 重定向 TCP 流量到 Redsocks 端口
iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345

# 应用规则到 OUTPUT 和 PREROUTING 链（替换 enp0s6 为实际网卡名）
iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
iptables -t nat -A PREROUTING -i enp0s6 -p tcp -j REDSOCKS
