#!/bin/bash

###############################################################################
# 快速安装脚本 - DD系统后常用软件安装
# 功能：更新系统、安装常用软件、启用BBR+FQ
###############################################################################

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo "错误: 此脚本需要root权限运行"
    exit 1
fi

echo "=========================================="
echo "开始执行快速安装脚本"
echo "=========================================="

# 更新软件包列表
echo "[1/3] 更新软件包列表..."
apt update -qq || {
    echo "警告: apt update 失败，继续执行..."
}

# 升级系统
echo "[2/3] 升级系统..."
apt upgrade -y -qq || {
    echo "警告: apt upgrade 失败，继续执行..."
}

# 安装软件包
echo "[3/3] 安装常用软件..."
apt install -y -qq sudo curl iperf3 mtr-tiny wget nano vim git iputils-ping dnsutils lsof net-tools jq whois nmap >/dev/null 2>&1 || true

# 安装nexttrace
echo "安装 nexttrace..."
# 先尝试从默认仓库安装
if apt install -y -qq nexttrace >/dev/null 2>&1; then
    echo "nexttrace 已安装"
else
    # 添加nexttrace官方仓库
    echo "添加 nexttrace 官方仓库..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://github.com/nxtrace/nexttrace-debs/releases/latest/download/nexttrace-archive-keyring.gpg -o /etc/apt/keyrings/nexttrace.gpg >/dev/null 2>&1 || true
    
    if [[ -f /etc/apt/keyrings/nexttrace.gpg ]]; then
        echo "Types: deb
URIs: https://github.com/nxtrace/nexttrace-debs/releases/latest/download/
Suites: ./
Signed-By: /etc/apt/keyrings/nexttrace.gpg" > /etc/apt/sources.list.d/nexttrace.sources 2>/dev/null || true
        
        # 更新仓库并安装
        apt update -qq >/dev/null 2>&1 || true
        if apt install -y -qq nexttrace >/dev/null 2>&1; then
            echo "nexttrace 已从官方仓库安装"
        else
            # 如果还是失败，从GitHub下载二进制文件
            echo "从GitHub下载 nexttrace..."
            ARCH=$(uname -m)
            case "$ARCH" in
                x86_64) ARCH="amd64" ;;
                aarch64) ARCH="arm64" ;;
                *) ARCH="amd64" ;;
            esac
            if wget -q -O /tmp/nexttrace "https://github.com/nxtrace/Ntrace-core/releases/latest/download/nexttrace-linux-${ARCH}" >/dev/null 2>&1; then
                chmod +x /tmp/nexttrace
                mv /tmp/nexttrace /usr/local/bin/nexttrace 2>/dev/null || true
                echo "nexttrace 已从GitHub安装"
            else
                echo "nexttrace 安装失败，跳过"
            fi
        fi
    else
        # 如果添加仓库失败，直接从GitHub下载
        echo "从GitHub下载 nexttrace..."
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) ARCH="amd64" ;;
            aarch64) ARCH="arm64" ;;
            *) ARCH="amd64" ;;
        esac
        if wget -q -O /tmp/nexttrace "https://github.com/nxtrace/Ntrace-core/releases/latest/download/nexttrace-linux-${ARCH}" >/dev/null 2>&1; then
            chmod +x /tmp/nexttrace
            mv /tmp/nexttrace /usr/local/bin/nexttrace 2>/dev/null || true
            echo "nexttrace 已从GitHub安装"
        else
            echo "nexttrace 安装失败，跳过"
        fi
    fi
fi

# 配置BBR+FQ
echo "配置BBR+FQ..."

# 备份原配置
if [[ -f /etc/sysctl.conf ]]; then
    cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
fi

# 检查并加载BBR模块
if ! lsmod | grep -q tcp_bbr; then
    modprobe tcp_bbr 2>/dev/null || true
fi

# 写入sysctl配置（追加BBR+FQ配置，如果不存在的话）
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    cat >> /etc/sysctl.conf << 'EOF'

# BBR+FQ 优化配置
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
fi

# 应用配置
sysctl -p >/dev/null 2>&1 || true

echo "=========================================="
echo "快速安装完成！"
echo "=========================================="
