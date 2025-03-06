#!/bin/bash

# 确保脚本以 root 用户身份运行
if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 权限运行此脚本。" 
   exit 1
fi

# 设置 root 密码
echo "请输入新的 root 密码："
passwd root

# 修改 SSH 配置，允许 root 通过 SSH 登录
SSHD_CONFIG="/etc/ssh/sshd_config"
if grep -q "^PermitRootLogin" $SSHD_CONFIG; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' $SSHD_CONFIG
else
    echo "PermitRootLogin yes" >> $SSHD_CONFIG
fi

if grep -q "^PasswordAuthentication" $SSHD_CONFIG; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' $SSHD_CONFIG
else
    echo "PasswordAuthentication yes" >> $SSHD_CONFIG
fi

# 重启 SSH 服务
systemctl restart ssh

echo "root 登录已启用，SSH 允许 root 使用密码登录。"
