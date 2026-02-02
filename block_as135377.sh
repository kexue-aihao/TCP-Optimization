#!/bin/bash
# AS135377 拉黑一键脚本 - 使用 ipset
# 需 root 权限运行: sudo bash as135377-apply.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX_FILE="${1:-$SCRIPT_DIR/as135377-prefix.txt}"

CIDRS=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' "$PREFIX_FILE")
COUNT=$(echo "$CIDRS" | grep -c . || true)

[[ $COUNT -eq 0 ]] && { echo "错误: 未找到 CIDR，请检查输入文件"; exit 1; }

echo "共 $COUNT 个网段，正在创建 ipset..."

# 创建或清空 ipset
ipset create as135377 hash:net hashsize 2048 maxelem 65536 2>/dev/null || ipset flush as135377

# 添加网段
echo "$CIDRS" | while read -r cidr; do
    [[ -z "$cidr" ]] && continue
    ipset add as135377 "$cidr" 2>/dev/null || true
done

# 添加 iptables 规则（如不存在）
if ! iptables -C INPUT -m set --match-set as135377 src -j DROP 2>/dev/null; then
    iptables -I INPUT -m set --match-set as135377 src -j DROP
    echo "已添加 iptables 规则"
fi

# 持久化
ipset save > /etc/ipset.conf 2>/dev/null && echo "ipset 已保存" || true
iptables-save > /etc/iptables/rules.v4 2>/dev/null && echo "iptables 已保存" || true

echo "完成! AS135377 已拉黑"
