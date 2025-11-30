#!/bin/bash
# TCP 智能網絡參數調優腳本（含 speedtest、自動安裝、支援小數 CPU/內存）

echo "====== TCP 智能網絡參數調優腳本 ======"
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

# 嘗試解析 JSON 輸出中的 bandwidth（bps）
parse_json_bandwidth() {
  local json="$1" key="$2"  # key="download" 或 "upload"
  echo "$json" | sed -n "s/.*\"$key\"[^{]*{[^}]*\"bandwidth\":\([0-9][0-9]*\).*/\1/p" | head -n1
}

# 從 speedtest output 解析 Mbps（文字模式）
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

# 執行 speedtest 並把帶寬存到全局變數 BW_Mbps
run_speedtest_and_get_bw() {
  BW_Mbps=""
  local OUTPUT JSON DL_BPS UP_BPS DL_Mbps UP_Mbps

  echo
  echo "正在使用 speedtest 測速，可能需要 30~60 秒..."

  # 先嘗試 JSON 格式（新版 speedtest by Ookla 推薦）
  OUTPUT=$(speedtest --accept-license --accept-gdpr -f json 2>/dev/null)
  if echo "$OUTPUT" | grep -q '"download"'; then
    DL_BPS=$(parse_json_bandwidth "$OUTPUT" "download")
    UP_BPS=$(parse_json_bandwidth "$OUTPUT" "upload")
    if [ -n "$DL_BPS" ]; then
      DL_Mbps=$(awk -v b="$DL_BPS" 'BEGIN{printf "%.2f", b*8/1000000}')
    fi
    if [ -n "$UP_BPS" ]; then
      UP_Mbps=$(awk -v b="$UP_BPS" 'BEGIN{printf "%.2f", b*8/1000000}')
    fi
  else
    # JSON 失敗就退回純文字模式
    OUTPUT=$(speedtest --accept-license --accept-gdpr 2>/dev/null || speedtest 2>/dev/null)
    DL_Mbps=$(parse_text_mbps "$OUTPUT" "Download")
    UP_Mbps=$(parse_text_mbps "$OUTPUT" "Upload")
  fi

  if [ -n "$DL_Mbps" ] && [ -n "$UP_Mbps" ]; then
    BW_Mbps=$(awk -v d="$DL_Mbps" -v u="$UP_Mbps" 'BEGIN{if (d<u) printf "%.2f", d; else printf "%.2f", u}')
    echo "speedtest 測試結果：Download=${DL_Mbps} Mbps, Upload=${UP_Mbps} Mbps"
    echo "採用上下行較小值作為帶寬：${BW_Mbps} Mbps"
    return 0
  elif [ -n "$DL_Mbps" ]; then
    BW_Mbps="$DL_Mbps"
    echo "只解析到 Download=${DL_Mbps} Mbps，採用此值作為帶寬。"
    return 0
  elif [ -n "$UP_Mbps" ]; then
    BW_Mbps="$UP_Mbps"
    echo "只解析到 Upload=${UP_Mbps} Mbps，採用此值作為帶寬。"
    return 0
  else
    echo "自動測速輸出解析失敗。"
    return 1
  fi
}

# 自動安裝 speedtest（需 apt 或 yum）
install_speedtest_interactive() {
  if command -v speedtest >/dev/null 2>&1; then
    return 0
  fi

  echo "未檢測到 speedtest。"
  read -p "是否自動安裝 speedtest？[Y/n]: " ins
  if [[ "$ins" =~ ^[Nn]$ ]]; then
    echo "你選擇不安裝 speedtest。"
    return 1
  fi

  echo "開始嘗試自動安裝 speedtest（需要網路）..."

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
    echo "未檢測到 apt 或 yum，無法自動安裝 speedtest，請手動安裝。"
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

# ========== 是否使用 speedtest 自動測速 ==========
BW_Mbps=""

read -p "是否使用 speedtest 自動測速獲取帶寬？[Y/n]: " use_st
if [[ ! "$use_st" =~ ^[Nn]$ ]]; then
  # 需要 speedtest
  if install_speedtest_interactive; then
    if ! run_speedtest_and_get_bw; then
      echo "自動測速失敗，將改為手動輸入帶寬。"
    fi
  else
    echo "未安裝 speedtest，將改為手動輸入帶寬。"
  fi
fi

# 如果自動測速沒成功，改為手動輸入帶寬
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

echo
echo "最終帶寬將按：${BW_Mbps} Mbps 進行計算。"
echo

# ========== 根據你的規則計算四個參數 ==========
# 基準：2C / 2000Mbps → 65536 / 10000000
DEFAULT_BASE=65536
MAX_BASE=10000000
CPU_BASE=2
BW_BASE=2000

CPU_FACTOR=$(echo "$CPU / $CPU_BASE" | bc -l)
BW_FACTOR=$(echo "$BW_Mbps / $BW_BASE" | bc -l)

NEW_DEFAULT=$(printf "%.0f" "$(echo "$DEFAULT_BASE * $CPU_FACTOR" | bc)")
NEW_MAX=$(printf "%.0f" "$(echo "$MAX_BASE * $BW_FACTOR" | bc)")

# 保底：不要低於原始基準
if [ "$NEW_DEFAULT" -lt "$DEFAULT_BASE" ]; then
  NEW_DEFAULT=$DEFAULT_BASE
fi
if [ "$NEW_MAX" -lt "$MAX_BASE" ]; then
  NEW_MAX=$MAX_BASE
fi

echo "計算得到："
echo "  默認值(default) = $NEW_DEFAULT"
echo "  最大值(max)     = $NEW_MAX"
echo

SYSCTL_FILE="/etc/sysctl.conf"
BACKUP_FILE="/etc/sysctl.conf.bak_$(date +%F_%H%M%S)"

cp "$SYSCTL_FILE" "$BACKUP_FILE"
echo "已備份原配置到：$BACKUP_FILE"
echo

# 刪掉舊的自動生成區塊
sed -i '/# ===== BageVM TCP 智能調優 START =====/,/# ===== BageVM TCP 智能調優 END =====/d' "$SYSCTL_FILE"

# 追加你的模板 + 計算後四個值
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
# 计算出的最大值填入 net.core.rmem_max net.core.wmem_max 这两个最大值需要一致，只需要用speedtest_cli测试出来的值套用计算公式计算出来即可，测试出来的值进行四舍五入计算后再套用公式进行计算
# 计算出来的最大值需要填写 net.ipv4.tcp_rmem net.ipv4.tcp_wmem 最后一个值里去
# 参数值释义
# net.core.rmem_max 下行带宽
# net.core.wmem_max 上行带宽
# net.ipv4.tcp_rmem ipv4下行带宽参数
# net.ipv4.tcp_wmem ipv4上行带宽参数
# net.ipv4.tcp_rmem=4096 524288 30000000 这三个值默认排序是，最小值、默认值、最大值，一般只需要调默认值和最大值，最小值不做更改
# Speedtest_cli 安装命令
# apt install sudo -y && curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash && apt-get install speedtest && speedtest -y
# Speedtest_cli 常用命令
# speedtest -L 查看最近VPS测速点
# speedtest -s 测速点id
# speedtest 不加任何参数，直接进行测速 （不推荐，默认测速点不一定是距离服务器最近的）

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
