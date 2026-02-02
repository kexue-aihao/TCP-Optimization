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

# 下载 ITDOG 探测节点 IP 列表
ITDOG_URL="https://raw.githubusercontent.com/IcyBlue17/dont_ping_me/main/itdog.txt"
TEMP_FILE="/tmp/itdog_ips_$$.txt"

echo "正在下载 ITDOG 探测节点 IP 列表..."
if command -v wget &>/dev/null; then
    wget -qO "$TEMP_FILE" "$ITDOG_URL" || curl -sL -o "$TEMP_FILE" "$ITDOG_URL"
else
    curl -sL -o "$TEMP_FILE" "$ITDOG_URL"
fi

# 提取有效 IP 或 CIDR（支持单 IP 和 x.x.x.x/xx 格式）
IPS=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$TEMP_FILE" 2>/dev/null | sort -u)
COUNT=$(echo "$IPS" | grep -c . 2>/dev/null || true)
rm -f "$TEMP_FILE"

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
