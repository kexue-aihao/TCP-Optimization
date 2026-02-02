#!/bin/bash
# ITDOG 探测节点拉黑脚本 - VPS 层面拉黑 ping/tcping/HTTP 探测 IP
# 数据来源: https://github.com/IcyBlue17/dont_ping_me
# 用法: bash block_itdog.sh
#        bash block_itdog.sh remove <IP> [IP2 ...]   # 从拉黑规则中移除指定 IP 并保存

set -e

# root 检查
[[ $EUID -ne 0 ]] && { echo "请使用 root 运行: sudo bash $0"; exit 1; }

# ---------- 子命令: remove 移除指定 IP ----------
if [[ "${1:-}" == "remove" ]]; then
    shift
    [[ $# -eq 0 ]] && { echo "用法: $0 remove <IP> [IP2 ...]"; exit 1; }
    normalized() {
        local a="$1"
        [[ "$a" == *"/"* ]] || a="$a/32"
        echo "$a"
    }
    removed=0
    while [[ $# -gt 0 ]]; do
        raw="$1"
        addr=$(normalized "$raw")
        base_ip="${addr%%/*}"
        if ipset list itdog &>/dev/null; then
            if ipset del itdog "$addr" 2>/dev/null || ipset del itdog "$base_ip" 2>/dev/null; then
                echo "已从 ipset(itdog) 移除: $base_ip"
                ((removed++)) || true
            fi
        fi
        if iptables -D INPUT -s "$base_ip" -j DROP 2>/dev/null; then
            echo "已删除 iptables 规则: $base_ip"
            ((removed++)) || true
        elif iptables -D INPUT -s "$addr" -j DROP 2>/dev/null; then
            echo "已删除 iptables 规则: $addr"
            ((removed++)) || true
        fi
        shift
    done
    if [[ $removed -gt 0 ]]; then
        ipset save > /etc/ipset.conf 2>/dev/null && echo "ipset 已保存" || true
        mkdir -p /etc/iptables 2>/dev/null
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && echo "iptables 已保存" || true
        echo "完成! 已撤销指定 IP 的拉黑规则"
    else
        echo "未找到或未移除任何规则（可能该 IP 本不在拉黑列表中）"
    fi
    exit 0
fi

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
1.71.14.77
1.193.215.70
1.194.195.182
14.205.46.244
23.225.146.6
27.44.127.113
27.185.235.70
36.104.133.71
36.104.136.154
36.136.125.68
36.156.28.126
36.158.204.68
36.163.196.91
36.250.8.139
38.54.45.156
38.54.59.59
38.54.63.220
38.54.126.18
38.60.209.194
39.130.253.208
42.63.75.72
42.81.156.75
42.185.158.83
42.202.219.70
43.130.151.11
43.131.29.194
43.156.69.84
43.163.239.208
49.71.77.84
49.119.120.226
58.19.20.71
58.211.13.98
59.36.216.228
59.37.89.72
59.80.45.132
60.26.220.104
61.134.71.167
61.156.170.245
61.179.224.11
81.225.215.118
101.28.250.72
101.70.156.68
101.207.252.75
103.239.185.87
106.225.223.67
111.12.212.73
111.13.153.72
111.26.149.68
111.29.45.133
111.32.145.8
111.42.192.68
111.45.68.178
111.48.137.135
111.62.174.73
111.124.196.26
111.180.136.169
112.16.227.111
112.17.53.253
112.29.205.70
112.48.150.134
112.48.230.122
112.67.249.58
112.90.210.132
112.91.160.101
112.123.37.77
112.192.18.61
113.62.118.132
113.142.188.61
113.142.209.125
113.200.41.120
113.201.9.12
113.207.73.135
113.240.100.81
115.223.6.243
116.53.37.105
116.136.19.134
116.153.63.68
116.162.51.68
116.172.154.17
116.176.33.201
116.178.236.69
116.196.137.180
117.68.54.243
117.148.172.71
117.157.235.95
117.161.136.74
117.168.153.198
117.176.244.250
117.177.67.15
117.180.235.132
117.186.171.10
117.187.147.235
117.187.182.132
118.213.140.68
119.96.16.114
119.147.118.127
120.71.150.171
120.201.243.134
120.220.190.144
120.232.121.81
120.232.140.54
120.233.3.233
120.233.53.26
120.233.64.219
121.31.236.73
122.225.28.184
122.247.217.59
123.6.70.5
124.160.160.70
125.64.2.134
125.72.141.121
125.77.129.206
125.211.192.35
139.170.157.197
139.170.157.222
139.180.169.124
139.209.203.28
140.210.12.62
150.109.245.197
150.139.140.89
150.223.3.94
153.0.230.8
156.225.76.237
156.253.8.27
171.109.103.69
180.95.228.8
180.97.244.136
180.130.108.61
180.163.134.53
182.242.83.133
183.2.175.36
183.95.221.228
183.201.192.92
183.205.177.20
183.246.188.214
183.249.101.84
194.147.100.44
202.108.15.148
202.112.237.201
211.91.67.89
211.91.233.130
211.95.35.189
211.139.55.70
218.24.85.60
218.60.79.228
218.63.8.167
218.64.94.212
218.91.221.95
218.98.53.91
219.151.141.70
220.162.119.105
220.164.107.98
221.130.18.132
221.180.208.210
221.181.52.170
221.204.62.68
222.75.5.70
222.79.71.253
223.26.78.6
223.109.39.219
223.109.46.112
223.244.186.68
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
