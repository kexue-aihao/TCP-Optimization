#!/bin/bash
# ITDOG 探测节点拉黑脚本 - VPS 层面拉黑 ping/tcping/HTTP 探测 IP
# 数据来源: https://github.com/IcyBlue17/dont_ping_me
# 用法: bash block_itdog.sh

set -e

# root 检查
[[ $EUID -ne 0 ]] && { echo "请使用 root 运行: sudo bash $0"; exit 1; }

# 缺失依赖时自动安装并重新执行
install_ipset() {
    echo "检测到 ipset 未安装，正在尝试自动安装..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null; apt-get install -y ipset
    elif command -v yum &>/dev/null; then
        yum install -y ipset
    elif command -v dnf &>/dev/null; then
        dnf install -y ipset
    elif command -v apk &>/dev/null; then
        apk add --no-cache ipset
    else
        echo "无法识别包管理器，请手动安装: apt install ipset 或 yum install ipset"
        return 1
    fi
}
if ! command -v ipset &>/dev/null; then
    if install_ipset; then
        if command -v ipset &>/dev/null; then
            echo "ipset 安装成功，重新执行脚本..."
            SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
            exec bash "$SCRIPT_PATH"
        fi
    fi
fi

# 获取 ITDOG 探测节点 IP（从 GitHub + 本地收集）
get_itdog_ips() {
    # 1. 尝试从 GitHub 下载最新列表
    ITDOG_URL="https://raw.githubusercontent.com/IcyBlue17/dont_ping_me/main/itdog.txt"
    TEMP_FILE="/tmp/itdog_ips_$$.txt"
    
    echo "正在下载 ITDOG 探测节点 IP 列表..."
    if command -v wget &>/dev/null; then
        wget -qO "$TEMP_FILE" "$ITDOG_URL" 2>/dev/null || curl -sL -o "$TEMP_FILE" "$ITDOG_URL" 2>/dev/null || true
    else
        curl -sL -o "$TEMP_FILE" "$ITDOG_URL" 2>/dev/null || true
    fi
    
    # 2. 合并本地收集的 IP（从 tcpdump 抓取）
    cat >> "$TEMP_FILE" << 'LOCALIPS'
211.95.35.189
117.148.172.71
180.163.134.53
106.225.223.67
112.67.249.58
119.96.16.114
116.153.63.68
36.158.204.68
150.223.3.94
223.26.78.6
36.104.133.71
218.98.53.91
124.160.160.70
211.139.55.70
202.108.15.148
111.32.145.8
223.244.186.68
49.71.77.84
117.161.136.74
27.185.235.70
36.136.125.68
112.90.210.132
112.29.205.70
180.97.244.136
58.211.13.98
125.77.129.206
222.75.5.70
222.79.71.253
112.91.160.101
59.80.45.132
211.91.233.130
14.205.46.244
183.95.221.228
112.16.227.111
111.180.136.169
117.176.244.250
122.247.217.59
43.163.239.208
183.246.188.214
218.64.94.212
218.91.221.95
183.205.177.20
117.177.67.15
42.81.156.75
49.119.120.226
120.71.150.171
156.225.76.237
101.70.156.68
42.185.158.83
60.26.220.104
43.130.151.11
43.131.29.194
194.147.100.44
38.54.63.220
38.54.59.59
LOCALIPS
    
    # 提取有效 IP 或 CIDR
    grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$TEMP_FILE" 2>/dev/null | sort -u
    rm -f "$TEMP_FILE"
}

IPS=$(get_itdog_ips)
COUNT=$(echo "$IPS" | grep -c . 2>/dev/null || true)

[[ $COUNT -eq 0 ]] && { echo "错误: 未获取到 IP 数据，请检查网络或源地址"; exit 1; }

echo "共 $COUNT 个 ITDOG 探测节点 IP"

# 优先使用 ipset
if command -v ipset &>/dev/null; then
    echo "使用 ipset 模式..."
    ipset create itdog hash:net hashsize 512 maxelem 2048 2>/dev/null || ipset flush itdog
    echo "$IPS" | while read -r addr; do
        [[ -z "$addr" ]] && continue
        # 单 IP 转为 /32
        [[ "$addr" == *"/"* ]] || addr="$addr/32"
        ipset add itdog "$addr" 2>/dev/null || true
    done
    if ! iptables -C INPUT -m set --match-set itdog src -j DROP 2>/dev/null; then
        iptables -I INPUT -m set --match-set itdog src -j DROP
        echo "已添加 iptables 规则"
    fi
    ipset save > /etc/ipset.conf 2>/dev/null && echo "ipset 已保存" || true
else
    echo "使用纯 iptables 模式..."
    echo "$IPS" | while read -r addr; do
        [[ -z "$addr" ]] && continue
        [[ "$addr" == *"/"* ]] || addr="$addr/32"
        iptables -A INPUT -s "$addr" -j DROP 2>/dev/null || true
    done
    echo "已添加 iptables 规则"
fi

# 持久化
mkdir -p /etc/iptables 2>/dev/null
iptables-save > /etc/iptables/rules.v4 2>/dev/null && echo "iptables 已保存" || true

echo "完成! ITDOG 探测节点已拉黑"
