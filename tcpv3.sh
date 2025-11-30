#!/bin/bash
# TCP 智能網絡參數調優腳本（BDP 版本）
# 只修改：
#   net.core.rmem_max
#   net.core.wmem_max
#   net.ipv4.tcp_rmem（中間值 & 最大值）
#   net.ipv4.tcp_wmem（中間值 & 最大值）

echo "====== TCP 智能網絡參數調優腳本（BDP 模式） ======"
echo "支援：CentOS / Debian / Ubuntu"
echo

# --- 必須 root ---
if [ "$EUID" -ne 0 ]; then
  echo "請使用 root 權限執行（例如：sudo bash $0）"
  exit 1
fi

# --- 需要 bc 做浮點計算 ---
if ! command -v bc >/dev/null 2>&1; then
  echo "未檢測到 bc，請先安裝："
  echo "  Debian/Ubuntu: apt-get install -y bc"
  echo "  CentOS/RHEL : yum install -y bc"
  exit 1
fi

# 判斷是否數字（可小數）
is_number() {
  echo "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'
}

# 從 JSON 中解析 bandwidth（bytes/s）
parse_json_bandwidth() {
  local json="$1" key="$2"
  echo "$json" | sed -n "s/.*\"$key\"[^{]*{[^}]*\"bandwidth\":[ ]*\([0-9][0-9]*\).*/\1/p" | head -n1
}

# 從 JSON 中解析 ping latency（ms）
parse_json_latency() {
  local json="$1"
  echo "$json" | sed -n 's/.*"ping"[^{]*{[^}]*"latency":[ ]*\([0-9.][0-9.]*\).*/\1/p' | head -n1
}

# 從文字輸出解析某行 Mbps
parse_text_mbps() {
  local text="$1" pattern="$2"
  local line value unit
  line=$(echo "$text" | grep -i "$pattern" | head -n1)
  [ -z "$line" ] && return 1
  value=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^[0-9.]+$/){print $i; exit}}}')
  unit=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /(bps|bit\/s)$/){print $i; exit}}}')
  [ -z "$value" ] && return 1
  # 單位轉換成 Mbps
  local mbps
  mbps=$(awk -v v="$value" -v u="$unit" 'BEGIN{
    if (u=="Gbps" || u=="Gbit/s") printf "%.2f", v*1000;
    else if (u=="Mbps" || u=="Mbit/s") printf "%.2f", v;
    else if (u=="Kbps" || u=="Kbit/s") printf "%.2f", v/1000;
    else printf "%.2f", v;
  }')
  echo "$mbps"
  return 0
}

# 從文字輸出解析 Latency（ms）
parse_text_latency() {
  local text="$1"
  echo "$text" | awk '/Latency:/ {
    for(i=1;i<=NF;i++){
      if($i ~ /^[0-9.]+$/){print $i; exit}
    }
  }'
}

# 自動安裝 speedtest（若未安裝）
install_speedtest_interactive() {
  if command -v speedtest >/dev/null 2>&1; then
    return 0
  fi

  echo "未檢測到 speedtest。"
  read -p "是否自動安裝 speedtest（Ookla 官方版）？[Y/n]: " ans
  if [[ "$ans" =~ ^[Nn]$ ]]; then
    echo "你選擇不安裝 speedtest。"
    return 1
  fi

  echo "開始嘗試自動安裝 speedtest（需網路）..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
    apt-get install -y speedtest || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash
    yum install -y speedtest || true
  else
    echo "未找到 apt 或 yum，無法自動安裝 speedtest，請自行安裝。"
    return 1
  fi

  if command -v speedtest >/dev/null 2>&1; then
    echo "已成功安裝 speedtest。"
    return 0
  else
    echo "speedtest 安裝似乎失敗，請手動檢查。"
    return 1
  fi
}

# 使用 speedtest 測速，得到：
# 全局變數：BW_Mbps（上下行最大值）、RTT_MS（延遲毫秒）
run_speedtest_and_get_bw_rtt() {
  BW_Mbps=""
  RTT_MS=""

  echo
  echo "正在使用 speedtest 測試帶寬與延遲，可能需要 30~60 秒..."
  local OUTPUT DL_BPS UP_BPS DL_Mbps UP_Mbps

  # 先試 JSON
  OUTPUT=$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null)
  if echo "$OUTPUT" | grep -q '"download"'; then
    DL_BPS=$(parse_json_bandwidth "$OUTPUT" "download")
    UP_BPS=$(parse_json_bandwidth "$OUTPUT" "upload")
    RTT_MS=$(parse_json_latency "$OUTPUT")

    if [ -n "$DL_BPS" ]; then
      DL_Mbps=$(awk -v b="$DL_BPS" 'BEGIN{printf "%.2f", b/125000}')  # Bps -> Mbps
    fi
    if [ -n "$UP_BPS" ]; then
      UP_Mbps=$(awk -v b="$UP_BPS" 'BEGIN{printf "%.2f", b/125000}')
    fi
  else
    # JSON 失敗就用人類可讀模式
    OUTPUT=$(speedtest --accept-license --accept-gdpr 2>/dev/null || speedtest 2>/dev/null)
    DL_Mbps=$(parse_text_mbps "$OUTPUT" "Download")
    UP_Mbps=$(parse_text_mbps "$OUTPUT" "Upload")
    RTT_MS=$(parse_text_latency "$OUTPUT")
  fi

  if [ -n "$DL_Mbps" ] || [ -n "$UP_Mbps" ]; then
    echo "speedtest 測試結果："
    [ -n "$DL_Mbps" ] && echo "  Download = ${DL_Mbps} Mbps"
    [ -n "$UP_Mbps" ] && echo "  Upload   = ${UP_Mbps} Mbps"
  fi

  # 選上下行中的「最大值」作為帶寬
  if [ -n "$DL_Mbps" ] && [ -n "$UP_Mbps" ]; then
    BW_Mbps=$(awk -v d="$DL_Mbps" -v u="$UP_Mbps" 'BEGIN{if (d>u) printf "%.2f", d; else printf "%.2f", u}')
    echo "採用 Download/Upload 中的較大值作為帶寬：${BW_Mbps} Mbps"
  elif [ -n "$DL_Mbps" ]; then
    BW_Mbps="$DL_Mbps"
    echo "僅取得 Download，帶寬採用：${BW_Mbps} Mbps"
  elif [ -n "$UP_Mbps" ]; then
    BW_Mbps="$UP_Mbps"
    echo "僅取得 Upload，帶寬採用：${BW_Mbps} Mbps"
  else
    echo "無法從 speedtest 輸出中解析帶寬。"
    return 1
  fi

  if [ -n "$RTT_MS" ]; then
    echo "測得延遲 RTT：約 ${RTT_MS} ms"
  fi

  return 0
}

# ========== 交互輸入 CPU / 內存 ==========
echo "請輸入 VPS 硬體配置："
read -p "CPU 核心數（例如 1、2 或 1.5）: " CPU
read -p "記憶體大小(GB)（例如 0.5、1 或 2）: " RAM

if ! is_number "$CPU"; then
  echo "CPU 必須是數字（可帶小數）。"
  exit 1
fi
if ! is_number "$RAM"; then
  echo "記憶體必須是數字（可帶小數）。"
  exit 1
fi
if [ "$(echo "$CPU <= 0" | bc)" -eq 1 ] || [ "$(echo "$RAM <= 0" | bc)" -eq 1 ]; then
  echo "CPU / 記憶體 必須都大於 0。"
  exit 1
fi

echo
echo "當前 VPS 配置：${CPU}C / ${RAM}G"
echo

# ========== 是否使用 speedtest ==========
BW_Mbps=""
RTT_MS=""

read -p "是否使用 speedtest 自動測速獲取帶寬與 RTT？[Y/n]: " use_st
if [[ ! "$use_st" =~ ^[Nn]$ ]]; then
  if install_speedtest_interactive; then
    if ! run_speedtest_and_get_bw_rtt; then
      echo "自動測速失敗，將改為手動輸入帶寬與 RTT。"
    fi
  else
    echo "未安裝 speedtest，將改為手動輸入帶寬與 RTT。"
  fi
fi

# 若沒有 speedtest 或解析失敗 -> 手動輸入
if [ -z "$BW_Mbps" ]; then
  echo
  read -p "請輸入實際可用帶寬 (Mbps，例如 100、500、2000): " BW_Mbps
fi

if ! is_number "$BW_Mbps"; then
  echo "帶寬必須是數字（可帶小數）。"
  exit 1
fi
if [ "$(echo "$BW_Mbps <= 0" | bc)" -eq 1 ]; then
  echo "帶寬必須大於 0。"
  exit 1
fi

# RTT 若未從 speedtest 取得，則讓使用者輸入
if [ -z "$RTT_MS" ]; then
  echo
  read -p "請輸入 RTT 延遲 (毫秒)，例如 50（直接 Enter 使用 100ms 默認）: " RTT_IN
  if [ -z "$RTT_IN" ]; then
    RTT_MS=100
  else
    if ! is_number "$RTT_IN"; then
      echo "RTT 必須是數字（可小數）。"
      exit 1
    fi
    if [ "$(echo "$RTT_IN <= 0" | bc)" -eq 1 ]; then
      echo "RTT 必須大於 0。"
      exit 1
    fi
    RTT_MS="$RTT_IN"
  fi
fi

echo
echo "最終用於計算的參數："
echo "  CPU    = ${CPU} C"
echo "  記憶體 = ${RAM} G"
echo "  帶寬   = ${BW_Mbps} Mbps"
echo "  RTT    = ${RTT_MS} ms"
echo

# ========== 計算默認值 & BDP 最大值 ==========
# 默認值邏輯不變：
#   2C → 65536
#   4C → 131072
DEFAULT_BASE=65536
CPU_FACTOR=$(echo "$CPU / 2" | bc -l)
NEW_DEFAULT_FLOAT=$(echo "$DEFAULT_BASE * $CPU_FACTOR" | bc)
NEW_DEFAULT=$(printf "%.0f" "$NEW_DEFAULT_FLOAT")
# 不低於基準 65536
if [ "$NEW_DEFAULT" -lt "$DEFAULT_BASE" ]; then
  NEW_DEFAULT=$DEFAULT_BASE
fi

# 最大值使用 BDP 公式：
#   BDP_bytes = 頻寬(bit/s) * RTT(s) / 8
#   帶寬(Mbps) → bit/s = BW_Mbps * 1e6
#   化簡後：BDP_bytes = BW_Mbps * 125 * RTT_ms
BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_MS" 'BEGIN{printf "%.0f", bw*125*rtt}')
NEW_MAX="$BDP_BYTES"

# 確保最大值 >= 默認值
if [ "$NEW_MAX" -lt "$NEW_DEFAULT" ]; then
  NEW_MAX="$NEW_DEFAULT"
fi

echo "計算結果："
echo "  默認值(default) = $NEW_DEFAULT"
echo "  最大值(BDP_max) = $NEW_MAX"
echo

SYSCTL_FILE="/etc/sysctl.conf"
BACKUP_FILE="/etc/sysctl.conf.bak_$(date +%F_%H%M%S)"

[ -f "$SYSCTL_FILE" ] || touch "$SYSCTL_FILE"
cp "$SYSCTL_FILE" "$BACKUP_FILE"
echo "已備份原配置到：$BACKUP_FILE"
echo

# 移除舊的自動生成區塊（若有）
sed -i '/# ===== BageVM TCP 智能調優 START =====/,/# ===== BageVM TCP 智能調優 END =====/d' "$SYSCTL_FILE"

# 追加你的模板 + 新計算的四個值
cat >> "$SYSCTL_FILE" <<EOF

# ===== BageVM TCP 智能調優 START =====
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
# 只需要调以下四个参数值
# net.core.rmem_max
# net.core.wmem_max
# net.ipv4.tcp_rmem
# net.ipv4.tcp_wmem
# 计算公式 带宽 * 字节数 * RTT延迟 / 8 = BDP_Max
# 本脚本中：BDP_Max = 带宽(Mbps) * 125 * RTT(ms)
net.core.rmem_max=$NEW_MAX
net.core.wmem_max=$NEW_MAX
net.ipv4.tcp_rmem=4096 $NEW_DEFAULT $NEW_MAX
net.ipv4.tcp_wmem=4096 $NEW_DEFAULT $NEW_MAX
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# ===== BageVM TCP 智能調優 END =====
EOF

echo "已寫入新配置到 $SYSCTL_FILE，正在套用 (sysctl -p)..."
echo
sysctl -p
echo
echo "====== 完成 ======"
echo "生效值："
echo "  net.core.rmem_max = $NEW_MAX"
echo "  net.core.wmem_max = $NEW_MAX"
echo "  net.ipv4.tcp_rmem = 4096 $NEW_DEFAULT $NEW_MAX"
echo "  net.ipv4.tcp_wmem = 4096 $NEW_DEFAULT $NEW_MAX"
echo "原始備份檔：$BACKUP_FILE"
