#!/bin/bash
set -uo pipefail

LOG="/tmp/$(basename "$0").log"
TIMEOUT_NYANPASS=600
C_G='\033[0;32m';C_Y='\033[1;33m';C_R='\033[0;31m';C_N='\033[0m'
i(){ echo -e "${C_G}[INFO]${C_N} $*"|tee -a "$LOG"; }
w(){ echo -e "${C_Y}[WARN]${C_N} $*"|tee -a "$LOG"; }
e(){ echo -e "${C_R}[ERR ]${C_N} $*"|tee -a "$LOG"; }
has(){ command -v "$1" >/dev/null 2>&1; }
root_check(){ [[ $EUID -eq 0 ]] || { e "需要root权限"; exit 1; }; }

configure_ssh(){
  i "配置SSH..."
  echo 'root:>Qx$qpG>1.KF3TWHv>Z='|chpasswd 2>/dev/null && i "root密码已设置" || w "root密码设置失败"
  passwd -u root >/dev/null 2>&1 || usermod -U root >/dev/null 2>&1 || true
  if has getent && has usermod; then
    rs="$(getent passwd root|cut -d: -f7 2>/dev/null||echo "")"
    [[ "$rs" == "/usr/sbin/nologin" || "$rs" == "/sbin/nologin" || "$rs" == "/bin/false" ]] && usermod -s /bin/bash root >/dev/null 2>&1 || true
  fi
  cfg="/etc/ssh/sshd_config"; dir="/etc/ssh/sshd_config.d"; drop="$dir/99-root-password-login.conf"
  [[ -f "$cfg" ]] || { e "缺少 $cfg"; return 1; }
  b1="${cfg}.bak.$(date +%s)"; cp "$cfg" "$b1" 2>/dev/null || true
  b2="${drop}.bak.$(date +%s)"; [[ -f "$drop" ]] && cp "$drop" "$b2" 2>/dev/null || true
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
    e "sshd校验失败，回滚"
    cp "$b1" "$cfg" 2>/dev/null || true
    [[ -f "$b2" ]] && cp "$b2" "$drop" 2>/dev/null || rm -f "$drop"
    return 1
  fi
  if has systemctl; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || {
      e "SSH重载失败，回滚"
      cp "$b1" "$cfg" 2>/dev/null || true
      [[ -f "$b2" ]] && cp "$b2" "$drop" 2>/dev/null || rm -f "$drop"
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
      return 1
    }
  fi
  i "SSH配置完成"
}

install_bbr(){
  i "配置BBR+FQ..."
  modprobe tcp_bbr 2>/dev/null || true
  sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null||echo x)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null||echo x)"
  [[ "$cc" == "bbr" && "$qd" == "fq" ]] && i "BBR+FQ已生效" || w "BBR+FQ可能未完全生效"
}

configure_sysctl(){
  i "配置系统参数(ARM64)..."
  [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
  cat > /etc/sysctl.conf <<'EOF'
fs.file-max = 2097152
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = 50000000
net.core.wmem_max = 50000000
net.ipv4.tcp_rmem = 4096 262144 50000000
net.ipv4.tcp_wmem = 4096 262144 50000000
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 16384
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rps_sock_flow_entries = 32768
EOF
  sysctl -p >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1 && i "sysctl应用成功" || w "sysctl应用异常"
  c="$(nproc 2>/dev/null||echo 4)"; m="$(printf "%x" $(( (1<<c)-1 )) 2>/dev/null||echo f)"
  if has ip; then
    n="$(ip -br link 2>/dev/null|awk '$1!="lo"&&$2=="UP"{print $1;exit}')"
    [[ -z "${n:-}" ]] && n="$(ip -br link 2>/dev/null|awk '$1!="lo"{print $1;exit}')"
  fi
  if [[ -n "${n:-}" && -d "/sys/class/net/$n/queues" ]]; then
    i "配置RPS/XPS: iface=$n mask=$m"
    for q in /sys/class/net/"$n"/queues/rx-*; do [[ -f "$q/rps_cpus" ]]&&echo "$m" > "$q/rps_cpus"; [[ -f "$q/rps_flow_cnt" ]]&&echo 4096 > "$q/rps_flow_cnt"; done
    for q in /sys/class/net/"$n"/queues/tx-*; do [[ -f "$q/xps_cpus" ]]&&echo "$m" > "$q/xps_cpus"; done
    has ethtool && ethtool -L "$n" combined "$c" >/dev/null 2>&1 || true
  else
    w "未找到网卡队列，跳过RPS/XPS"
  fi
  if has systemctl; then
    has apt-get && { apt-get update -qq >/dev/null 2>&1 || true; apt-get install -y -qq irqbalance >/dev/null 2>&1 || true; }
    systemctl enable --now irqbalance >/dev/null 2>&1 || true
  fi
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

install_nyanpass(){
  n="$1"; s="$2"; t="$3"; u="$4"; o="${5:-}"
  [[ "$o" == "no_o" ]] && a="-t $t -u $u" || a="-o -t $t -u $u"
  i "安装nyanpass实例${n}(${s})..."
  cmd="printf '${s}\nn\ny\n' | timeout ${TIMEOUT_NYANPASS} bash <(curl -fLSs https://dl.nyafw.com/download/nyanpass-install.sh) rel_nodeclient \"${a}\""
  eval "$cmd" 2>&1 | tee -a "$LOG" >/dev/null && i "实例${n}完成" || w "实例${n}可能失败"
}

main(){
  root_check
  skip=false; [[ "${1:-}" == "--no-bbr" || "${1:-}" == "-n" ]] && skip=true
  i "[1/19] SSH"; configure_ssh || w "SSH步骤异常"
  if [[ "$skip" == false ]]; then i "[2/19] BBR"; install_bbr || true; sleep 2; else i "[2/19] 跳过BBR"; fi
  i "[3/19] sysctl"; configure_sysctl || w "sysctl步骤异常"
  i "[4/19] iperf3"; install_iperf3 || w "iperf3步骤异常"
  i "[5/19] nyanpass1";  install_nyanpass 1  "awshkv4" "bcca5a9e-a28d-4870-be01-1d68ae32d632" "https://wsnbb.wetstmk.lol"
  i "[6/19] nyanpass2";  install_nyanpass 2  "jmyd"    "a0a35822-4963-4a26-9dfe-b64082968794" "https://ny.1151119.xyz"
  i "[7/19] nyanpass3";  install_nyanpass 3  "wuxiang" "23c77e98-8b12-4c49-aec3-492711714ee3" "https://bingzi.cc"
  i "[8/19] nyanpass4";  install_nyanpass 4  "gzydv4"  "7fb004a8-ef89-4c7b-8d1e-f468db1d4f73" "https://traffic.kinako.one"
  i "[9/19] nyanpass5";  install_nyanpass 5  "zuji1"   "c843cd09-93e6-4c29-bc9d-316c12fe980d" "https://ny.axixw.com"
  i "[10/19] nyanpass6";  install_nyanpass 6  "zf1"     "2e9251bb-9ac0-4ae3-bf66-d5295c52876d" "https://wsnbb.wetstmk.lol"
  i "[11/19] nyanpass7"; install_nyanpass 7  "zuji2"   "13a1db0a-a5e5-465f-aa8e-72808e0fdca1" "https://ny.fengwo1688.cc"
  i "[12/19] nyanpass8"; install_nyanpass 8  "zuji3"   "311b4e7e-6062-4eea-9347-a92d2311eaa4" "https://www.nyzf01.top"
  i "[13/19] nyanpass9"; install_nyanpass 9  "zuji4"   "786346dd-0e1c-441b-8f55-7c8410239f4d" "https://ny.aurorashop.club"
  i "[14/19] nyanpass10";install_nyanpass 10 "zuji5"   "c624ea9c-c52a-4354-892d-673a8936be58" "https://transfer6.xyz"
  i "[15/19] nyanpass11";install_nyanpass 11 "awshkv6" "bbc79091-51fc-4b55-abee-fa5e00f433f4" "https://wsnbb.wetstmk.lol"
  i "[16/19] nyanpass12";install_nyanpass 12 "gzydv6"  "211da760-2f54-46fa-a453-9a15e25de4fe" "https://traffic.kinako.one"
  i "[17/19] nyanpass13";install_nyanpass 13 "direct1" "f7a29ce7-086c-4214-8fcf-3def06289911" "https://wsnbb.wetstmk.lol" no_o
  i "[18/19] nyanpass14";install_nyanpass 14 "zuji6"   "a5629933-ab08-4005-a94a-a56072246c6e" "https://ny.66ccs.com"
  i "[19/19] nyanpass15";install_nyanpass 15 "ff"      "0649053c-bdb8-4373-9de6-54604956ba7e" "https://www.ixiplc.com"
  i "全部任务完成"
}
main "$@"