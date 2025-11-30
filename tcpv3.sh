#!/bin/bash

echo "====== TCP 智能網絡參數調優腳本 ======"
echo "支援：CentOS / Debian / Ubuntu"
echo "注意：請使用 root 或 sudo 執行本腳本"
echo ""

# 必須 root
if [ "$EUID" -ne 0 ]; then
    echo "請使用 root 權限運行，例如：sudo bash $0"
    exit 1
fi

# 檢測系統
OS="unknown"
if [ -f /etc/redhat-release ]; then
    OS="centos"
elif [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu) OS="ubuntu" ;;
        debian) OS="debian" ;;
        centos|rhel|rocky|almalinux) OS="centos" ;;
        *) OS="$ID" ;;
    esac
fi

echo "檢測到系統：$OS"
echo ""

# 確保有 bc（做浮點運算用）
if ! command -v bc >/dev/null 2>&1; then
    echo "未找到 bc，正在嘗試安裝..."
    if [ "$OS" = "centos" ]; then
        yum install -y bc || { echo "安裝 bc 失敗，請手動安裝後重試。"; exit 1; }
    elif [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        apt-get update && apt-get install -y bc || { echo "安裝 bc 失敗，請手動安裝後重試。"; exit 1; }
    else
        echo "無法自動安裝 bc，請手動安裝後重試。"
        exit 1
    fi
fi

# 判斷是否為正數（可帶小數）
is_number() {
    echo "$1" | grep -Eq '^[0-9]+([.][0-9]+)?$'
}

# 尋找 speedtest 命令
find_speedtest_cmd() {
    if command -v speedtest >/dev/null 2>&1; then
        echo "speedtest"
    elif command -v speedtest-cli >/dev/null 2>&1; then
        echo "speedtest-cli"
    else
        echo ""
    fi
}

# 交互式安裝 speedtest
install_speedtest() {
    local cmd
    cmd=$(find_speedtest_cmd)
    if [ -n "$cmd" ]; then
        return 0
    fi

    echo "未檢測到 speedtest / speedtest-cli。"
    read -p "是否自動為你安裝 speedtest？(y/N): " INSTALL
    if [[ ! "$INSTALL" =~ ^[Yy]$ ]]; then
        echo "你選擇不自動安裝 speedtest。"
        return 1
    fi

    echo "正在嘗試自動安裝 speedtest..."

    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        apt-get update
        apt-get install -y curl
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
        apt-get install -y speedtest || true
    elif [ "$OS" = "centos" ]; then
        yum install -y curl
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash
        yum install -y speedtest || true
    else
        echo "暫不支援此系統的一鍵安裝 speedtest，請參考官方文檔手動安裝。"
        return 1
    fi

    cmd=$(find_speedtest_cmd)
    if [ -z "$cmd" ]; then
        echo "自動安裝 speedtest 似乎沒有成功，請手動安裝。"
        return 1
    fi

    echo "已成功安裝 speedtest 命令：$cmd"
    return 0
}

# 使用 speedtest 測試帶寬
auto_detect_bw() {
    local ST_CMD
    ST_CMD=$(find_speedtest_cmd)

    if [ -z "$ST_CMD" ]; then
        install_speedtest || return 1
        ST_CMD=$(find_speedtest_cmd)
        if [ -z "$ST_CMD" ]; then
            return 1
        fi
    fi

    echo ""
    echo "正在使用 $ST_CMD 測試帶寬，這可能需要一段時間..."
    local OUTPUT
    if [ "$(basename "$ST_CMD")" = "speedtest" ]; then
        OUTPUT=$($ST_CMD -y 2>/dev/null)
    else
        OUTPUT=$($ST_CMD 2>/dev/null)
    fi

    if [ -z "$OUTPUT" ]; then
        echo "speedtest 輸出為空，測速失敗。"
        return 1
    fi

    local DL_LINE DL_VALUE
    DL_LINE=$(echo "$OUTPUT" | grep -i "Download" | head -n1)
    if [ -z "$DL_LINE" ]; then
        echo "無法從 speedtest 輸出中找到 Download 行。"
        return 1
    fi

    DL_VALUE=$(echo "$DL_LINE" | awk '{
        for(i=1;i<=NF;i++){
            if($i ~ /^[0-9.]+$/){print $i; exit}
        }
    }')

    if [ -z "$DL_VALUE" ]; then
        echo "無法解析下載帶寬數值。"
        return 1
    fi

    # 四捨五入到整數 Mbps
    BW_INT=$(awk -v v="$DL_VALUE" 'BEGIN{printf "%d", v+0.5}')
    if [ "$BW_INT" -le 0 ]; then
        echo "解析出的帶寬數值非法：$BW_INT"
        return 1
    fi

    echo "speedtest 測得下行帶寬約為：${BW_INT} Mbps"
    BW="$BW_INT"
    return 0
}

# ====== 讀取硬體配置（CPU / 內存支援小數） ======
echo "請按提示輸入 VPS 硬體配置："
read -p "請輸入 CPU 核心數 (例如 1 或 2 或 1.5): " CPU
read -p "請輸入 記憶體大小 (GB) (例如 0.5 或 2): " RAM

if ! is_number "$CPU" || ! is_number "$RAM"; then
    echo "輸入錯誤：CPU / 記憶體 必須是數字（可以是整數或小數，例如 1、2、0.5）。"
    exit 1
fi

if [ "$(echo "$CPU <= 0" | bc)" -eq 1 ] || [ "$(echo "$RAM <= 0" | bc)" -eq 1 ]; then
    echo "輸入錯誤：CPU / 記憶體 必須大於 0。"
    exit 1
fi

echo ""
read -p "是否使用 speedtest 自動測速獲取帶寬？(y/N): " USE_AUTO

BW=""   # 之後會存成「整數 Mbps」

if [[ "$USE_AUTO" =~ ^[Yy]$ ]]; then
    if ! auto_detect_bw; then
        echo ""
        echo "自動測速失敗，或你拒絕安裝 speedtest。"
        echo "改為手動輸入帶寬模式。"
    fi
fi

# 手動輸入帶寬（自動測速沒成功 或 選 N）
if [ -z "$BW" ]; then
    echo ""
    read -p "請輸入實際可用帶寬 (Mbps，例如 2000 或 150.5): " BW_INPUT
    if ! is_number "$BW_INPUT"; then
        echo "輸入錯誤：帶寬必須是數字（可以是整數或小數）。"
        exit 1
    fi
    BW=$(awk -v v="$BW_INPUT" 'BEGIN{printf "%d", v+0.5}')
    if [ "$BW" -le 0 ]; then
        echo "輸入錯誤：帶寬必須大於 0。"
        exit 1
    fi
fi

echo ""
echo "最終將使用以下輸入參數："
echo "  CPU    = ${CPU} C"
echo "  記憶體 = ${RAM} G"
echo "  帶寬   = ${BW} Mbps"
echo ""

# ====== 計算緩衝區大小 ======
# 基準：2C 2G 2000Mbps → 默認值 65536，最大值 10000000
DEFAULT_BASE=65536
MAX_BASE=10000000

CPU_FACTOR=$(echo "scale=4; $CPU / 2" | bc)
RAM_FACTOR=$(echo "scale=4; $RAM / 2" | bc)
DEFAULT_FACTOR=$(echo "scale=4; ($CPU_FACTOR + $RAM_FACTOR) / 2" | bc)
BW_FACTOR=$(echo "scale=4; $BW / 2000" | bc)

NEW_DEFAULT_FLOAT=$(echo "scale=4; $DEFAULT_BASE * $DEFAULT_FACTOR" | bc)
NEW_MAX_FLOAT=$(echo "scale=4; $MAX_BASE * $BW_FACTOR" | bc)

NEW_DEFAULT=$(printf "%.0f" "$NEW_DEFAULT_FLOAT")
NEW_MAX=$(printf "%.0f" "$NEW_MAX_FLOAT")

# 保證不低於最小值 4096，且最大值不小於默認值
if [ "$NEW_DEFAULT" -lt 4096 ]; then
    NEW_DEFAULT=4096
fi
if [ "$NEW_MAX" -lt "$NEW_DEFAULT" ]; then
    NEW_MAX="$NEW_DEFAULT"
fi

echo "==== 計算結果預覽 ===="
echo "net.core.rmem_max = $NEW_MAX"
echo "net.core.wmem_max = $NEW_MAX"
echo "net.ipv4.tcp_rmem = 4096 $NEW_DEFAULT $NEW_MAX"
echo "net.ipv4.tcp_wmem = 4096 $NEW_DEFAULT $NEW_MAX"
echo ""

read -p "是否將以上參數寫入 /etc/sysctl.conf 並立即生效？[y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "已取消，不會修改系統配置。"
    exit 0
fi

SYSCTL_FILE="/etc/sysctl.conf"
BACKUP_FILE="/etc/sysctl.conf.bak_$(date +%Y%m%d_%H%M%S)"

cp "$SYSCTL_FILE" "$BACKUP_FILE"
echo "已備份原始配置到: $BACKUP_FILE"
echo ""

cat >> "$SYSCTL_FILE" <<EOF

################## BageVM TCP 優化模板（智能腳本生成） ##################
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
################## BageVM TCP 優化模板（智能腳本生成結束） ##################
EOF

echo "已寫入 /etc/sysctl.conf，正在執行 sysctl -p 使配置生效..."
echo ""
sysctl -p

echo ""
echo "====== TCP 智能網絡參數調優完成 ======"
echo "當前生效的關鍵參數："
echo "  net.core.rmem_max = $NEW_MAX"
echo "  net.core.wmem_max = $NEW_MAX"
echo "  net.ipv4.tcp_rmem = 4096 $NEW_DEFAULT $NEW_MAX"
echo "  net.ipv4.tcp_wmem = 4096 $NEW_DEFAULT $NEW_MAX"
echo "如需恢復，可使用備份檔案：$BACKUP_FILE"
