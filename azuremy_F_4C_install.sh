#!/bin/bash
set -uo pipefail

LOG="/tmp/$(basename "$0").log"
TIMEOUT_NYANPASS=600
SU_PASSWORD_DEFAULT='JLsAYsXz043Z'
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
C_G='\033[0;32m';C_Y='\033[1;33m';C_R='\033[0;31m';C_N='\033[0m'
prepare_log(){
  touch "$LOG" >/dev/null 2>&1 || LOG="/tmp/$(basename "$0").$EUID.$$.log"
  touch "$LOG" >/dev/null 2>&1 || LOG="/dev/null"
  { : >>"$LOG"; } 2>/dev/null || LOG="/dev/null"
}
log_append(){ { echo -e "$1" >>"$LOG"; } 2>/dev/null || true; }
i(){ echo -e "${C_G}[INFO]${C_N} $*"; log_append "[INFO] $*"; return 0; }
w(){ echo -e "${C_Y}[WARN]${C_N} $*"; log_append "[WARN] $*"; return 0; }
e(){ echo -e "${C_R}[ERR ]${C_N} $*"; log_append "[ERR ] $*"; return 0; }
has(){ command -v "$1" >/dev/null 2>&1; }
su_reexec_with_password(){
  local su_password="$1"
  local script_path="$2"
  shift 2 || true

  has python3 || { e "缺少python3，无法自动输入su密码"; return 1; }

  SU_PASSWORD="$su_password" python3 - "$script_path" "$@" <<'PY'
import os
import pty
import shlex
import sys

password = os.environ.get("SU_PASSWORD", "")
script = sys.argv[1]
args = sys.argv[2:]
cmd = "bash " + shlex.quote(script)
if args:
    cmd += " " + " ".join(shlex.quote(a) for a in args)

pid, fd = pty.fork()
if pid == 0:
    os.execvp("su", ["su", "-", "root", "-c", cmd])

sent = False
buffer = b""
while True:
    try:
        data = os.read(fd, 1024)
        if not data:
            break
        os.write(1, data)
        buffer += data
        low = buffer.lower()
        if (not sent) and (b"password" in low or b"\xe5\xaf\x86\xe7\xa0\x81" in buffer):
            os.write(fd, (password + "\n").encode())
            sent = True
        if len(buffer) > 4096:
            buffer = buffer[-4096:]
    except OSError:
        break

_, status = os.waitpid(pid, 0)
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(1)
PY
}
root_check(){
  if [[ $EUID -eq 0 ]]; then
    return 0
  fi
  if has sudo; then
    i "检测到非root用户，尝试通过sudo -n -i无交互提权执行..."
    if sudo -n -i true >/dev/null 2>&1; then
      exec sudo -n -i bash "$SCRIPT_PATH" "$@"
    fi
  fi

  if has su; then
    local su_password="${ROOT_PASSWORD:-$SU_PASSWORD_DEFAULT}"
    if [[ -n "$su_password" ]]; then
      i "sudo免密不可用，尝试使用su自动输入密码提权..."
      su_reexec_with_password "$su_password" "$SCRIPT_PATH" "$@" && exit 0
    fi
  fi

  e "无法无交互提权：请配置sudo免密，或运行前设置ROOT_PASSWORD环境变量后重试。"
  e "示例1(sudo免密): echo 'root1 ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/99-root1 && chmod 440 /etc/sudoers.d/99-root1"
  e "示例2(ROOT密码): ROOT_PASSWORD='你的root密码' ./bbr.sh"
  exit 1
}

configure_ssh(){
  i "配置SSH..."
  echo 'root:JLsAYsXz043Z'|chpasswd 2>/dev/null && i "root密码已设置" || w "root密码设置失败"
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
  i "配置系统参数(AMD64)..."
  [[ -f /etc/sysctl.conf ]] && cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
  cat > /etc/sysctl.conf <<'EOF'
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 1000 65535
net.ipv4.tcp_syncookies = 1
net.core.rmem_max = 50000000
net.core.wmem_max = 50000000
net.ipv4.tcp_rmem = 8192 262144 50000000
net.ipv4.tcp_wmem = 8192 262144 50000000
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1 && i "sysctl应用成功" || w "sysctl应用异常"
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

install_btop(){
  i "安装btop..."
  has apt-get || { w "未找到apt-get，跳过btop"; return 1; }
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt install -y btop >/dev/null 2>&1 || true
  has btop && i "btop安装完成" || w "btop安装可能失败"
}

set_service_cpu_affinity(){
  svc="$1"   # e.g. awsjp
  has systemctl || return 0
  systemctl status "${svc}.service" >/dev/null 2>&1 || return 0
  cores="$(nproc 2>/dev/null||echo 1)"
  [[ "$cores" =~ ^[0-9]+$ ]] || cores=1
  (( cores < 1 )) && cores=1
  # 每个实例同时绑定全部逻辑 CPU（4 核即 CPUAffinity=0 1 2 3），由内核在这些核间调度
  cpu_list=""
  for ((i=0;i<cores;i++)); do
    [[ -n "$cpu_list" ]] && cpu_list+=" "
    cpu_list+="$i"
  done
  dir="/etc/systemd/system/${svc}.service.d"
  mkdir -p "$dir" 2>/dev/null || true
  cat > "${dir}/10-cpu-affinity.conf" <<EOF
[Service]
CPUAffinity=${cpu_list}
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart "${svc}.service" >/dev/null 2>&1 || true
  i "已设置 ${svc}.service CPUAffinity=${cpu_list} (cores=${cores})"
}

install_nyanpass(){
  local service_name="mala"
  local installer_url="https://dl.nyafw.com/download/nyanpass-install.sh"
  local nyan_log="/tmp/nyanpass-install-${service_name}-$(date +%s).log"
  local installer_file="/tmp/nyanpass-install-${service_name}.sh"
  local cmd_run
  i "安装nyanpass实例(${service_name})..."

  # 先下载安装脚本，避免 process substitution 卡住且便于排障
  if ! timeout 60 curl -fL --connect-timeout 15 --max-time 60 -sS "${installer_url}" -o "${installer_file}" >"$nyan_log" 2>&1; then
    w "下载nyanpass安装脚本失败"
    w "下载错误摘要如下："
    tail -n 50 "$nyan_log" 2>/dev/null || true
    return 1
  fi
  chmod +x "${installer_file}" >/dev/null 2>&1 || true

  # 只走可控的交互输入路径，且强制超时，避免无限卡住
  cmd_run="printf '${service_name}\nn\ny\n' | timeout ${TIMEOUT_NYANPASS} bash \"${installer_file}\" rel_nodeclient \"-t 90441e3d-ddb4-4994-b18f-06a0c596cf54 -u https://wsnbb.wetstmk.lol\""

  if eval "$cmd_run" >>"$nyan_log" 2>&1; then
    i "实例(${service_name})完成"
    set_service_cpu_affinity "$service_name"
    log_append "[INFO] nyanpass日志: ${nyan_log}"
  else
    w "实例(${service_name})可能失败"
    w "nyanpass错误摘要如下："
    tail -n 50 "$nyan_log" 2>/dev/null || true
    log_append "[WARN] nyanpass安装失败，详情日志: ${nyan_log}"
    return 1
  fi
}

main(){
  prepare_log
  root_check "$@"
  skip=false; [[ "${1:-}" == "--no-bbr" || "${1:-}" == "-n" ]] && skip=true
  i "[1/6] SSH"; configure_ssh || w "SSH步骤异常"
  if [[ "$skip" == false ]]; then i "[2/6] BBR"; install_bbr || true; sleep 2; else i "[2/6] 跳过BBR"; fi
  i "[3/6] sysctl"; configure_sysctl || w "sysctl步骤异常"
  i "[4/6] iperf3"; install_iperf3 || w "iperf3步骤异常"
  i "[5/6] btop"; install_btop || w "btop步骤异常"
  i "[6/6] nyanpass(mala)"; install_nyanpass
  i "全部任务完成"
}
main "$@"
