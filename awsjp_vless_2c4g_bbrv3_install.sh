#!/bin/sh
set -u
umask 022

# ================================================================
# VPS 一键初始化：XanMod(BBRv3) + fq + 基础调优
# 适用：Debian 11+ / Ubuntu 20.04+，x86_64，KVM 或裸机
#
#   sh vps-setup.sh              # 安装 XanMod(LTS) + 调优，不自动重启
#   sh vps-setup.sh --reboot     # 完成后自动重启
#   sh vps-setup.sh --mainline   # 用 XanMod 主线分支（默认 LTS）
#   sh vps-setup.sh --no-xanmod  # 只做调优，不动内核
#   sh vps-setup.sh --no-bbr     # 跳过网络调优
#
# ---- 相对原脚本的改动 ----
#  [1] 新增 install_xanmod()：CPU 等级检测 + GPG 源 + LTS/主线切换
#  [2] 修复容器误判：systemd-detect-virt 打印 none 时非 0 退出
#  [3] 新增 find_xanmod_entry()/set_grub_default_xanmod()：按标题
#      把 GRUB 默认项指向 XanMod，避免版本排序继续启动 Debian 内核
#  [4] 新增 check_cloud_drivers()：EC2 上校验 ENA/NVMe 驱动
#  [5] sysctl 移除 tcp_fack/tcp_early_retrans/tcp_frto，mtu_probing=1
#  [6] ICMP 规则从整段 DROP 改为只丢 ping，保留 frag-needed
#  [7] 新增 vps-net-tune.service：开机对 mq 子队列套 fq
#  [8] apt 源 suite 改用发行版代号（releases 已 404）
#  [9] GPG 密钥改为多源回退：官方 → keyserver.ubuntu.com → keys.openpgp.org
#      并校验指纹 D38D7D1DA1349567ADED882D86F7D09EE734E623
# ================================================================

LOG_NAME="$(basename "${0:-}" 2>/dev/null || true)"
[ -n "$LOG_NAME" ] || LOG_NAME="vps-setup.sh"
LOG="/tmp/${LOG_NAME}.log"
TIMEOUT_NYANPASS=600
C_G=$(printf '\033[0;32m');C_Y=$(printf '\033[1;33m');C_R=$(printf '\033[0;31m');C_N=$(printf '\033[0m')
i(){ printf '%s\n' "${C_G}[INFO]${C_N} $*"|tee -a "$LOG"; }
w(){ printf '%s\n' "${C_Y}[WARN]${C_N} $*"|tee -a "$LOG"; }
e(){ printf '%s\n' "${C_R}[ERR ]${C_N} $*"|tee -a "$LOG"; }
has(){ command -v "$1" >/dev/null 2>&1; }
root_check(){ [ "$(id -u)" -eq 0 ] || { e "需要root权限"; exit 1; }; }

DO_XANMOD=true
DO_BBR=true
DO_REBOOT=false
XANMOD_BRANCH=lts
NEED_REBOOT=false
CPU_LEVEL=3

usage(){
  cat <<'USAGE'
用法: sh vps-setup.sh [选项]
  --reboot      全部完成后自动重启
  --mainline    使用 XanMod 主线分支（默认 LTS）
  --no-xanmod   跳过内核安装，只做网络调优
  --no-bbr|-n   跳过 BBR/fq 与 sysctl 调优
  -h, --help    显示帮助
USAGE
}

parse_args(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --reboot) DO_REBOOT=true;;
      --mainline) XANMOD_BRANCH=mainline;;
      --no-xanmod) DO_XANMOD=false;;
      --no-bbr|-n) DO_BBR=false;;
      -h|--help) usage; exit 0;;
      *) w "未知参数：$1";;
    esac
    shift
  done
}

detect_env(){
  OS_ID=unknown; OS_VER=""; OS_CODENAME=""
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-}"; OS_CODENAME="${VERSION_CODENAME:-}"
  fi
  if [ -z "$OS_CODENAME" ] && has lsb_release; then
    OS_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
  fi
  case "$OS_ID" in
    debian|ubuntu) ;;
    *) w "未在 Debian/Ubuntu 上验证过（当前 $OS_ID），继续尝试";;
  esac
  ARCH="$(uname -m)"
  if [ "$ARCH" != "x86_64" ]; then
    w "XanMod 仅提供 x86_64，当前 $ARCH，已跳过内核安装"
    DO_XANMOD=false
  fi
  VIRT=""
  if has systemd-detect-virt; then
    # 未检测到容器时该命令会打印 none 并以非 0 退出，不能再加 || echo none
    VIRT="$(systemd-detect-virt --container 2>/dev/null || true)"
  fi
  [ -n "$VIRT" ] || VIRT=none
  if [ -r /run/systemd/container ]; then
    VIRT="$(cat /run/systemd/container 2>/dev/null || true)"
    [ -n "$VIRT" ] || VIRT=none
  fi
  if [ "$VIRT" != "none" ]; then
    w "检测到容器环境（$VIRT），内核由宿主机共享，已跳过 XanMod"
    DO_XANMOD=false
  fi
  if [ -e /proc/user_beancounters ]; then
    w "OpenVZ 环境，无法更换内核，已跳过 XanMod"
    DO_XANMOD=false
  fi
  CPU_FLAGS="$(awk -F: '/^flags[[:space:]]*:/{sub(/^[[:space:]]*/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
}

have_all_flags(){
  for f in "$@"; do
    case " $CPU_FLAGS " in *" $f "*) ;; *) return 1;; esac
  done
  return 0
}

cpu_level(){
  if have_all_flags avx512f avx512bw avx512cd avx512dq avx512vl; then echo 4
  elif have_all_flags avx2 bmi1 bmi2 fma movbe abm; then echo 3
  elif have_all_flags sse4_2 ssse3 cx16 sahf popcnt; then echo 2
  else echo 1; fi
}

check_disk(){
  fm="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
  case "${fm:-x}" in ''|*[!0-9]*) fm=0;; esac
  [ "$fm" -lt 500 ] && w "根分区剩余 ${fm}MB，XanMod 安装并保留旧内核约需 400MB"
  if has mountpoint && mountpoint -q /boot 2>/dev/null; then
    fb="$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')"
    case "${fb:-x}" in ''|*[!0-9]*) fb=0;; esac
    [ "$fb" -lt 200 ] && w "/boot 剩余 ${fb}MB，可能不够"
  fi
  return 0
}

check_secure_boot(){
  if has mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
    w "Secure Boot 已开启：XanMod 内核未签名，可能无法引导，请先关闭"
  fi
  return 0
}

configure_ssh(){
  i "配置SSH..."
  # 把下面的 *** 换成实际密码
  echo 'root:>Qx$qpG>1.KF3TWHv>Z='|chpasswd 2>/dev/null && i "root密码已设置" || w "root密码设置失败"
  passwd -u root >/dev/null 2>&1 || usermod -U root >/dev/null 2>&1 || true
  if has getent && has usermod; then
    rs="$(getent passwd root|cut -d: -f7 2>/dev/null||echo "")"
    case "$rs" in
      /usr/sbin/nologin|/sbin/nologin|/bin/false) usermod -s /bin/bash root >/dev/null 2>&1 || true;;
    esac
  fi
  cfg="/etc/ssh/sshd_config";dir="/etc/ssh/sshd_config.d";drop="$dir/99-root-password-login.conf"
  [ -f "$cfg" ] || { e "缺少 $cfg"; return 1; }
  b1="${cfg}.bak.$(date +%s)";cp "$cfg" "$b1" 2>/dev/null || true
  b2="${drop}.bak.$(date +%s)";[ -f "$drop" ] && cp "$drop" "$b2" 2>/dev/null || true
  sed -i '/^[[:space:]]*Port[[:space:]]/d' "$cfg" 2>/dev/null || true
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' "$cfg" 2>/dev/null || true
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' "$cfg" 2>/dev/null || true
  sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/g' "$cfg" 2>/dev/null || true
  sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/g' "$cfg" 2>/dev/null || true
  sed -i 's/^#\?UsePAM.*/UsePAM yes/g' "$cfg" 2>/dev/null || true
  grep -qE '^[[:space:]]*PermitRootLogin[[:space:]]+' "$cfg" || echo "PermitRootLogin yes">>"$cfg"
  grep -qE '^[[:space:]]*PasswordAuthentication[[:space:]]+' "$cfg" || echo "PasswordAuthentication yes">>"$cfg"
  grep -qE '^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+' "$cfg" || echo "KbdInteractiveAuthentication yes">>"$cfg"
  grep -qE '^[[:space:]]*UsePAM[[:space:]]+' "$cfg" || echo "UsePAM yes">>"$cfg"
  mkdir -p "$dir" 2>/dev/null || true
  cat > "$drop" <<'EOF'
Port 50100
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
PubkeyAuthentication yes
Match all
    PermitRootLogin yes
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    PubkeyAuthentication yes
EOF
  if ! has sshd || ! sshd -t >/dev/null 2>&1; then
    e "sshd校验失败，回滚";cp "$b1" "$cfg" 2>/dev/null || true
    if [ -f "$b2" ]; then cp "$b2" "$drop" 2>/dev/null || true; else rm -f "$drop"; fi
    return 1
  fi
  if has systemctl; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || {
      e "SSH重载失败，回滚";cp "$b1" "$cfg" 2>/dev/null || true
      if [ -f "$b2" ]; then cp "$b2" "$drop" 2>/dev/null || true; else rm -f "$drop"; fi
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
      return 1
    }
  fi
  i "SSH配置完成（端口 50100）"
}

find_xanmod_entry(){
  # 输出 GRUB 的 "子菜单标题>菜单项标题"；顶层菜单项则只输出标题。
  # 用标题而不是序号：内核升级后标题找不到时 GRUB 会回退到默认项，
  # 不会像序号漂移那样误进 recovery mode。
  awk -F"'" '
    BEGIN { insub=0; stitle="" }
    /^[[:space:]]*submenu[[:space:]]/ {
      if (insub==0) { insub=1; stitle=$2 }
      next
    }
    /^[[:space:]]*menuentry[[:space:]]/ {
      t=$2
      if (insub==1) {
        if (tolower(t) ~ /xanmod/) { print stitle ">" t; exit }
      } else {
        if (tolower(t) ~ /xanmod/) { print t; exit }
      }
      next
    }
    /^}/ { insub=0 }
  ' /boot/grub/grub.cfg 2>/dev/null
}

set_grub_default_xanmod(){
  [ -r /boot/grub/grub.cfg ] || return 1
  [ -f /etc/default/grub ] || return 1
  has update-grub || return 1
  epath="$(find_xanmod_entry)"
  [ -n "$epath" ] || return 1
  cp -a /etc/default/grub "/etc/default/grub.bak.$(date +%s)" 2>/dev/null || true
  tmp="$(mktemp)" || return 1
  grep -v '^[[:space:]]*GRUB_DEFAULT=' /etc/default/grub > "$tmp" 2>/dev/null || true
  printf 'GRUB_DEFAULT="%s"\n' "$epath" >> "$tmp"
  cat "$tmp" > /etc/default/grub
  rm -f "$tmp"
  if ! update-grub >>"$LOG" 2>&1; then
    w "update-grub 失败，GRUB 默认项可能未生效"
    return 1
  fi
  i "GRUB 默认启动项已设为 $epath（XanMod）"
  return 0
}

check_cloud_drivers(){
  kv="$1"
  # 只对 AWS EC2 做 ENA/NVMe 检查，避免换内核后失联
  if [ -r /sys/devices/virtual/dmi/id/sys_vendor ]; then
    grep -qi 'amazon' /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || return 0
  else
    return 0
  fi
  cfg="/boot/config-$kv"
  [ -r "$cfg" ] || { w "未找到 $cfg，无法校验 ENA/NVMe 驱动"; return 0; }
  miss=""
  for opt in CONFIG_ENA_ETHERNET CONFIG_BLK_DEV_NVME; do
    grep -qE "^${opt}=(y|m)$" "$cfg" || miss="$miss $opt"
  done
  if [ -n "$miss" ]; then
    w "新内核缺少${miss}，在 EC2 上可能无法联网/挂盘，请勿直接重启"
  else
    i "云驱动检查通过（ENA/NVMe）"
  fi
  return 0
}

key_install_file(){
  src="$1"; dst="$2"
  rm -f "$dst"
  gpg --dearmor --yes -o "$dst" "$src" 2>/dev/null && return 0
  # 已经是二进制 keyring 的情况
  gpg --show-keys "$src" >/dev/null 2>&1 && cp "$src" "$dst" && return 0
  rm -f "$dst"
  return 1
}

import_xanmod_key(){
  kfile=/etc/apt/keyrings/xanmod-archive-keyring.gpg
  fpr_want=D38D7D1DA1349567ADED882D86F7D09EE734E623
  install -d -m 0755 /etc/apt/keyrings

  if [ -s "$kfile" ] && gpg --show-keys "$kfile" >/dev/null 2>&1; then
    fpr_old="$(gpg --show-keys --with-colons "$kfile" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
    [ "$fpr_old" = "$fpr_want" ] && return 0
  fi

  ktmp="$(mktemp)" || return 1
  kok=0

  # 1) 本地预置文件（浏览器下载后 scp 上来）
  for f in /root/xanmod-archive.key /root/xanmod.key /root/archive.key; do
    if [ -s "$f" ] && key_install_file "$f" "$kfile"; then
      i "使用本地密钥文件 $f"
      kok=1; break
    fi
  done

  # 2) 官方地址（部分 IP 会被 Cloudflare 拦成 403）
  if [ "$kok" = 0 ]; then
    for u in https://dl.xanmod.org/archive.key https://dl.xanmod.org/gpg.key; do
      if curl -fsSL -A 'Mozilla/5.0' --max-time 30 "$u" -o "$ktmp" 2>>"$LOG" \
         && [ -s "$ktmp" ] && key_install_file "$ktmp" "$kfile"; then
        i "已从 $u 导入密钥"
        kok=1; break
      fi
    done
  fi

  # 3) Ubuntu keyserver（走 keyserver.ubuntu.com，绕开 dl.xanmod.org）
  if [ "$kok" = 0 ]; then
    u='https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x86F7D09EE734E623'
    if curl -fsSL --max-time 30 "$u" -o "$ktmp" 2>>"$LOG" \
       && [ -s "$ktmp" ] && key_install_file "$ktmp" "$kfile"; then
      i "已从 keyserver.ubuntu.com 导入密钥"
      kok=1
    fi
  fi

  # 4) keys.openpgp.org
  if [ "$kok" = 0 ]; then
    u='https://keys.openpgp.org/vks/v1/by-fingerprint/D38D7D1DA1349567ADED882D86F7D09EE734E623'
    if curl -fsSL --max-time 30 "$u" -o "$ktmp" 2>>"$LOG" \
       && [ -s "$ktmp" ] && key_install_file "$ktmp" "$kfile"; then
      i "已从 keys.openpgp.org 导入密钥"
      kok=1
    fi
  fi

  rm -f "$ktmp"
  [ "$kok" = 1 ] || return 1

  # 校验指纹，防止拿到错误的 key
  fpr_got="$(gpg --show-keys --with-colons "$kfile" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
  if [ "$fpr_got" != "$fpr_want" ]; then
    e "密钥指纹不匹配：$fpr_got"
    rm -f "$kfile"
    return 1
  fi
  chmod 0644 "$kfile"
  return 0
}

install_xanmod(){
  if uname -r | grep -q xanmod; then
    i "当前已是 XanMod 内核：$(uname -r)"
    set_grub_default_xanmod >/dev/null 2>&1 || true
    return 0
  fi
  if ls /boot/vmlinuz-*xanmod* >/dev/null 2>&1; then
    i "XanMod 已安装但尚未运行，检查并修正启动项..."
    set_grub_default_xanmod || w "未能设置 GRUB 默认启动项"
    NEED_REBOOT=true
    return 0
  fi
  if [ "$DO_XANMOD" != true ]; then
    w "按参数跳过 XanMod 安装"
    return 0
  fi
  has apt-get || { e "未找到 apt-get"; return 1; }
  export DEBIAN_FRONTEND=noninteractive

  if [ -z "$OS_CODENAME" ]; then
    e "无法确定发行版代号（/etc/os-release 里没有 VERSION_CODENAME）"
    return 1
  fi
  i "添加 XanMod 软件源（$OS_CODENAME）..."
  apt-get update -qq >>"$LOG" 2>&1 || w "apt update 返回非零，继续"
  apt-get install -y -qq ca-certificates curl gnupg dirmngr >>"$LOG" 2>&1 || true

  if ! import_xanmod_key; then
    e "XanMod GPG 密钥导入失败（dl.xanmod.org 常见 403）"
    w "手动方案：用本机浏览器打开 https://dl.xanmod.org/archive.key"
    w "保存为 /root/xanmod-archive.key 后重新运行本脚本"
    return 1
  fi

  printf '%s\n' "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org $OS_CODENAME main" > /etc/apt/sources.list.d/xanmod-release.list
  if ! apt-get update -qq >>"$LOG" 2>&1; then
    e "XanMod 源更新失败；检查 http://deb.xanmod.org/dists/$OS_CODENAME/Release 是否可访问"
    return 1
  fi

  CPU_LEVEL="$(cpu_level)"
  i "CPU 支持 x86-64-v${CPU_LEVEL}"
  if [ "$XANMOD_BRANCH" = mainline ]; then
    pfx1=linux-xanmod; pfx2=linux-xanmod-lts
  else
    pfx1=linux-xanmod-lts; pfx2=linux-xanmod
  fi
  pkg=""; use_lvl="$CPU_LEVEL"; lvl="$CPU_LEVEL"
  while [ "$lvl" -ge 1 ]; do
    for c in "${pfx1}-x64v${lvl}" "${pfx2}-x64v${lvl}"; do
      if apt-cache show "$c" >/dev/null 2>&1; then pkg="$c"; use_lvl="$lvl"; break 2; fi
    done
    lvl=$((lvl-1))
  done
  [ -n "$pkg" ] || { e "源中没有可用的 XanMod 内核包"; return 1; }
  if [ "$use_lvl" -ne "$CPU_LEVEL" ]; then
    w "XanMod 只提供到 x64v3，x64v${CPU_LEVEL} 回退为 x64v${use_lvl}（v3 代码在 v4 CPU 上完全兼容）"
  fi

  i "安装 $pkg（下载约 100MB，耐心等待）..."
  if ! apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$pkg" >>"$LOG" 2>&1; then
    e "内核安装失败，详见 $LOG 或 apt 输出"; return 1
  fi
  if ! ls /boot/vmlinuz-*xanmod* >/dev/null 2>&1; then
    e "安装结束但 /boot 下没有 xanmod 内核"; return 1
  fi
  i "内核已安装：$(ls /boot/vmlinuz-*xanmod* | tail -n 1)"
  if has update-grub; then update-grub >>"$LOG" 2>&1 || true; fi

  xkver="$(ls /boot/vmlinuz-*xanmod* | tail -n 1 | sed 's#.*/vmlinuz-##')"
  check_cloud_drivers "$xkver"

  if ! set_grub_default_xanmod; then
    w "未能自动设置 GRUB 默认启动项；重启后若 uname -r 不含 xanmod，请在 GRUB 菜单里手动选一次"
  fi
  NEED_REBOOT=true
  return 0
}

install_modules_load(){
  mkdir -p /etc/modules-load.d 2>/dev/null || true
  printf 'tcp_bbr\n' > /etc/modules-load.d/tcp_bbr.conf
  printf 'sch_fq\n' > /etc/modules-load.d/sch_fq.conf
}

install_net_tune(){
  cat > /usr/local/sbin/vps-net-tune.sh <<'NETTUNE'
#!/bin/sh
set -u
LOG=/var/log/vps-net-tune.log
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true; }

modprobe tcp_bbr 2>/dev/null || true
modprobe sch_fq 2>/dev/null || true

avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")"
cc=""
case " $avail " in
  *" bbr3 "*) cc=bbr3 ;;
  *" bbr "*)  cc=bbr ;;
esac
if [ -n "$cc" ]; then
  sysctl -w "net.ipv4.tcp_congestion_control=$cc" >/dev/null 2>&1 || cc=""
fi
sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true

set_fq(){
  d="$1"
  kind="$(tc qdisc show dev "$d" 2>/dev/null | awk '$1=="qdisc" && $4=="root"{print $2; exit}')"
  [ -n "$kind" ] || return 0
  case "$kind" in
    fq) return 0 ;;
    mq)
      handle="$(tc qdisc show dev "$d" 2>/dev/null | awk '$1=="qdisc" && $4=="root"{print $3; exit}')"
      major="${handle%%:*}"
      if [ "$major" = "0" ]; then
        tc qdisc replace dev "$d" root handle 1: mq 2>/dev/null || return 0
        major=1
      fi
      for p in $(tc qdisc show dev "$d" 2>/dev/null | awk -v m="$major" '$1=="qdisc" && $4=="parent" && $5 ~ ("^" m ":"){print $5}' | sort -u); do
        mn="${p#*:}"
        case "$mn" in ''|*[!0-9]*) continue ;; esac
        tc qdisc replace dev "$d" parent "$p" handle "$((100+mn)):" fq 2>/dev/null || true
      done
      ;;
    *)
      # 10G 以上可加 limit 32768 flow_limit 1000
      tc qdisc replace dev "$d" root fq 2>/dev/null || true
      ;;
  esac
}

if command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1; then
  for d in $(ip -o route show default 2>/dev/null | awk '{print $5}' | sort -u); do
    set_fq "$d"
  done
fi

ver="$(modinfo -F version tcp_bbr 2>/dev/null | head -n1 || true)"
[ -n "$ver" ] || ver="$(cat /sys/module/tcp_bbr/version 2>/dev/null || true)"
log "kernel=$(uname -r) cc=${cc:-none} bbr_version=${ver:-unknown}"
NETTUNE
  chmod 0755 /usr/local/sbin/vps-net-tune.sh

  cat > /etc/systemd/system/vps-net-tune.service <<'UNIT'
[Unit]
Description=Apply fq qdisc and BBR congestion control
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vps-net-tune.sh
StandardOutput=null

[Install]
WantedBy=multi-user.target
UNIT
  if has systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable vps-net-tune.service >/dev/null 2>&1 || true
  fi
  /usr/local/sbin/vps-net-tune.sh >/dev/null 2>&1 || w "fq 队列立即应用失败，重启后服务会再试"
}

configure_sysctl(){
  add_bbr="${1:-true}"
  i "写入系统参数..."
  if [ -f /etc/sysctl.conf ]; then
    cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
  fi
  cat > /etc/sysctl.conf <<'EOF'
# ============================================================
# 由 vps-setup.sh 生成。已移除内核 4.x 之后废弃的 tcp_fack /
# tcp_early_retrans / tcp_frto 等键，避免 sysctl 报错中断。
# ============================================================
fs.file-max = 6815744
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 50000000
net.core.wmem_max = 50000000
net.ipv4.tcp_rmem = 8192 131072 50000000
net.ipv4.tcp_wmem = 8192 131072 50000000
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

net.ipv4.tcp_no_metrics_save = 1
# 关掉全部 ICMP 会让 PMTU 黑洞，必须保留探测
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
# BBRv3 支持 ECN，链路可靠时可改 1；代理场景保守留 0
net.ipv4.tcp_ecn = 0

net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
EOF
  if [ "$add_bbr" = true ]; then
    cat >> /etc/sysctl.conf <<'EOF'

# BBR + fq
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  fi
  sysctl --system >/dev/null 2>&1 || w "部分 sysctl 未生效，执行 sysctl --system 查看详情"
  if [ "$add_bbr" = true ]; then
    install_modules_load
    install_net_tune || w "fq 服务安装异常"
  fi
  return 0
}

install_bbr(){
  i "配置 BBR + fq..."
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  bbr_available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")"
  case " $bbr_available " in
    *" bbr "*) ;;
    *) w "当前内核不支持 BBR"; configure_sysctl false || true; return 1;;
  esac
  configure_sysctl true || return 1

  bbr_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo x)"
  bbr_qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo x)"
  bbr_dev="$(ip -o route show default 2>/dev/null | awk 'NR==1{print $5}')"
  bbr_fq_count=0
  [ -n "$bbr_dev" ] && bbr_fq_count="$(tc qdisc show dev "$bbr_dev" 2>/dev/null | awk '$1=="qdisc" && $2=="fq"{n++}END{print n+0}')"
  bbr_ver="$(modinfo -F version tcp_bbr 2>/dev/null | head -n1 || true)"
  [ -n "$bbr_ver" ] || bbr_ver="$(cat /sys/module/tcp_bbr/version 2>/dev/null || true)"

  case "$(uname -r)" in
    *xanmod*)
      if [ "$bbr_ver" = "3" ]; then
        i "BBRv3 已生效（内核 $(uname -r)，cc=$bbr_cc，qdisc=$bbr_qd，fq队列=$bbr_fq_count）"
      else
        i "XanMod 已运行，BBR 版本=${bbr_ver:-未知}（cc=$bbr_cc，qdisc=$bbr_qd）"
      fi
      ;;
    *)
      w "当前内核 $(uname -r) 不含 BBRv3，现已按 BBRv1 调优；重启进入 XanMod 后自动变 v3"
      NEED_REBOOT=true
      ;;
  esac
  return 0
}

install_iperf3(){
  i "安装iperf3..."
  has apt-get || { w "未找到apt-get，跳过iperf3"; return 1; }
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  has iperf3 || apt-get install -y -qq iperf3 >/dev/null 2>&1 || true
  if has systemctl && has iperf3; then
    cat > /etc/systemd/system/iperf3.service <<EOF
[Unit]
Description=iperf3 server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v iperf3) -s -p 5201 --bind 0.0.0.0
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now iperf3 >/dev/null 2>&1 || true
  fi
  has iperf3 && i "iperf3安装完成" || w "iperf3安装可能失败"
}

install_btop(){
  i "安装btop..."
  has apt-get || { w "未找到apt-get，跳过btop"; return 1; }
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt install -y btop >/dev/null 2>&1 || true
  has btop && i "btop安装完成" || w "btop安装可能失败"
}

set_service_cpu_affinity(){
  cpu_svc="$1"
  has systemctl || return 0
  systemctl status "${cpu_svc}.service" >/dev/null 2>&1 || return 0
  cpu_cores="$(nproc 2>/dev/null||echo 1)"
  case "$cpu_cores" in ''|*[!0-9]*) cpu_cores=1;; esac
  [ "$cpu_cores" -ge 1 ] 2>/dev/null || cpu_cores=1
  cpu_list="";cpu_index=0
  while [ "$cpu_index" -lt "$cpu_cores" ]; do
    [ -n "$cpu_list" ] && cpu_list="$cpu_list "
    cpu_list="${cpu_list}${cpu_index}";cpu_index=$((cpu_index+1))
  done
  cpu_dir="/etc/systemd/system/${cpu_svc}.service.d";mkdir -p "$cpu_dir" 2>/dev/null || true
  cat > "${cpu_dir}/10-cpu-affinity.conf" <<EOF
[Service]
CPUAffinity=${cpu_list}
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart "${cpu_svc}.service" >/dev/null 2>&1 || true
  i "已设置 ${cpu_svc}.service CPUAffinity=${cpu_list} (cores=${cpu_cores})"
}

install_nyanpass(){
  nyan_n="$1";nyan_s="$2";nyan_t="$3";nyan_u="$4";nyan_o="${5:-}"
  [ "$nyan_o" = no_o ] && nyan_args="-t $nyan_t -u $nyan_u" || nyan_args="-o -t $nyan_t -u $nyan_u"
  has curl || { w "未找到 curl，跳过nyanpass实例${nyan_n}"; return 1; }
  has bash || { w "未找到 bash，跳过nyanpass实例${nyan_n}"; return 1; }
  has timeout || { w "未找到 timeout，跳过nyanpass实例${nyan_n}"; return 1; }
  i "安装nyanpass实例${nyan_n}(${nyan_s})..."
  nyan_installer="$(mktemp /tmp/nyanpass-install.XXXXXX)" || { w "无法创建安装临时文件"; return 1; }
  nyan_output="$(mktemp /tmp/nyanpass-output.XXXXXX)" || { rm -f "$nyan_installer"; w "无法创建输出临时文件"; return 1; }
  if curl -fLSs https://dl.nyafw.com/download/nyanpass-install.sh -o "$nyan_installer" >>"$LOG" 2>&1 && printf '%s\n' "$nyan_s" n y|timeout "$TIMEOUT_NYANPASS" bash "$nyan_installer" rel_nodeclient "$nyan_args">"$nyan_output" 2>&1; then
    cat "$nyan_output">>"$LOG";rm -f "$nyan_installer" "$nyan_output";i "实例${nyan_n}完成";set_service_cpu_affinity "$nyan_s"
  else
    cat "$nyan_output">>"$LOG";rm -f "$nyan_installer" "$nyan_output";w "实例${nyan_n}可能失败"
  fi
}

configure_icmp(){
  i "调整 ICMP 规则..."
  has iptables || { w "未找到 iptables，跳过"; return 0; }
  # 旧规则整段 DROP ICMP 会破坏 PMTU 发现，先移除
  while iptables -D INPUT -p icmp -j DROP 2>/dev/null; do :; done
  iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null \
    || iptables -I INPUT 1 -p icmp --icmp-type echo-request -j DROP 2>/dev/null \
    || w "iptables 规则写入失败"
  i "已改为只丢弃 ping，保留 ICMP frag-needed"
}

summary(){
  i "================ 结果 ================"
  i "内核        : $(uname -r)"
  i "拥塞控制    : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  i "默认 qdisc  : $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  sdev="$(ip -o route show default 2>/dev/null | awk 'NR==1{print $5}')"
  if [ -n "$sdev" ]; then
    i "网卡 $sdev : $(tc qdisc show dev "$sdev" 2>/dev/null | awk '$1=="qdisc"{print $2}' | sort -u | tr '\n' ' ')"
  fi
  sver="$(modinfo -F version tcp_bbr 2>/dev/null | head -n1 || true)"
  i "tcp_bbr 版本: ${sver:-未知（XanMod 通常显示 3）}"
  i "======================================"
  cat <<'TIP'
重启后验证：
  uname -r                                   # 应包含 xanmod
  modinfo -F version tcp_bbr                 # 应为 3
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
  tc qdisc show dev $(ip -o route show default | awk 'NR==1{print $5}')
TIP
}

main(){
  parse_args "$@"
  root_check
  detect_env
  check_disk
  check_secure_boot

  i "[1/8] 环境：$OS_ID $OS_VER / $(uname -m) / 当前内核 $(uname -r)"
  i "[2/8] SSH";configure_ssh || w "SSH步骤异常"

  if [ "$DO_XANMOD" = true ] || uname -r | grep -q xanmod; then
    i "[3/8] XanMod 内核"; install_xanmod || w "XanMod步骤异常，继续后续调优"
  else
    i "[3/8] 跳过 XanMod"
  fi

  if [ "$DO_BBR" = true ]; then
    i "[4/8] BBR + fq";install_bbr || w "BBR步骤异常";sleep 2
  else
    i "[4/8] 跳过 BBR";configure_sysctl false || w "sysctl步骤异常"
  fi

  i "[5/8] iperf3";install_iperf3 || w "iperf3步骤异常"
  i "[6/8] btop";install_btop || w "btop步骤异常"
  i "[7/8] nyanpass(2)";install_nyanpass 1 "2" "5e0d5cbb-4850-4b51-93e9-6d62ae317325" "https://alpha.argoa.org" no_o
  i "[8/8] ICMP";configure_icmp || w "ICMP步骤异常"

  summary

  if [ "$DO_REBOOT" = true ] && [ "$NEED_REBOOT" = true ]; then
    i "10 秒后重启，可 Ctrl-C 取消"
    sleep 10
    reboot
  elif [ "$NEED_REBOOT" = true ]; then
    w "需要重启才会启用 XanMod/BBRv3：请执行 reboot"
  fi
  i "全部任务完成，日志：$LOG"
}
main "$@"
