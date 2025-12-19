#!/usr/bin/env bash
# from https://github.com/oneclickvirt/lxd
# ./init.sh NAT服务器前缀 数量
# fixed: 2025-12-19

set -Eeuo pipefail

cd /root >/dev/null 2>&1 || exit 1

# ---------- basic checks ----------
if [[ $# -lt 2 ]]; then
  echo "用法: $0 <prefix> <count>"
  echo "示例: $0 nat 5"
  exit 1
fi

PREFIX="$1"
COUNT="$2"

if ! command -v lxc >/dev/null 2>&1; then
  echo "未找到 lxc 命令，请先安装并初始化 LXD (lxd init)。"
  exit 1
fi

# ensure /usr/local/bin exists
mkdir -p /usr/local/bin

# ---------- detect China network ----------
CN=false
check_china() {
  echo "IP area being detected ......"
  if [[ -n "${CN:-}" && "${CN}" == "true" ]]; then
    CN=true
    return 0
  fi

  # ipapi.co
  local j=""
  if j="$(curl -m 6 -fsS https://ipapi.co/json 2>/dev/null || true)"; then
    if echo "$j" | grep -qi "China"; then
      echo "根据 ipapi.co 信息，当前IP可能在中国，使用中国镜像完成相关组件安装"
      CN=true
      return 0
    fi
  fi

  # cip.cc fallback
  local c=""
  c="$(curl -m 6 -fsS cip.cc 2>/dev/null || true)"
  if echo "$c" | grep -q "中国"; then
    echo "根据 cip.cc 信息，当前IP可能在中国，使用中国镜像完成相关组件安装"
    CN=true
  fi
}
check_china

# ---------- settings ----------
IMAGE_REMOTE="${LXD_IMAGE_REMOTE:-images:debian/12}"   # 可改回你自己的 remote
DISK_SIZE="${LXD_DISK_SIZE:-5GB}"
MEM_LIMIT="${LXD_MEM_LIMIT:-256MiB}"
CPU_LIMIT="${LXD_CPU_LIMIT:-1}"
CPU_ALLOWANCE="${LXD_CPU_ALLOWANCE:-50%}"

# Disk I/O throttle (bytes/sec). Note: iops 与 bytes/sec 同键会互相覆盖，这里只保留吞吐限制。
DISK_READ_LIMIT="${LXD_DISK_READ_LIMIT:-500MB}"
DISK_WRITE_LIMIT="${LXD_DISK_WRITE_LIMIT:-500MB}"

# Network limit
NET_LIMIT="${LXD_NET_LIMIT:-1024Mbit}"

# Bridge for iptables forward filter
BRIDGE="${LXD_BRIDGE:-lxdbr0}"
UPLINK_IF="${LXD_UPLINK_IF:-eth0}"

# blocked ports
blocked_ports=(3389 8888 54321 65432)

# ---------- helpers ----------
iptables_add_once() {
  # usage: iptables_add_once <table/chain args...>
  # example: iptables_add_once -I FORWARD -i lxdbr0 -o eth0 -p tcp --dport 3389 -j DROP
  if iptables --ipv4 -C "${@#-I }" >/dev/null 2>&1; then
    return 0
  fi
  iptables --ipv4 "$@"
}

ensure_host_helper_scripts() {
  if [[ ! -f /usr/local/bin/ssh_bash.sh ]]; then
    curl -fsSL https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/ssh_bash.sh -o /usr/local/bin/ssh_bash.sh
    chmod 755 /usr/local/bin/ssh_bash.sh
    command -v dos2unix >/dev/null 2>&1 && dos2unix /usr/local/bin/ssh_bash.sh >/dev/null 2>&1 || true
  fi
  cp -f /usr/local/bin/ssh_bash.sh /root/ssh_bash.sh

  if [[ ! -f /usr/local/bin/config.sh ]]; then
    curl -fsSL https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/config.sh -o /usr/local/bin/config.sh
    chmod 755 /usr/local/bin/config.sh
    command -v dos2unix >/dev/null 2>&1 && dos2unix /usr/local/bin/config.sh >/dev/null 2>&1 || true
  fi
  cp -f /usr/local/bin/config.sh /root/config.sh
}

container_apt_install() {
  local name="$1"
  lxc exec "$name" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update -y'
  lxc exec "$name" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends curl dos2unix'
}

set_container_limits() {
  local name="$1"

  # cpu/mem
  lxc config set "$name" limits.cpu="$CPU_LIMIT"
  lxc config set "$name" limits.memory="$MEM_LIMIT"

  # cpu allowance (choose one)
  lxc config set "$name" limits.cpu.allowance "$CPU_ALLOWANCE"
  lxc config set "$name" limits.cpu.priority 0

  # swap
  lxc config set "$name" limits.memory.swap true
  lxc config set "$name" limits.memory.swap.priority 1

  # nesting for docker
  lxc config set "$name" security.nesting true

  # disk size + IO throttle
  # 注意：root 设备名通常是 "root"，由 profile 提供；这里直接 set 即可。
  lxc config device set "$name" root size="$DISK_SIZE" || true
  lxc config device set "$name" root limits.read "$DISK_READ_LIMIT" || true
  lxc config device set "$name" root limits.write "$DISK_WRITE_LIMIT" || true

  # net limits
  lxc config device override "$name" eth0 limits.egress="$NET_LIMIT" || true
  lxc config device override "$name" eth0 limits.ingress="$NET_LIMIT" || true
  lxc config device override "$name" eth0 limits.max="$NET_LIMIT" || true
}

apply_blocked_ports() {
  for port in "${blocked_ports[@]}"; do
    # Only block forwarded traffic from containers to uplink
    # Use -i $BRIDGE for LXD bridge; adjust if your bridge differs.
    iptables_add_once -I FORWARD -i "$BRIDGE" -o "$UPLINK_IF" -p tcp --dport "$port" -j DROP || true
    iptables_add_once -I FORWARD -i "$BRIDGE" -o "$UPLINK_IF" -p udp --dport "$port" -j DROP || true
  done
}

change_mirrors_if_cn() {
  local name="$1"
  if [[ "$CN" == true ]]; then
    # 安装 curl 后再拉脚本
    container_apt_install "$name"
    lxc exec "$name" -- bash -lc 'curl -fsSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o /root/ChangeMirrors.sh'
    lxc exec "$name" -- bash -lc 'chmod +x /root/ChangeMirrors.sh && dos2unix /root/ChangeMirrors.sh'
    lxc exec "$name" -- bash -lc '/root/ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips'
    lxc exec "$name" -- bash -lc 'rm -f /root/ChangeMirrors.sh'
  fi
}

# ---------- main ----------
ensure_host_helper_scripts
apply_blocked_ports

# recreate log
: > /root/log

# Create a base container (stopped) to copy from
BASE="${PREFIX}"
if lxc info "$BASE" >/dev/null 2>&1; then
  echo "检测到已存在同名基础容器: $BASE，将先删除再创建（避免 copy/配置混乱）"
  lxc delete -f "$BASE" || true
fi

echo "创建基础容器: $BASE (image: $IMAGE_REMOTE)"
lxc init "$IMAGE_REMOTE" "$BASE" -c limits.cpu="$CPU_LIMIT" -c limits.memory="$MEM_LIMIT"

set_container_limits "$BASE"

# Batch create containers
for ((a=1; a<=COUNT; a++)); do
  name="${PREFIX}${a}"

  if lxc info "$name" >/dev/null 2>&1; then
    echo "检测到已存在容器: $name，先删除再重建"
    lxc delete -f "$name" || true
  fi

  lxc copy "$BASE" "$name"

  # ports
  sshn=$((20000 + a))
  nat1=$((30000 + (a - 1) * 24 + 1))
  nat2=$((30000 + a * 24))

  # password
  ori="$(date +%s%N | md5sum | awk '{print $1}')"
  passwd="${ori:2:9}"

  # start container
  lxc start "$name"
  sleep 1

  # CN mirrors (optional)
  change_mirrors_if_cn "$name"

  # install deps
  container_apt_install "$name"

  # push scripts + run
  lxc file push /root/ssh_bash.sh "$name"/root/
  lxc exec "$name" -- bash -lc 'chmod +x /root/ssh_bash.sh && dos2unix /root/ssh_bash.sh'
  lxc exec "$name" -- bash -lc "/root/ssh_bash.sh '$passwd'"

  lxc file push /root/config.sh "$name"/root/
  lxc exec "$name" -- bash -lc 'chmod +x /root/config.sh && dos2unix /root/config.sh'
  lxc exec "$name" -- bash -lc '/root/config.sh'

  # proxy devices (delete old if exist to avoid duplicate errors)
  lxc config device remove "$name" ssh-port >/dev/null 2>&1 || true
  lxc config device remove "$name" nattcp-ports >/dev/null 2>&1 || true
  lxc config device remove "$name" natudp-ports >/dev/null 2>&1 || true

  lxc config device add "$name" ssh-port proxy listen=tcp:0.0.0.0:"$sshn" connect=tcp:127.0.0.1:22
  lxc config device add "$name" nattcp-ports proxy listen=tcp:0.0.0.0:"$nat1"-"$nat2" connect=tcp:127.0.0.1:"$nat1"-"$nat2"
  lxc config device add "$name" natudp-ports proxy listen=udp:0.0.0.0:"$nat1"-"$nat2" connect=udp:127.0.0.1:"$nat1"-"$nat2"

  echo "$name $sshn $passwd $nat1 $nat2" >> /root/log
  echo "完成: $name  SSH:$sshn  PASS:$passwd  NAT:$nat1-$nat2"
done

# cleanup local copies
rm -f /root/ssh_bash.sh /root/config.sh /root/ssh_sh.sh 2>/dev/null || true

echo "全部完成。输出信息在 /root/log"
