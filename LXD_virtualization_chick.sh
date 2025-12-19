#!/usr/bin/env bash
# from https://github.com/oneclickvirt/lxd
# ./LXD_virtualization_chick.sh <prefix> <count>
# fixed: 2025-12-19

set -Eeuo pipefail

cd /root >/dev/null 2>&1 || exit 1

# ---------- args ----------
if [[ $# -lt 2 ]]; then
  echo "用法: $0 <prefix> <count>"
  echo "示例: $0 xsxj 10"
  exit 1
fi

PREFIX="$1"
COUNT="$2"

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [[ "$COUNT" -le 0 ]]; then
  echo "错误: count 必须是正整数"
  exit 1
fi

# ---------- base deps ----------
if ! command -v lxc >/dev/null 2>&1; then
  echo "未找到 lxc 命令，请先安装 LXD：apt-get install -y lxd"
  exit 1
fi
if ! command -v lxd >/dev/null 2>&1; then
  echo "未找到 lxd 命令，请先安装/确认 LXD 服务正常"
  exit 1
fi

mkdir -p /usr/local/bin

# ---------- detect China network ----------
CN=false
check_china() {
  echo "IP area being detected ......"
  local j=""
  if j="$(curl -m 6 -fsS https://ipapi.co/json 2>/dev/null || true)"; then
    if echo "$j" | grep -qi "China"; then
      echo "根据 ipapi.co 信息，当前IP可能在中国，将优先使用国内镜像脚本"
      CN=true
      return 0
    fi
  fi

  local c=""
  c="$(curl -m 6 -fsS cip.cc 2>/dev/null || true)"
  if echo "$c" | grep -q "中国"; then
    echo "根据 cip.cc 信息，当前IP可能在中国，将优先使用国内镜像脚本"
    CN=true
  fi
}
check_china

# ---------- configurable defaults ----------
DISK_SIZE="${LXD_DISK_SIZE:-5GB}"
MEM_LIMIT="${LXD_MEM_LIMIT:-256MiB}"
CPU_LIMIT="${LXD_CPU_LIMIT:-1}"
CPU_ALLOWANCE="${LXD_CPU_ALLOWANCE:-50%}"
DISK_READ_LIMIT="${LXD_DISK_READ_LIMIT:-500MB}"
DISK_WRITE_LIMIT="${LXD_DISK_WRITE_LIMIT:-500MB}"
NET_LIMIT="${LXD_NET_LIMIT:-1024Mbit}"
BRIDGE="${LXD_BRIDGE:-lxdbr0}"
UPLINK_IF="${LXD_UPLINK_IF:-eth0}"

# 是否自动初始化 LXD（默认开启）
AUTO_INIT="${LXD_AUTO_INIT:-1}"

# blocked ports
blocked_ports=(3389 8888 54321 65432)

# ---------- helpers ----------
log() { echo "[$(date +'%F %T')] $*"; }

iptables_add_once() {
  # 传入完整规则，但用 -C 检查时需要去掉 -I/-A 之类的首参数
  # 这里简单处理：调用者用 -I FORWARD ...，我们用同样参数检查（把 -I 改成 -C）
  local args=("$@")
  if [[ "${args[0]}" == "-I" ]]; then
    args[0]="-C"
  elif [[ "${args[0]}" == "-A" ]]; then
    args[0]="-C"
  fi

  if iptables --ipv4 "${args[@]}" >/dev/null 2>&1; then
    return 0
  fi
  iptables --ipv4 "$@"
}

ensure_lxd_initialized() {
  # 如果 storage list 都失败，说明很可能没 init
  if lxc storage list >/dev/null 2>&1; then
    return 0
  fi

  log "检测到 LXD 可能尚未初始化（lxc storage list 失败）。"
  if [[ "$AUTO_INIT" == "1" ]]; then
    log "执行: lxd init --auto"
    lxd init --auto >/dev/null 2>&1 || {
      echo "错误: 自动初始化失败。请手动执行: lxd init"
      exit 1
    }
  else
    echo "错误: LXD 未初始化。请先执行: lxd init"
    exit 1
  fi

  # 再确认一次
  lxc storage list >/dev/null 2>&1 || {
    echo "错误: LXD 初始化后仍不可用，请检查 lxd 服务与存储配置。"
    exit 1
  }
}

ensure_image_remote() {
  # 目标：得到一个可用的 remote 前缀，并拼出镜像名
  # 优先 images:debian/12，其次 ubuntu:debian/12
  local have_images="0"
  local have_ubuntu="0"

  if lxc remote list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "images"; then
    have_images="1"
  fi
  if lxc remote list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "ubuntu"; then
    have_ubuntu="1"
  fi

  if [[ "$have_images" == "1" ]]; then
    echo "images:debian/12"
    return 0
  fi

  # 如果没有 images 但有 ubuntu，直接用 ubuntu
  if [[ "$have_ubuntu" == "1" ]]; then
    echo "ubuntu:debian/12"
    return 0
  fi

  # 两个都没有：尝试添加 images remote
  log "未找到 images/ubuntu remote，尝试添加 images remote..."
  lxc remote add images https://images.linuxcontainers.org --protocol=simplestreams >/dev/null 2>&1 || true

  if lxc remote list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "images"; then
    echo "images:debian/12"
    return 0
  fi

  echo "错误: 无法获取可用镜像 remote（images/ubuntu）。请检查网络或手动配置 lxc remote。"
  exit 1
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

change_mirrors_if_cn() {
  local name="$1"
  if [[ "$CN" == true ]]; then
    container_apt_install "$name"
    lxc exec "$name" -- bash -lc 'curl -fsSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o /root/ChangeMirrors.sh'
    lxc exec "$name" -- bash -lc 'chmod +x /root/ChangeMirrors.sh && dos2unix /root/ChangeMirrors.sh'
    lxc exec "$name" -- bash -lc '/root/ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips'
    lxc exec "$name" -- bash -lc 'rm -f /root/ChangeMirrors.sh'
  fi
}

set_container_limits() {
  local name="$1"

  lxc config set "$name" limits.cpu="$CPU_LIMIT"
  lxc config set "$name" limits.memory="$MEM_LIMIT"
  lxc config set "$name" limits.cpu.allowance "$CPU_ALLOWANCE"
  lxc config set "$name" limits.cpu.priority 0

  lxc config set "$name" limits.memory.swap true
  lxc config set "$name" limits.memory.swap.priority 1
  lxc config set "$name" security.nesting true

  # root 磁盘配额（有些后端不支持会失败，这里不让脚本中断）
  lxc config device set "$name" root size="$DISK_SIZE" >/dev/null 2>&1 || true
  lxc config device set "$name" root limits.read "$DISK_READ_LIMIT" >/dev/null 2>&1 || true
  lxc config device set "$name" root limits.write "$DISK_WRITE_LIMIT" >/dev/null 2>&1 || true

  # 网卡限速（override 若失败也不终止）
  lxc config device override "$name" eth0 limits.egress="$NET_LIMIT" >/dev/null 2>&1 || true
  lxc config device override "$name" eth0 limits.ingress="$NET_LIMIT" >/dev/null 2>&1 || true
  lxc config device override "$name" eth0 limits.max="$NET_LIMIT" >/dev/null 2>&1 || true
}

apply_blocked_ports() {
  for port in "${blocked_ports[@]}"; do
    iptables_add_once -I FORWARD -i "$BRIDGE" -o "$UPLINK_IF" -p tcp --dport "$port" -j DROP || true
    iptables_add_once -I FORWARD -i "$BRIDGE" -o "$UPLINK_IF" -p udp --dport "$port" -j DROP || true
  done
}

# ---------- main ----------
ensure_lxd_initialized
IMAGE_REMOTE="$(ensure_image_remote)"
log "使用镜像: $IMAGE_REMOTE"

ensure_host_helper_scripts
apply_blocked_ports

: > /root/log

BASE="${PREFIX}"
if lxc info "$BASE" >/dev/null 2>&1; then
  log "检测到已存在基础容器: $BASE，删除后重建"
  lxc delete -f "$BASE" >/dev/null 2>&1 || true
fi

log "创建基础容器: $BASE"
lxc init "$IMAGE_REMOTE" "$BASE" -c limits.cpu="$CPU_LIMIT" -c limits.memory="$MEM_LIMIT"
set_container_limits "$BASE"

# 确认基础容器存在
if ! lxc info "$BASE" >/dev/null 2>&1; then
  echo "错误: 基础容器 $BASE 创建失败，脚本终止。"
  exit 1
fi

for ((a=1; a<=COUNT; a++)); do
  name="${PREFIX}${a}"

  if lxc info "$name" >/dev/null 2>&1; then
    log "检测到已存在容器: $name，删除后重建"
    lxc delete -f "$name" >/dev/null 2>&1 || true
  fi

  lxc copy "$BASE" "$name"
  set_container_limits "$name"

  sshn=$((20000 + a))
  nat1=$((30000 + (a - 1) * 24 + 1))
  nat2=$((30000 + a * 24))

  ori="$(date +%s%N | md5sum | awk '{print $1}')"
  passwd="${ori:2:9}"

  lxc start "$name"
  sleep 1

  change_mirrors_if_cn "$name"
  container_apt_install "$name"

  lxc file push /root/ssh_bash.sh "$name"/root/
  lxc exec "$name" -- bash -lc 'chmod +x /root/ssh_bash.sh && dos2unix /root/ssh_bash.sh'
  lxc exec "$name" -- bash -lc "/root/ssh_bash.sh '$passwd'"

  lxc file push /root/config.sh "$name"/root/
  lxc exec "$name" -- bash -lc 'chmod +x /root/config.sh && dos2unix /root/config.sh'
  lxc exec "$name" -- bash -lc '/root/config.sh'

  # proxy devices（先删旧，防重复）
  lxc config device remove "$name" ssh-port >/dev/null 2>&1 || true
  lxc config device remove "$name" nattcp-ports >/dev/null 2>&1 || true
  lxc config device remove "$name" natudp-ports >/dev/null 2>&1 || true

  lxc config device add "$name" ssh-port proxy listen=tcp:0.0.0.0:"$sshn" connect=tcp:127.0.0.1:22
  lxc config device add "$name" nattcp-ports proxy listen=tcp:0.0.0.0:"$nat1"-"$nat2" connect=tcp:127.0.0.1:"$nat1"-"$nat2"
  lxc config device add "$name" natudp-ports proxy listen=udp:0.0.0.0:"$nat1"-"$nat2" connect=udp:127.0.0.1:"$nat1"-"$nat2"

  echo "$name $sshn $passwd $nat1 $nat2" >> /root/log
  log "完成: $name  SSH:$sshn  PASS:$passwd  NAT:$nat1-$nat2"
done

rm -f /root/ssh_bash.sh /root/config.sh /root/ssh_sh.sh 2>/dev/null || true
log "全部完成。信息输出在 /root/log"
