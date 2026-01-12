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
echo "[1/5] 更新软件包列表..."
apt update -qq >/dev/null 2>&1 || {
    echo "警告: apt update 失败，继续执行..."
}

# 升级系统
echo "[2/5] 升级系统..."
apt upgrade -y -qq >/dev/null 2>&1 || {
    echo "警告: apt upgrade 失败，继续执行..."
}

# 安装常用软件包
echo "[3/5] 安装常用软件..."
apt install -y -qq iperf3 ncdu iftop curl unzip wget ethtool mtr net-tools sudo >/dev/null 2>&1 || {
    echo "警告: 部分软件包安装失败，继续执行..."
}

# 安装nexttrace
echo "[4/5] 安装 nexttrace..."
bash -c "$(curl -Ls https://raw.githubusercontent.com/xgadget-lab/nexttrace/main/nt_install.sh)" >/dev/null 2>&1 || {
    echo "警告: nexttrace 安装失败，跳过"
}

# 安装speedtest
echo "[5/5] 安装 speedtest..."
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash >/dev/null 2>&1 || {
    echo "警告: speedtest 仓库添加失败，跳过安装"
}
apt-get install -y speedtest >/dev/null 2>&1 || {
    echo "警告: speedtest 安装失败，跳过"
}

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
