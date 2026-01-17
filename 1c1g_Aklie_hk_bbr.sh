#!/bin/bash

###############################################################################
# BBR+FQ 配置脚本
# 功能：开启BBR+FQ加速并配置系统参数
# 版本：1.0
###############################################################################

set -uo pipefail  # 严格模式：未定义变量报错，管道失败报错（不使用-e，允许某些步骤失败后继续）

###############################################################################
# 全局变量和配置
###############################################################################

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# 清理函数列表
CLEANUP_FUNCTIONS=()

###############################################################################
# 工具函数
###############################################################################

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

# 错误处理函数
error_exit() {
    local exit_code=${1:-1}
    log_error "脚本执行失败，退出码: $exit_code"
    cleanup
    exit "$exit_code"
}

# 清理函数
cleanup() {
    log_info "执行清理操作..."
    
    # 执行所有注册的清理函数
    for func in "${CLEANUP_FUNCTIONS[@]}"; do
        $func || true
    done
}

# 注册清理函数
register_cleanup() {
    CLEANUP_FUNCTIONS+=("$1")
}

# 设置退出trap
trap cleanup EXIT INT TERM

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

###############################################################################
# BBR安装函数 - 直接配置方式（Debian 12内核已支持BBR）
###############################################################################

install_bbr() {
    log_info "开始BBR+FQ配置流程..."
    log_info "使用直接配置方式，无需交互式安装（Debian 12内核已支持BBR）"
    
    # 第一步：检查内核版本和BBR支持
    log_info "检查内核版本和BBR支持..."
    local kernel_version
    kernel_version=$(uname -r | cut -d. -f1,2)
    log_info "当前内核版本: $(uname -r)"
    
    # 检查内核是否支持BBR（需要内核版本 >= 4.9）
    local kernel_major kernel_minor
    IFS='.' read -r kernel_major kernel_minor <<< "$kernel_version"
    
    if [[ $kernel_major -lt 4 ]] || [[ $kernel_major -eq 4 && $kernel_minor -lt 9 ]]; then
        log_warn "内核版本过低（${kernel_version}），BBR需要内核 >= 4.9"
        log_info "尝试加载BBR模块..."
        modprobe tcp_bbr 2>/dev/null || {
            log_error "无法加载BBR模块，可能需要升级内核"
            log_info "可以手动执行: bash <(curl -sL https://raw.githubusercontent.com/teddysun/across/master/bbr.sh)"
            return 1
        }
    fi
    
    # 检查BBR模块是否可用
    if ! lsmod | grep -q tcp_bbr; then
        log_info "加载BBR模块..."
        if modprobe tcp_bbr 2>/dev/null; then
            log_info "BBR模块加载成功"
        else
            log_warn "无法加载BBR模块，尝试编译安装..."
            # 如果模块不存在，尝试安装
            if command_exists apt-get; then
                apt-get update -qq >/dev/null 2>&1
                apt-get install -y -qq linux-headers-$(uname -r) >/dev/null 2>&1 || true
                modprobe tcp_bbr 2>/dev/null || log_warn "BBR模块加载失败，继续配置（可能内核已内置BBR）"
            fi
        fi
    else
        log_info "BBR模块已加载"
    fi
    
    # 第四步：验证BBR是否启用
    log_info "验证BBR配置..."
    sleep 2
    
    local current_cc current_qdisc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    
    log_info "当前拥塞控制算法: $current_cc"
    log_info "当前队列算法: $current_qdisc"
    
    if [[ "$current_cc" == "bbr" ]] && [[ "$current_qdisc" == "fq" ]]; then
        log_info "✓ BBR+FQ配置成功！"
        
        # 验证BBR模块
        if lsmod | grep -q tcp_bbr; then
            log_info "✓ BBR模块已加载"
        else
            log_warn "BBR模块未加载（可能内核已内置BBR）"
        fi
        
        # 显示当前TCP连接使用的拥塞控制
        log_info "验证TCP连接状态..."
        local tcp_bbr_count
        tcp_bbr_count=$(ss -tin 2>/dev/null | grep -c bbr || echo "0")
        if [[ $tcp_bbr_count -gt 0 ]]; then
            log_info "✓ 发现 $tcp_bbr_count 个使用BBR的TCP连接"
        else
            log_info "当前没有活跃的TCP连接使用BBR（新连接将使用BBR）"
        fi
        
        return 0
    else
        log_warn "BBR配置可能未完全生效"
        log_info "当前配置: cc=$current_cc, qdisc=$current_qdisc"
        log_info "配置将在sysctl配置应用后生效"
        return 0  # 继续执行，因为sysctl配置会设置BBR
    fi
}

###############################################################################
# 系统参数调优函数
###############################################################################

configure_sysctl() {
    log_info "配置系统参数..."
    
    # 备份原配置
    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
        log_info "已备份原配置到: /etc/sysctl.conf.bak.$(date +%s)"
    fi
    
    # 写入新配置
    log_info "写入sysctl配置..."
    cat > /etc/sysctl.conf << 'EOF'
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
net.core.rmem_max=2500000
net.core.wmem_max=2500000
net.ipv4.tcp_rmem=4096 65536 2500000
net.ipv4.tcp_wmem=4096 65536 2500000
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    
    # 应用配置
    log_info "应用sysctl配置..."
    if sysctl -p && sysctl --system; then
        log_info "✓ 系统参数配置成功"
        
        # 验证配置
        sleep 2
        local current_cc current_qdisc
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
        current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
        
        log_info "当前拥塞控制算法: $current_cc"
        log_info "当前队列算法: $current_qdisc"
        
        if [[ "$current_cc" == "bbr" ]] && [[ "$current_qdisc" == "fq" ]]; then
            log_info "✓ BBR+FQ已成功启用！"
        else
            log_warn "BBR+FQ可能未完全生效，可能需要重启系统"
        fi
        
        return 0
    else
        log_warn "系统参数配置可能未完全成功"
        return 1
    fi
}

###############################################################################
# 主函数
###############################################################################

main() {
    log_info "=========================================="
    log_info "开始执行BBR+FQ配置脚本"
    log_info "=========================================="
    
    # 检查root权限
    check_root
    
    # 第一部分：BBR安装和配置
    log_info "[1/2] 配置BBR+FQ..."
    if install_bbr; then
        log_info "BBR配置检查完成"
    else
        log_warn "BBR配置检查可能未完全成功，继续执行"
    fi
    
    # 等待系统稳定
    log_info "等待系统稳定（2秒）..."
    sleep 2
    
    # 第二部分：系统参数调优
    log_info "[2/2] 配置系统参数..."
    if configure_sysctl; then
        log_info "系统参数配置成功"
    else
        log_warn "系统参数配置可能未完全成功"
    fi
    
    log_info "=========================================="
    log_info "所有配置任务完成！"
    log_info "=========================================="
}

###############################################################################
# 执行主函数
###############################################################################

main "$@"
