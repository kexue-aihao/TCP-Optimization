#!/usr/bin/env bash

echo "====== TCP 智能網絡參數調優腳本 ======"
echo "支援：CentOS / Debian / Ubuntu"
echo ""

if [ "$(id -u)" -ne 0 ]; then
  echo "請以 root 身份執行本腳本。"
  exit 1
fi

if ! command -v bc >/dev/null 2>&1; then
  echo "未找到 bc，請先安裝："
  echo "  Debian/Ubuntu: apt install bc"
  echo "  CentOS/RHEL:  yum install bc"
  exit 1
fi

echo "請按提示輸入 VPS 硬體配置："
read -p "請輸入 CPU 核心數 (例如 2 或 1.5): " CPU
read -p "請輸入 記憶體大小 (GB) (例如 2 或 0.5): " MEM

# 允許 CPU / 記憶體 為小數，例如 1.5C、0.5G
if ! [[ "$CPU" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ "$MEM" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "輸入錯誤：CPU / 記憶體 必須是數字（可為小數，例如 1、2.5、0.5）。"
  exit 1
fi

cpu_gt_zero=$(echo "$CPU > 0" | bc)
mem_gt_zero=$(echo "$MEM > 0" | bc)
if [ "$cpu_gt_zero" -ne 1 ] || [ "$mem_gt_zero" -ne 1 ]; then
  echo "輸入錯誤：CPU / 記憶體 必須都大於 0。"
  exit 1
fi

BW=""

# 優先嘗試使用 speedtest 自動測速獲取帶寬
if command -v speedtest >/dev/null 2>&1; then
  echo ""
  read -p "檢測到 speedtest，可自動測速獲取帶寬，是否立即測試？[Y/n]: " USE_ST
  if [ -z "$USE_ST" ] || [[ "$USE_ST" =~ ^[Yy]$ ]]; then
    echo "正在執行 speedtest 測速，這可能需要一段時間..."
    ST_OUTPUT=$(speedtest 2>/dev/null)

    DOWN=$(echo "$ST_OUTPUT" | awk '/Download:/ {print $2; exit}')
    UP=$(echo "$ST_OUTPUT" | awk '/Upload:/ {print $2; exit}')
    LAT=$(echo "$ST_OUTPUT" | awk '/Latency:/ {print $2; exit}')

    if [ -n "$DOWN" ] && [ -n "$UP" ]; then
      echo "speedtest 測試結果："
      echo "  Download: ${DOWN} Mbps"
      echo "  Upload  : ${UP} Mbps"
      [ -n "$LAT" ] && echo "  Latency : ${LAT} ms"

      # 取上下行較小值作為實際可用帶寬
      BW_MEASURED=$(echo "$DOWN $UP" | awk '{d=$1; u=$2; if(d<u) print d; else print u}')
      echo "將使用上下行中較小值作為帶寬：${BW_MEASURED} Mbps"
      read -p "是否接受該帶寬數值？[Y/n]: " USE_BW
      if [ -z "$USE_BW" ] || [[ "$USE_BW" =~ ^[Yy]$ ]]; then
        BW="$BW_MEASURED"
      else
        echo "你選擇手動輸入帶寬。"
      fi
    else
      echo "speedtest 測試結果解析失敗，將改為手動輸入帶寬。"
    fi
  fi
else
  echo ""
  echo "未檢測到 speedtest，可按模板中的命令安裝後再使用自動測速。"
fi

# 若未從 speedtest 取得帶寬，改為手動輸入
if [ -z "$BW" ]; then
  read -p "請輸入實際可用帶寬 (Mbps，例如 2000 或 150.5): " BW
fi

# 檢查帶寬為數字（可帶小數）
if ! [[ "$BW" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "輸入錯誤：帶寬必須是數字（可帶小數，例如 100、2000.5）。"
  exit 1
fi

# 基準：2C 2G 2000Mbps → 默認值 65536，最大值 10000000
DEFAULT_BASE=65536     # net.ipv4.tcp_[rw]mem 中的默認值（中間那個）
MAX_BASE=10000000      # net.core.[rw]mem_max 和 tcp_[rw]mem 的最大值（最後那個）

# 按你給的邏輯：
#   默認值 隨 CPU 核心數線性放大：CPU=4C → 65536 * (4/2) = 131072
#   最大值 隨帶寬線性放大：BW=4000Mbps → 10000000 * (4000/2000) = 20000000
cpu_factor=$(echo "$CPU / 2" | bc -l)
bw_factor=$(echo "$BW / 2000" | bc -l)

NEW_DEFAULT=$(printf "%.0f" "$(echo "$DEFAULT_BASE * $cpu_factor" | bc)")
NEW_MAX=$(printf "%.0f" "$(echo "$MAX_BASE * $bw_factor" | bc)")

# 防止過小，至少不低於基準值
if [ "$NEW_DEFAULT" -lt "$DEFAULT_BASE" ]; then
  NEW_DEFAULT=$DEFAULT_BASE
fi
if [ "$NEW_MAX" -lt "$MAX_BASE" ]; then
  NEW_MAX=$MAX_BASE
fi

echo ""
echo "根據輸入硬體與帶寬計算出的參數："
echo "  CPU        : ${CPU}C"
echo "  記憶體     : ${MEM}G"
echo "  帶寬       : ${BW} Mbps"
echo "  默認值     : ${NEW_DEFAULT}"
echo "  最大值     : ${NEW_MAX}"
echo ""
echo "將會修改以下四個 sysctl 參數（其他模板參數原封不動寫入）："
echo "  net.core.rmem_max = ${NEW_MAX}"
echo "  net.core.wmem_max = ${NEW_MAX}"
echo "  net.ipv4.tcp_rmem = 4096 ${NEW_DEFAULT} ${NEW_MAX}"
echo "  net.ipv4.tcp_wmem = 4096 ${NEW_DEFAULT} ${NEW_MAX}"
echo ""

read -p "確認寫入 /etc/sysctl.conf 並立即生效？[y/N]: " CONFIRM
case "$CONFIRM" in
  [yY]|[yY][eE][sS])
    ;;
  *)
    echo "已取消，不做任何修改。"
    exit 0
    ;;
esac

SYSCTL_FILE="/etc/sysctl.conf"
BACKUP_FILE="/etc/sysctl.conf.bak-$(date +%Y%m%d-%H%M%S)"

if [ -f "$SYSCTL_FILE" ]; then
  cp "$SYSCTL_FILE" "$BACKUP_FILE"
  echo "已備份原檔案為: $BACKUP_FILE"
fi

cat >> "$SYSCTL_FILE" <<EOF

# ======= TCP 智能優化腳本自動生成 (開始) =======
# 本TCP网络参数模板取自BageVM默认参数模板进行修改
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
# 本TCP网络参数模板取自BageVM默认参数模板进行修改
net.core.rmem_max=${NEW_MAX}
net.core.wmem_max=${NEW_MAX}
net.ipv4.tcp_rmem=4096  ${NEW_DEFAULT} ${NEW_MAX}
net.ipv4.tcp_wmem=4096 ${NEW_DEFAULT} ${NEW_MAX}
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# ======= TCP 智能優化腳本自動生成 (結束) =======
EOF

echo ""
echo "已寫入 /etc/sysctl.conf，正在應用配置 (sysctl -p)..."
if sysctl -p; then
  echo "TCP 網絡參數已成功應用。"
else
  echo "警告：sysctl -p 執行時出現錯誤，請檢查上述輸出與 $SYSCTL_FILE。"
fi
