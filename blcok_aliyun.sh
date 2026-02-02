#!/bin/bash
# AS45102 (Alibaba US) 拉黑脚本 - 从 RIPEstat 获取前缀并用 ipset+iptables 拉黑
# 用法: sudo bash block_as45102.sh
#       sudo bash block_as45102.sh remove   # 移除拉黑规则并删除 ipset

set -e

ASN=45102
IPSET_NAME=as45102
API_URL="https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${ASN}"

# root 检查
[[ $EUID -ne 0 ]] && { echo "请使用 root 运行: sudo bash $0"; exit 1; }

# ---------- 子命令: remove 移除拉黑 ----------
if [[ "${1:-}" == "remove" ]]; then
    echo "正在移除 AS${ASN} 拉黑规则..."
    iptables -D INPUT -m set --match-set "$IPSET_NAME" src -j DROP 2>/dev/null && echo "已删除 iptables 规则" || true
    ipset destroy "$IPSET_NAME" 2>/dev/null && echo "已删除 ipset: $IPSET_NAME" || true
    ipset save > /etc/ipset.conf 2>/dev/null && echo "ipset 已保存" || true
    mkdir -p /etc/iptables 2>/dev/null
    iptables-save > /etc/iptables/rules.v4 2>/dev/null && echo "iptables 已保存" || true
    echo "完成! AS${ASN} 拉黑已撤销"
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

# 从 RIPEstat 获取 AS 的 IPv4 前缀
get_prefixes() {
    local tmp
    tmp=$(mktemp)
    if command -v wget &>/dev/null; then
        wget -qO "$tmp" "$API_URL" 2>/dev/null || curl -sL -o "$tmp" "$API_URL" 2>/dev/null || true
    else
        curl -sL -o "$tmp" "$API_URL" 2>/dev/null || true
    fi
    if [[ ! -s "$tmp" ]]; then
        echo "错误: 无法获取 AS${ASN} 前缀数据，请检查网络" >&2
        rm -f "$tmp"
        return 1
    fi
    # 解析 JSON 中的 prefix 字段（兼容 "prefix":"x.x.x.x/xx" 与 "prefix": "x.x.x.x/xx"）
    grep -oE '"prefix"[[:space:]]*:[[:space:]]*"[^"]+"' "$tmp" | sed 's/.*"\([^"]*\)"$/\1/' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' | sort -u
    rm -f "$tmp"
    return 0
}

echo "正在从 RIPEstat 获取 AS${ASN} 的 IPv4 前缀..."
CIDRS=$(get_prefixes) || exit 1
COUNT=$(echo "$CIDRS" | grep -c . || true)

[[ $COUNT -eq 0 ]] && { echo "错误: 未获取到任何前缀"; exit 1; }

echo "共 $COUNT 个网段"

# 创建或清空 ipset
ipset create "$IPSET_NAME" hash:net hashsize 2048 maxelem 65536 2>/dev/null || ipset flush "$IPSET_NAME"

# 添加网段
echo "$CIDRS" | while read -r cidr; do
    [[ -z "$cidr" ]] && continue
    ipset add "$IPSET_NAME" "$cidr" 2>/dev/null || true
done

# 添加 iptables 规则（如不存在）
if ! iptables -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP 2>/dev/null; then
    iptables -I INPUT -m set --match-set "$IPSET_NAME" src -j DROP
    echo "已添加 iptables 规则"
fi

# 持久化
ipset save > /etc/ipset.conf 2>/dev/null && echo "ipset 已保存" || true
mkdir -p /etc/iptables 2>/dev/null
iptables-save > /etc/iptables/rules.v4 2>/dev/null && echo "iptables 已保存" || true

echo "完成! AS${ASN} (Alibaba US) 已拉黑"
