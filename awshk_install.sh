#!/bin/bash

###############################################################################
# 自动化安装脚本 - 生产级版本
# 功能：SSH配置、BBR加速安装、系统参数调优、nyanpass安装
# 作者：顶级Shell脚本程序员
# 版本：2.0
###############################################################################

set -uo pipefail  # 严格模式：未定义变量报错，管道失败报错（不使用-e，允许某些步骤失败后继续）

###############################################################################
# 全局变量和配置
###############################################################################

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly LOG_FILE="/tmp/${SCRIPT_NAME}.log"
readonly BBR_LOG="/tmp/bbr_install.log"
readonly TIMEOUT_BBR=600  # BBR安装超时时间（10分钟）
readonly TIMEOUT_NYANPASS=600  # nyanpass安装超时时间

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
    
    # 清理残留进程（如果需要）
    pkill -9 -f "kejilio" 2>/dev/null || true
    pkill -9 -f "kejilion" 2>/dev/null || true
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

# 等待进程结束
wait_for_process() {
    local pid=$1
    local timeout=${2:-60}
    local count=0
    
    while kill -0 "$pid" 2>/dev/null && [[ $count -lt $timeout ]]; do
        sleep 1
        ((count++))
    done
    
    if kill -0 "$pid" 2>/dev/null; then
        return 1  # 超时
    fi
    return 0
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
    
    # 第二步：配置sysctl参数
    log_info "配置BBR和FQ参数..."
    
    # 备份原sysctl配置（如果存在）
    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
    fi
    
    # 读取现有sysctl配置
    local sysctl_content=""
    if [[ -f /etc/sysctl.conf ]]; then
        sysctl_content=$(cat /etc/sysctl.conf)
    fi
    
    # 移除旧的BBR/FQ配置（如果存在）
    sysctl_content=$(echo "$sysctl_content" | grep -v "net.core.default_qdisc" | grep -v "net.ipv4.tcp_congestion_control")
    
    # 添加BBR和FQ配置
    {
        echo "$sysctl_content"
        echo ""
        echo "# BBR and FQ configuration - Added by install.sh"
        echo "net.core.default_qdisc = fq"
        echo "net.ipv4.tcp_congestion_control = bbr"
    } > /etc/sysctl.conf
    
    # 第三步：立即应用配置
    log_info "应用BBR和FQ配置..."
    if sysctl -p >/dev/null 2>&1; then
        log_info "sysctl配置应用成功"
    else
        log_warn "sysctl配置应用可能失败"
    fi
    
    # 应用系统级配置
    sysctl --system >/dev/null 2>&1 || true
    
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
        log_info "可能需要重启系统后生效"
        return 1
    fi
}

###############################################################################
# SSH配置函数
###############################################################################

configure_ssh() {
    log_info "配置SSH..."
    
    # 设置root密码
    if echo "root:>Qx\$qpG>1.KF3TWHv>Z=" | chpasswd 2>/dev/null; then
        log_info "Root密码设置成功"
    else
        log_warn "Root密码设置可能失败"
    fi
    
    # 配置SSH
    local sshd_config="/etc/ssh/sshd_config"
    
    if [[ -f "$sshd_config" ]]; then
        # 备份原配置
        cp "$sshd_config" "${sshd_config}.bak.$(date +%s)" 2>/dev/null || true
        
        # 修改配置
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' "$sshd_config" 2>/dev/null || true
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' "$sshd_config" 2>/dev/null || true
        
        # 删除可能冲突的配置目录
        rm -rf /etc/ssh/sshd_config.d 2>/dev/null || true
        
        # 重启SSH服务
        sleep 3
        if systemctl restart sshd 2>/dev/null; then
            log_info "SSH服务重启成功"
        else
            log_warn "SSH服务重启可能失败"
        fi
    else
        log_error "SSH配置文件不存在: $sshd_config"
        return 1
    fi
    
    log_info "SSH配置完成"
}

###############################################################################
# 系统参数调优函数
###############################################################################

configure_sysctl() {
    log_info "配置系统参数..."
    
    # 备份原配置
    if [[ -f /etc/sysctl.conf ]]; then
        cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)" 2>/dev/null || true
    fi
    
    # 写入新配置
    cat > /etc/sysctl.conf << 'SYSCTL_EOF'
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
net.core.rmem_max=10000000
net.core.wmem_max=10000000
net.ipv4.tcp_rmem=4096 190054 10000000
net.ipv4.tcp_wmem=4096 190054 10000000
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL_EOF
    
    # 应用配置
    if sysctl -p >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1; then
        log_info "系统参数配置成功"
    else
        log_warn "系统参数配置可能未完全成功"
    fi
}

###############################################################################
# nyanpass安装函数
###############################################################################

install_nyanpass() {
    local instance_num=$1
    local service_name=$2
    local token=$3
    local url=$4
    
    log_info "安装nyanpass实例${instance_num} (${service_name})..."
    
    local install_cmd="printf '${service_name}\nn\ny\n' | timeout ${TIMEOUT_NYANPASS} bash <(curl -fLSs https://dl.nyafw.com/download/nyanpass-install.sh) rel_nodeclient \"-o -t ${token} -u ${url}\""
    
    if eval "$install_cmd" 2>&1 | tee -a "$LOG_FILE"; then
        log_info "nyanpass实例${instance_num}安装完成"
        return 0
    else
        log_warn "nyanpass实例${instance_num}安装可能未完全成功"
        return 1
    fi
}

###############################################################################
# 主函数
###############################################################################

main() {
    log_info "=========================================="
    log_info "开始执行自动化安装脚本"
    log_info "=========================================="
    
    # 检查root权限
    check_root
    
    # 解析参数
    local skip_bbr=false
    if [[ "${1:-}" == "--no-bbr" ]] || [[ "${1:-}" == "-n" ]]; then
        skip_bbr=true
        log_info "跳过BBR安装模式"
    fi
    
    # 第一部分：SSH配置
    log_info "[1/10] 配置SSH..."
    if configure_ssh; then
        log_info "SSH配置成功"
    else
        log_warn "SSH配置可能未完全成功，继续执行"
    fi
    
    # 第二部分：BBR安装
    if [[ "$skip_bbr" == false ]]; then
        log_info "[2/10] 安装BBR加速..."
        if install_bbr; then
            log_info "BBR安装成功"
        else
            log_warn "BBR安装可能未完全成功，继续执行后续步骤"
        fi
        
        # 等待系统稳定
        log_info "等待系统稳定（5秒）..."
        sleep 5
    else
        log_info "[2/10] BBR加速安装..."
        log_info "已跳过BBR安装"
    fi
    
    # 第三部分：系统参数调优
    log_info "[3/10] 配置系统参数..."
    if configure_sysctl; then
        log_info "系统参数配置成功"
    else
        log_warn "系统参数配置可能未完全成功，继续执行"
    fi
    
    # 第四部分：安装nyanpass实例
    log_info "[4/10] 安装nyanpass实例1 (awshk)..."
    install_nyanpass 1 "awshk" "bcca5a9e-a28d-4870-be01-1d68ae32d632" "https://wsnbb.wetstmk.lol" || true
    
    log_info "[5/10] 安装nyanpass实例2 (jmyd)..."
    install_nyanpass 2 "jmyd" "a0a35822-4963-4a26-9dfe-b64082968794" "https://ny.1151119.xyz" || true
    
    log_info "[6/10] 安装nyanpass实例3 (jmyd2)..."
    install_nyanpass 3 "jmyd2" "23c77e98-8b12-4c49-aec3-492711714ee3" "https://bingzi.cc" || true
    
    log_info "[7/10] 安装nyanpass实例4 (gzyd)..."
    install_nyanpass 4 "gzyd" "211da760-2f54-46fa-a453-9a15e25de4fe" "https://traffic.kinako.one" || true
    
    log_info "[8/10] 安装nyanpass实例5 (zuji1)..."
    install_nyanpass 5 "zuji1" "c843cd09-93e6-4c29-bc9d-316c12fe980d" "https://ny.zesjke.top" || true

    log_info "[9/10] 安装nyanpass实例6 (jmyd4)..."
    install_nyanpass 6 "jmyd4" "2e9251bb-9ac0-4ae3-bf66-d5295c52876d" "https://wsnbb.wetstmk.lol" || true
    
    log_info "[10/10] 安装nyanpass实例7 (zuji3)..."
    install_nyanpass 7 "zuji3" "311b4e7e-6062-4eea-9347-a92d2311eaa4" "https://www.nyzf01.top" || true
    
    log_info "=========================================="
    log_info "所有安装任务完成！"
    log_info "=========================================="
}

###############################################################################
# 执行主函数
###############################################################################

main "$@"
