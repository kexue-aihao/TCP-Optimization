#!/bin/bash

###############################################################################
# BBR+FQ 配置脚本（Amazon Linux / ARM64）
# 功能：仅开启 BBR 拥塞控制 + fq 队列（无其它 sysctl 调参）
# 适用：Amazon Linux 2/2023 on aarch64（graviton 等）
###############################################################################

set -uo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
readonly SYSCTL_DROPIN="/etc/sysctl.d/99-bbr-fq.conf"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

CLEANUP_FUNCTIONS=()

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

cleanup() {
    log_info "执行清理操作..."
    for func in "${CLEANUP_FUNCTIONS[@]}"; do
        $func || true
    done
}

trap cleanup EXIT INT TERM

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

# 架构提示：本脚本面向 ARM64（aarch64），x86_64 上通常也可用
check_arch() {
    local arch
    arch=$(uname -m)
    log_info "机器架构: $arch"
    case "$arch" in
        aarch64|arm64)
            ;;
        x86_64)
            log_warn "当前为 x86_64，脚本主要为 Amazon ARM 实例编写；内核支持 BBR 时仍可生效"
            ;;
        *)
            log_warn "未识别的架构 $arch，若内核 >= 4.9 且含 BBR，可继续尝试"
            ;;
    esac
}

# 需要时尝试安装内核头文件以便编译/加载模块（Amazon Linux 用 yum/dnf）
try_install_kernel_headers() {
    local kver
    kver=$(uname -r)
    if command_exists dnf; then
        dnf install -y "kernel-devel-${kver}" 2>/dev/null || \
        dnf install -y kernel-devel 2>/dev/null || true
    elif command_exists yum; then
        yum install -y "kernel-devel-${kver}" 2>/dev/null || \
        yum install -y kernel-devel 2>/dev/null || true
    elif command_exists apt-get; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "linux-headers-${kver}" >/dev/null 2>&1 || true
    fi
}

load_bbr_module() {
    if lsmod | grep -q '^tcp_bbr'; then
        log_info "BBR 模块已加载"
        return 0
    fi
    log_info "加载 tcp_bbr 模块..."
    if modprobe tcp_bbr 2>/dev/null; then
        log_info "tcp_bbr 加载成功"
        return 0
    fi
    log_warn "modprobe tcp_bbr 失败，尝试安装内核头文件后重试..."
    try_install_kernel_headers
    modprobe tcp_bbr 2>/dev/null && log_info "tcp_bbr 加载成功" && return 0
    log_warn "仍无法加载 tcp_bbr（部分内核将 BBR 内置，可继续设置 sysctl）"
    return 0
}

kernel_supports_bbr() {
    local kernel_version kernel_major kernel_minor
    kernel_version=$(uname -r | cut -d. -f1,2)
    IFS='.' read -r kernel_major kernel_minor <<< "$kernel_version"
    if [[ ${kernel_major:-0} -lt 4 ]] || [[ ${kernel_major:-0} -eq 4 && ${kernel_minor:-0} -lt 9 ]]; then
        return 1
    fi
    return 0
}

write_bbr_sysctl_dropin() {
    log_info "写入 ${SYSCTL_DROPIN}（仅 BBR + fq）..."
    cat > "$SYSCTL_DROPIN" << 'EOF'
# BBR + FQ only (Amazon ARM / generic)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
}

apply_sysctl() {
    log_info "应用 sysctl..."
    if sysctl -p "$SYSCTL_DROPIN" 2>/dev/null; then
        :
    else
        sysctl --system 2>/dev/null || sysctl -p 2>/dev/null || true
    fi
}

verify_bbr_fq() {
    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    log_info "当前拥塞控制: $cc"
    log_info "当前默认队列: $qdisc"
    if [[ "$cc" == "bbr" && "$qdisc" == "fq" ]]; then
        log_info "✓ BBR+FQ 已生效"
        return 0
    fi
    log_warn "未完全生效（cc=$cc, qdisc=$qdisc），可检查内核或重启后再试"
    return 1
}

main() {
    log_info "=========================================="
    log_info "BBR+FQ 仅启用模式（Amazon / ARM）"
    log_info "=========================================="

    check_root
    check_arch

    if ! kernel_supports_bbr; then
        log_warn "内核版本可能低于 4.9，BBR 可能不可用"
    fi

    load_bbr_module

    write_bbr_sysctl_dropin
    apply_sysctl
    sleep 1
    verify_bbr_fq || true

    log_info "=========================================="
    log_info "完成。持久化配置: ${SYSCTL_DROPIN}"
    log_info "=========================================="
}

main "$@"
