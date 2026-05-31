#!/usr/bin/env bash
set -u

echo "========== LXC/LXD 容器磁盘限速自动修复脚本 =========="

if ! command -v lxc >/dev/null 2>&1; then
  echo "错误：未找到 lxc 命令"
  exit 1
fi

echo
echo "正在读取容器列表..."

containers=$(lxc list --format csv -c n 2>/dev/null)

if [ -z "$containers" ]; then
  echo "没有找到任何 LXC/LXD 容器，或 lxc list 执行失败"
  exit 1
fi

echo "找到以下容器："
echo "$containers"

echo
echo "开始修复..."

for c in $containers; do
  echo
  echo "========== 处理容器：$c =========="

  if ! lxc config device show "$c" >/tmp/lxc_device_"$c".yaml 2>/dev/null; then
    echo "无法读取 $c 的设备配置，跳过"
    continue
  fi

  echo "当前设备配置："
  cat /tmp/lxc_device_"$c".yaml

  # 检查 root 设备是否存在
  if ! grep -q '^root:' /tmp/lxc_device_"$c".yaml; then
    echo "未发现 root 磁盘设备，跳过 limits 修复"
  else
    echo "清理 root 磁盘 I/O 限速参数..."

    lxc config device unset "$c" root limits.read  >/dev/null 2>&1 || true
    lxc config device unset "$c" root limits.write >/dev/null 2>&1 || true
    lxc config device unset "$c" root limits.max   >/dev/null 2>&1 || true

    echo "清理完成，新的设备配置："
    lxc config device show "$c"
  fi

  state=$(lxc list "$c" --format csv -c s 2>/dev/null)

  if [ "$state" = "RUNNING" ]; then
    echo "$c 已经是 RUNNING，跳过启动"
  else
    echo "尝试启动 $c ..."
    if lxc start "$c"; then
      echo "$c 启动成功"
    else
      echo "$c 启动失败，显示日志："
      lxc info "$c" --show-log || true
    fi
  fi
done

echo
echo "========== 最终容器状态 =========="
lxc list

echo
echo "修复流程完成"
