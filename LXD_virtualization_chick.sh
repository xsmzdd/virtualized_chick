#!/usr/bin/env bash
# ./LXD_virtualization_chick.sh <prefix> <count>
# final fix: ensure container NIC + wait IP + ensure default route
# date: 2025-12-19

set -Eeuo pipefail
log() { echo "[$(date +'%F %T')] $*"; }
trap 'rc=$?; echo; echo "[FATAL] exit=$rc line=$LINENO cmd=$BASH_COMMAND" >&2; exit $rc' ERR

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

command -v lxc >/dev/null 2>&1 || { echo "未找到 lxc，请先安装：apt-get install -y lxd"; exit 1; }
command -v lxd >/dev/null 2>&1 || { echo "未找到 lxd，请先安装/确认服务"; exit 1; }

mkdir -p /usr/local/bin

# ---------- detect China ----------
CN=false
echo "IP area being detected ......"
if curl -m 6 -fsS https://ipapi.co/json 2>/dev/null | grep -qi "China"; then CN=true; fi
if curl -m 6 -fsS cip.cc 2>/dev/null | grep -q "中国"; then CN=true; fi
[[ "$CN" == true ]] && echo "检测到可能在中国，将优先使用国内镜像脚本"

# ---------- defaults ----------
DISK_SIZE="${LXD_DISK_SIZE:-5GB}"
MEM_LIMIT="${LXD_MEM_LIMIT:-256MiB}"
CPU_LIMIT="${LXD_CPU_LIMIT:-1}"
CPU_ALLOWANCE="${LXD_CPU_ALLOWANCE:-50%}"
DISK_READ_LIMIT="${LXD_DISK_READ_LIMIT:-500MB}"
DISK_WRITE_LIMIT="${LXD_DISK_WRITE_LIMIT:-500MB}"
NET_LIMIT="${LXD_NET_LIMIT:-1024Mbit}"

BRIDGE="${LXD_BRIDGE:-lxdbr0}"
AUTO_INIT="${LXD_AUTO_INIT:-1}"
FORCE_LEGACY="${FORCE_LEGACY:-1}"  # 你这台机子明显 legacy 生效，默认强制 legacy

blocked_ports=(3389 8888 54321 65432)

# ---------- helpers ----------
ensure_lxd_running() {
  lxc info >/dev/null 2>&1 && return 0
  log "lxc info 失败，尝试启动 LXD daemon..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start lxd >/dev/null 2>&1 || true
    systemctl start lxd.socket >/dev/null 2>&1 || true
  fi
  for _ in 1 2 3 4 5; do
    sleep 1
    lxc info >/dev/null 2>&1 && { log "LXD daemon 已就绪"; return 0; }
  done
  echo "错误: LXD daemon 未就绪。请检查 systemctl status lxd / journalctl -u lxd"
  exit 1
}

ensure_lxd_initialized() {
  if lxc storage list >/dev/null 2>&1; then
    log "LXD 已初始化（storage 可用）"
    return 0
  fi
  log "检测到 LXD 可能尚未初始化。"
  if [[ "$AUTO_INIT" == "1" ]]; then
    log "执行: lxd init --auto"
    lxd init --auto
  else
    echo "错误: LXD 未初始化。请先执行: lxd init"
    exit 1
  fi
  lxc storage list >/dev/null 2>&1 || { echo "错误: LXD 初始化后仍不可用"; exit 1; }
  log "LXD 初始化完成"
}

remote_has() {
  local name="$1"
  if lxc remote list --format csv >/dev/null 2>&1; then
    lxc remote list --format csv 2>/dev/null | awk -F, '{gsub(/\r/,""); print $1}' | grep -Fxq "$name"
    return $?
  fi
  lxc remote list 2>/dev/null | tr -d '|' | awk '{print $1}' | sed 's/\r//g' | grep -Fxq "$name"
}

ensure_image_remote() {
  remote_has "images" && { echo "images:debian/12"; return 0; }
  remote_has "ubuntu" && { echo "ubuntu:debian/12"; return 0; }
  log "未找到 images/ubuntu remote，尝试添加 images remote..."
  lxc remote add images https://images.linuxcontainers.org --protocol=simplestreams >/dev/null 2>&1 || true
  remote_has "images" && { echo "images:debian/12"; return 0; }
  remote_has "ubuntu" && { echo "ubuntu:debian/12"; return 0; }
  echo "错误: 找不到可用 remote（images/ubuntu）"
  exit 1
}

detect_uplink_if() {
  local dev
  dev="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  [[ -z "$dev" ]] && dev="eth0"
  echo "$dev"
}

choose_ipt() {
  if [[ "$FORCE_LEGACY" == "1" ]] && command -v iptables-legacy >/dev/null 2>&1; then
    echo "iptables-legacy"
    return 0
  fi
  echo "iptables"
}

ipt_insert_once() {
  local IPT="$1" table="$2" chain="$3"; shift 3
  if "$IPT" -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
    return 0
  fi
  "$IPT" -t "$table" -I "$chain" 1 "$@"
}

ipt_append_once() {
  local IPT="$1" table="$2" chain="$3"; shift 3
  if "$IPT" -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
    return 0
  fi
  "$IPT" -t "$table" -A "$chain" "$@"
}

ensure_lxd_network_and_nat() {
  if ! lxc network show "$BRIDGE" >/dev/null 2>&1; then
    log "未发现网络 $BRIDGE，创建 NAT 网络..."
    lxc network create "$BRIDGE" ipv4.address=auto ipv4.nat=true ipv6.address=none
  fi

  # 确保 default profile 有网卡并绑定到 BRIDGE
  if ! lxc profile show default 2>/dev/null | grep -qE 'name:\s*eth0'; then
    log "default profile 未发现 eth0，添加并绑定到 $BRIDGE"
    lxc profile device add default eth0 nic name=eth0 network="$BRIDGE"
  else
    # 如果 eth0 不是绑定该 bridge，删了重加（稳）
    if ! lxc profile show default 2>/dev/null | awk '
      $1=="name:" && $2=="eth0"{ineth=1}
      ineth && $1=="network:"{print $2; exit}
      ineth && $1=="parent:"{print $2; exit}
    ' | grep -qx "$BRIDGE"; then
      log "default profile eth0 未绑定到 $BRIDGE，重建该设备"
      lxc profile device remove default eth0 >/dev/null 2>&1 || true
      lxc profile device add default eth0 nic name=eth0 network="$BRIDGE"
    fi
  fi

  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

  IPT="$(choose_ipt)"
  UPLINK="$(detect_uplink_if)"
  log "使用 $IPT 写规则；检测到外网口: $UPLINK"

  local v4cidr subnet
  v4cidr="$(lxc network get "$BRIDGE" ipv4.address 2>/dev/null || true)" # e.g. 10.0.90.1/24
  subnet="$(python3 - <<PY
import ipaddress
print(ipaddress.ip_interface("$v4cidr").network.with_prefixlen)
PY
)"

  # NAT + FORWARD（插到最前，避免被其它链路抢先处理）
  ipt_append_once "$IPT" nat POSTROUTING -s "$subnet" -o "$UPLINK" -j MASQUERADE || true
  ipt_insert_once "$IPT" filter FORWARD -i "$BRIDGE" -o "$UPLINK" -j ACCEPT || true
  ipt_insert_once "$IPT" filter FORWARD -i "$UPLINK" -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true

  # 封禁端口（只封容器 -> 外网方向）
  for port in "${blocked_ports[@]}"; do
    ipt_insert_once "$IPT" filter FORWARD -i "$BRIDGE" -o "$UPLINK" -p tcp --dport "$port" -j DROP || true
    ipt_insert_once "$IPT" filter FORWARD -i "$BRIDGE" -o "$UPLINK" -p udp --dport "$port" -j DROP || true
  done

  export IPT UPLINK subnet
}

ensure_host_helper_scripts() {
  if [[ ! -f /usr/local/bin/ssh_bash.sh ]]; then
    curl -fsSL https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/ssh_bash.sh -o /usr/local/bin/ssh_bash.sh
    chmod 755 /usr/local/bin/ssh_bash.sh
  fi
  cp -f /usr/local/bin/ssh_bash.sh /root/ssh_bash.sh

  if [[ ! -f /usr/local/bin/config.sh ]]; then
    curl -fsSL https://raw.githubusercontent.com/oneclickvirt/lxd/main/scripts/config.sh -o /usr/local/bin/config.sh
    chmod 755 /usr/local/bin/config.sh
  fi
  cp -f /usr/local/bin/config.sh /root/config.sh
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

  lxc config device set "$name" root size="$DISK_SIZE" >/dev/null 2>&1 || true
  lxc config device set "$name" root limits.read "$DISK_READ_LIMIT" >/dev/null 2>&1 || true
  lxc config device set "$name" root limits.write "$DISK_WRITE_LIMIT" >/dev/null 2>&1 || true

  lxc config device override "$name" eth0 limits.egress="$NET_LIMIT" >/dev/null 2>&1 || true
  lxc config device override "$name" eth0 limits.ingress="$NET_LIMIT" >/dev/null 2>&1 || true
  lxc config device override "$name" eth0 limits.max="$NET_LIMIT" >/dev/null 2>&1 || true
}

ensure_instance_nic() {
  # 有些场景 profile 生效不及时/被实例覆盖，这里对实例做兜底
  local name="$1"
  if ! lxc config device show "$name" | grep -qE '^eth0:'; then
    log "实例 $name 未发现 eth0 设备，添加到 $BRIDGE"
    lxc config device add "$name" eth0 nic name=eth0 network="$BRIDGE"
  fi
}

wait_container_has_route() {
  # 关键：解决你现在的 “Network is unreachable”
  local name="$1"

  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    # 1) 确认拿到 IPv4
    if lxc exec "$name" -- bash -lc "ip -4 addr show dev eth0 | grep -q 'inet '" >/dev/null 2>&1; then
      # 2) 确认有 default route
      if lxc exec "$name" -- bash -lc "ip route | grep -q '^default '" >/dev/null 2>&1; then
        return 0
      fi
      # 尝试拉起网络（Debian 常见 ifupdown）
      lxc exec "$name" -- bash -lc "ip link set eth0 up >/dev/null 2>&1 || true; if command -v ifup >/dev/null 2>&1; then ifdown eth0 >/dev/null 2>&1 || true; ifup eth0 >/dev/null 2>&1 || true; fi" || true
    else
      # 没拿到地址也尝试 ifup
      lxc exec "$name" -- bash -lc "ip link set eth0 up >/dev/null 2>&1 || true; if command -v ifup >/dev/null 2>&1; then ifup eth0 >/dev/null 2>&1 || true; fi" || true
    fi
    sleep 1
  done

  echo "错误: 容器 $name 仍未获得 IPv4/默认路由（导致 Network is unreachable）"
  echo "请在宿主机执行：lxc list $name -c ns4 && lxc exec $name -- ip r"
  exit 1
}

fix_container_net_and_dns_check() {
  local name="$1"

  ensure_instance_nic "$name"
  wait_container_has_route "$name"

  # 先测出网
  lxc exec "$name" -- bash -lc "ping -c1 -W1 1.1.1.1 >/dev/null 2>&1" || {
    echo "错误: 容器 $name 无法 ping 通 1.1.1.1（仍然无法出网）"
    echo "宿主机检查：$IPT -t nat -S | grep MASQUERADE 以及 $IPT -S FORWARD"
    exit 1
  }

  # 写公共 DNS
  lxc exec "$name" -- bash -lc "printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:1 attempts:2\n' > /etc/resolv.conf" || true

  # 测解析
  lxc exec "$name" -- bash -lc "getent hosts deb.debian.org >/dev/null 2>&1" || {
    echo "错误: 容器 $name 仍无法解析 deb.debian.org（DNS 不通）"
    exit 1
  }
}

container_apt_install() {
  local name="$1"
  fix_container_net_and_dns_check "$name"
  lxc exec "$name" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get update -y'
  lxc exec "$name" -- bash -lc 'export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends curl dos2unix'
}

change_mirrors_if_cn() {
  local name="$1"
  if [[ "$CN" == true ]]; then
    container_apt_install "$name"
    lxc exec "$name" -- bash -lc 'curl -fsSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o /root/ChangeMirrors.sh'
    lxc exec "$name" -- bash -lc 'chmod +x /root/ChangeMirrors.sh'
    lxc exec "$name" -- bash -lc '/root/ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips'
    lxc exec "$name" -- bash -lc 'rm -f /root/ChangeMirrors.sh'
  fi
}

# ---------- main ----------
log "Step 1/7: 确保 LXD daemon 运行"
ensure_lxd_running

log "Step 2/7: 确保 LXD 已初始化"
ensure_lxd_initialized

log "Step 3/7: 修复/确保 LXD NAT 网络 & 写入生效 iptables 规则"
ensure_lxd_network_and_nat

log "Step 4/7: 选择可用镜像 remote"
IMAGE_REMOTE="$(ensure_image_remote)"
log "使用镜像: $IMAGE_REMOTE"

log "Step 5/7: 准备辅助脚本"
ensure_host_helper_scripts

: > /root/log

BASE="${PREFIX}"
if lxc info "$BASE" >/dev/null 2>&1; then
  log "检测到已存在基础容器: $BASE，删除后重建"
  lxc delete -f "$BASE" >/dev/null 2>&1 || true
fi

log "Step 6/7: 创建基础容器: $BASE"
lxc init "$IMAGE_REMOTE" "$BASE" -c limits.cpu="$CPU_LIMIT" -c limits.memory="$MEM_LIMIT"
set_container_limits "$BASE"

log "Step 7/7: 批量创建 ${COUNT} 个容器"
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
  lxc exec "$name" -- bash -lc 'chmod +x /root/ssh_bash.sh'
  lxc exec "$name" -- bash -lc "/root/ssh_bash.sh '$passwd'"

  lxc file push /root/config.sh "$name"/root/
  lxc exec "$name" -- bash -lc 'chmod +x /root/config.sh'
  lxc exec "$name" -- bash -lc '/root/config.sh'

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
