#!/bin/bash
set -euo pipefail

# 临时目录用于存储测量数据
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 日志函数
log_info() {
    echo -e "${BLUE}INFO: $1${NC}"
}

log_success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}WARN: $1${NC}"
}

log_error() {
    echo -e "${RED}ERROR: $1${NC}"
}

# 检查命令是否存在
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        log_error "缺少必要工具: $1，请先安装"
        exit 1
    fi
}

# 检查依赖
check_dependency "bc"
check_dependency "ping"
check_dependency "grep"
check_dependency "awk"

# 检查参数数量
if [ $# -ne 3 ]; then
    echo "用法: $0 <带宽(Mbps)> <CPU核心数> <内存(GB)>"
    echo "示例: $0 5000 8 32"
    exit 1
fi

# 解析参数
bandwidth_mbps=$1
cpu_cores=$2
memory_gb=$3

# 参数验证
if ! [[ "$bandwidth_mbps" =~ ^[0-9]+$ ]] || ! [[ "$cpu_cores" =~ ^[0-9]+$ ]] || ! [[ "$memory_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    log_error "参数错误: 带宽和CPU核心数必须为整数，内存可以是小数"
    exit 1
fi

if [ "$bandwidth_mbps" -lt 500 ] || [ "$bandwidth_mbps" -gt 10000 ]; then
    log_error "参数错误: 带宽需在500Mbps-10000Mbps范围内"
    exit 1
fi

if [ "$cpu_cores" -le 0 ] || (( $(echo "$memory_gb <= 0" | bc -l) )); then
    log_error "参数错误: CPU核心数和内存必须为正数"
    exit 1
fi

# 1. CPU类型检测
log_info "开始检测CPU类型..."
cpu_vendor=$(grep -m 1 'vendor_id' /proc/cpuinfo | awk -F ': ' '{print $2}')
cpu_model=$(grep -m 1 'model name' /proc/cpuinfo | awk -F ': ' '{print $2}')

if [[ "$cpu_vendor" == *"Intel"* ]]; then
    cpu_type="intel"
elif [[ "$cpu_vendor" == *"AMD"* ]]; then
    cpu_type="amd"
else
    log_warn "无法识别CPU类型: $cpu_vendor，使用通用配置"
    cpu_type="generic"
fi

log_info "CPU信息: $cpu_model"
log_info "CPU类型: $(echo $cpu_type | tr '[:lower:]' '[:upper:]')"

# 2. 测量不同地区的RTT（保留RTT测量但不依赖IP地址）
log_info "开始测量网络延迟（RTT）..."

# 定义测试目标（按地区分类）
declare -A test_targets=(
    ["local"]="114.114.114.114"  # 国内通用DNS，作为本地参考
    ["north"]="202.106.0.20"    # 北京联通DNS
    ["south"]="202.96.128.166"  # 上海电信DNS
    ["east"]="218.4.4.4"        # 江苏电信DNS
    ["west"]="61.139.2.69"      # 四川电信DNS
    ["foreign"]="8.8.8.8"       # Google DNS，作为国际参考
)

# 测量RTT函数
measure_rtt() {
    local target=$1
    local count=${2:-10}
    local timeout=${3:-2}
    
    # 使用ping测量RTT，取平均值
    if ping -c "$count" -W "$timeout" "$target" &> "$TMP_DIR/ping_$target.txt"; then
        # 提取平均RTT（不同系统ping输出格式可能不同）
        avg_rtt=$(awk -F '/' '/rtt/ {print $5}' "$TMP_DIR/ping_$target.txt")
        if [ -z "$avg_rtt" ]; then
            avg_rtt=$(awk -F '=' '/Average/ {print $2}' "$TMP_DIR/ping_$target.txt" | cut -d' ' -f1)
        fi
        echo "$avg_rtt"
    else
        echo "timeout"
    fi
}

# 测量所有目标的RTT
declare -A rtt_results=()
for region in "${!test_targets[@]}"; do
    target=${test_targets[$region]}
    log_info "正在测量到$region ($target)的延迟..."
    rtt=$(measure_rtt "$target")
    
    if [ "$rtt" = "timeout" ]; then
        log_warn "到$region的连接超时，使用默认值"
        case $region in
            "local") rtt=50 ;;    # 本地默认50ms
            "north"|"south"|"east"|"west") rtt=80 ;;  # 国内其他地区默认80ms
            "foreign") rtt=200 ;; # 国外默认200ms
        esac
    fi
    
    rtt_results[$region]=$rtt
    log_info "到$region的平均延迟: ${rtt}ms"
done

# 计算平均RTT和确定主要通信区域
local_rtt=${rtt_results["local"]}
domestic_rtt_avg=$(echo "scale=2; (${rtt_results["north"]} + ${rtt_results["south"]} + ${rtt_results["east"]} + ${rtt_results["west"]}) / 4" | bc)
foreign_rtt=${rtt_results["foreign"]}

log_info "本地平均延迟: ${local_rtt}ms"
log_info "国内平均延迟: ${domestic_rtt_avg}ms"
log_info "国际平均延迟: ${foreign_rtt}ms"

# 确定主要通信区域和典型RTT
if (( $(echo "$foreign_rtt < $domestic_rtt_avg * 0.7" | bc -l) )); then
    primary_region="foreign"
    typical_rtt=$foreign_rtt
    log_info "主要通信区域: 国际"
else
    primary_region="domestic"
    typical_rtt=$domestic_rtt_avg
    log_info "主要通信区域: 国内"
fi

# 按RTT范围分类
if (( $(echo "$typical_rtt < 30" | bc -l) )); then
    rtt_category="low"    # 低延迟: <30ms
elif (( $(echo "$typical_rtt < 70" | bc -l) )); then
    rtt_category="medium" # 中等延迟: 30-70ms
else
    rtt_category="high"   # 高延迟: >70ms
fi
log_info "典型网络延迟: ${typical_rtt}ms (${rtt_category}延迟场景)"

# 3. 基础计算和场景判断
memory_bytes=$(printf "%.0f" $(echo "$memory_gb * 1024 * 1024 * 1024" | bc))
bandwidth_mb_per_sec=$(echo "scale=2; $bandwidth_mbps / 8" | bc)

# 硬件与带宽场景判断
is_low_memory=$(echo "$memory_gb <= 4" | bc -l)
is_single_core=$([ "$cpu_cores" -eq 1 ] && echo 1 || echo 0)
is_small_bandwidth=$([ "$bandwidth_mbps" -ge 500 ] && [ "$bandwidth_mbps" -lt 2000 ] && echo 1 || echo 0)
is_medium_bandwidth=$([ "$bandwidth_mbps" -ge 2000 ] && [ "$bandwidth_mbps" -lt 5000 ] && echo 1 || echo 0)
is_large_bandwidth=$([ "$bandwidth_mbps" -ge 5000 ] && [ "$bandwidth_mbps" -le 10000 ] && echo 1 || echo 0)

# 确定BBR版本和参数
if [ "$is_large_bandwidth" -eq 1 ]; then
    # 大带宽使用BBRv2或修改版BBR
    bbr_version="bbr2"
    log_info "检测到大带宽，将使用BBRv2优化配置"
elif [ "$is_medium_bandwidth" -eq 1 ]; then
    # 中带宽使用标准BBRv1优化版
    bbr_version="bbr_optimized"
    log_info "检测到中带宽，将使用优化版BBRv1配置"
else
    # 小带宽使用标准BBRv1
    bbr_version="bbr_standard"
    log_info "检测到小带宽，将使用标准BBRv1配置"
fi

# 4. TCP窗口核心参数计算（结合RTT和带宽）
# BDP = 带宽 (MB/s) * RTT (秒)
rtt_seconds=$(echo "scale=6; $typical_rtt / 1000" | bc)
bdp_mb=$(echo "scale=2; $bandwidth_mb_per_sec * $rtt_seconds" | bc)

log_info "带宽时延积(BDP)计算: ${bdp_mb}MB"

# 按带宽和RTT调整窗口内存占比
if [ "$is_low_memory" -eq 1 ]; then
    max_window_ratio=0.03  # 低内存统一3%
else
    if [ "$is_small_bandwidth" -eq 1 ]; then
        max_window_ratio=0.06
    elif [ "$is_medium_bandwidth" -eq 1 ]; then
        max_window_ratio=0.10
    else
        max_window_ratio=0.15
    fi
    
    # 高延迟场景增加窗口比例
    if [ "$rtt_category" = "high" ]; then
        max_window_ratio=$(echo "scale=2; $max_window_ratio * 1.5" | bc)
    fi
fi

# 按带宽和RTT调整BDP乘数
if [ "$is_small_bandwidth" -eq 1 ]; then
    bdp_multiplier=5
elif [ "$is_medium_bandwidth" -eq 1 ]; then
    bdp_multiplier=7
else
    bdp_multiplier=10
fi

# 高延迟场景需要更大的缓冲区
if [ "$rtt_category" = "high" ]; then
    bdp_multiplier=$(( bdp_multiplier * 2 ))
elif [ "$rtt_category" = "medium" ]; then
    bdp_multiplier=$(( bdp_multiplier * 1.5 ))
fi

bdp_limit=$(echo "$bdp_mb * $bdp_multiplier * 1024 * 1024" | bc | awk '{print int($1)}')
memory_limit=$(echo "$memory_bytes * $max_window_ratio" | bc | awk '{print int($1)}')

# 确定最大窗口
if [ "$bdp_limit" -lt "$memory_limit" ]; then
    max_window_bytes="$bdp_limit"
else
    max_window_bytes="$memory_limit"
fi

# 最小窗口（按带宽和RTT分级）
if [ "$is_small_bandwidth" -eq 1 ]; then
    min_window_base=0.6
elif [ "$is_medium_bandwidth" -eq 1 ]; then
    min_window_base=0.8
else
    min_window_base=1.0
fi

# 高延迟场景增加最小窗口
if [ "$rtt_category" = "high" ]; then
    min_window_base=$(echo "scale=1; $min_window_base * 1.5" | bc)
elif [ "$rtt_category" = "medium" ]; then
    min_window_base=$(echo "scale=1; $min_window_base * 1.2" | bc)
fi

min_window=$(echo "$bdp_mb * $min_window_base * 1024 * 1024" | bc | awk '{print int($1)}')
if [ "$min_window" -lt 524288 ]; then  # 最小512KB
    min_window=524288
fi

# 默认窗口（按带宽和RTT分级）
if [ "$is_small_bandwidth" -eq 1 ]; then
    default_window_base=2.0
elif [ "$is_medium_bandwidth" -eq 1 ]; then
    default_window_base=3.0
else
    default_window_base=4.0
fi

# 高延迟场景增加默认窗口
if [ "$rtt_category" = "high" ]; then
    default_window_base=$(echo "scale=1; $default_window_base * 1.8" | bc)
elif [ "$rtt_category" = "medium" ]; then
    default_window_base=$(echo "scale=1; $default_window_base * 1.3" | bc)
fi

default_window=$(echo "$bdp_mb * $default_window_base * 1024 * 1024" | bc | awk '{print int($1)}')
if [ "$default_window" -lt 2097152 ]; then  # 最小2MB
    default_window=2097152
fi

max_window="$max_window_bytes"
if [ "$max_window" -lt "$default_window" ]; then
    max_window="$default_window"
fi

# 5. BBR拥塞控制参数（按带宽、RTT、CPU和BBR版本调整）
# 基础BBR参数
if [ "$bbr_version" = "bbr2" ]; then
    # BBRv2参数（大带宽优化）
    bbr_high_gain=3000000000
    bbr_low_gain=1000000000
    bbr_rtt_scaling=1
    bbr_probe_rtt_mode=1
    bbr_cwnd_gain=2800000
    bbr_min_rtt_window=10000000  # 10ms
elif [ "$bbr_version" = "bbr_optimized" ]; then
    # 优化版BBRv1（中带宽）
    bbr_high_gain=3500000000
    bbr_low_gain=1000000000
    bbr_rtt_scaling=2
    bbr_probe_rtt_mode=1
    bbr_cwnd_gain=2500000
    bbr_min_rtt_window=20000000  # 20ms
else
    # 标准BBRv1（小带宽）
    bbr_high_gain=3000000000
    bbr_low_gain=1000000000
    bbr_rtt_scaling=2
    bbr_probe_rtt_mode=0
    bbr_cwnd_gain=2000000
    bbr_min_rtt_window=50000000  # 50ms
fi

# 根据CPU类型调整BBR参数
if [ "$cpu_type" = "intel" ]; then
    # Intel CPU通常单核性能更强，可使用更高增益
    bbr_high_gain=$(echo "$bbr_high_gain * 1.1" | bc | awk '{print int($1)}')
elif [ "$cpu_type" = "amd" ]; then
    # AMD CPU多核性能更好，调整RTT响应
    bbr_rtt_scaling=$(( bbr_rtt_scaling - 1 ))
    if [ "$bbr_rtt_scaling" -lt 1 ]; then
        bbr_rtt_scaling=1
    fi
fi

# 单核CPU特殊处理
if [ "$is_single_core" -eq 1 ]; then
    bbr_high_gain=$(echo "$bbr_high_gain * 0.8" | bc | awk '{print int($1)}')
    bbr_probe_rtt_mode=0
fi

# 根据RTT调整BBR参数
if [ "$rtt_category" = "high" ]; then
    bbr_high_gain=$(echo "$bbr_high_gain * 1.2" | bc | awk '{print int($1)}')
    bbr_min_rtt_window=$(echo "$bbr_min_rtt_window * 1.5" | bc | awk '{print int($1)}')
elif [ "$rtt_category" = "low" ]; then
    bbr_high_gain=$(echo "$bbr_high_gain * 0.9" | bc | awk '{print int($1)}')
fi

# 6. 单线程性能参数（按带宽分级）
if [ "$is_small_bandwidth" -eq 1 ]; then
    tcp_limit_output=4194304  # 4MB
elif [ "$is_medium_bandwidth" -eq 1 ]; then
    tcp_limit_output=8388608  # 8MB
else
    tcp_limit_output=16777216  # 16MB
fi

# 高延迟场景增加单次发送上限
if [ "$rtt_category" = "high" ]; then
    tcp_limit_output=$(echo "$tcp_limit_output * 2" | bc | awk '{print int($1)}')
elif [ "$rtt_category" = "medium" ]; then
    tcp_limit_output=$(echo "$tcp_limit_output * 1.5" | bc | awk '{print int($1)}')
fi

# 7. 网络设备队列参数（按带宽和RTT调整）
if [ "$is_small_bandwidth" -eq 1 ]; then
    netdev_max_backlog=30000
    dev_weight=128
    netdev_budget=600
elif [ "$is_medium_bandwidth" -eq 1 ]; then
    netdev_max_backlog=60000
    dev_weight=256
    netdev_budget=800
else
    netdev_max_backlog=100000
    dev_weight=512
    netdev_budget=1200
fi

# 高延迟场景增加队列长度
if [ "$rtt_category" = "high" ]; then
    netdev_max_backlog=$(echo "$netdev_max_backlog * 2" | bc | awk '{print int($1)}')
    netdev_budget=$(echo "$netdev_budget * 1.5" | bc | awk '{print int($1)}')
elif [ "$rtt_category" = "medium" ]; then
    netdev_max_backlog=$(echo "$netdev_max_backlog * 1.5" | bc | awk '{print int($1)}')
fi

# 忙轮询参数（高延迟更激进）
busy_poll=50
if [ "$is_medium_bandwidth" -eq 1 ]; then
    busy_poll=100
elif [ "$is_large_bandwidth" -eq 1 ]; then
    busy_poll=200
fi

# 根据RTT调整忙轮询
if [ "$rtt_category" = "high" ]; then
    busy_poll=$(( busy_poll + 100 ))
elif [ "$rtt_category" = "medium" ]; then
    busy_poll=$(( busy_poll + 50 ))
fi

# 根据CPU类型调整忙轮询
if [ "$cpu_type" = "intel" ] && [ "$cpu_cores" -ge 4 ]; then
    busy_poll=$(( busy_poll + 50 ))
elif [ "$cpu_type" = "amd" ] && [ "$cpu_cores" -ge 8 ]; then
    busy_poll=$(( busy_poll + 30 ))
fi

if [ "$is_single_core" -eq 1 ]; then
    busy_poll=0  # 单核禁用忙轮询
fi

# 8. CPU特定优化参数
cpu_specific_params=""

if [ "$cpu_type" = "intel" ]; then
    # Intel CPU优化
    cpu_specific_params=$(cat << EOF
# Intel CPU优化参数
kernel.sched_mc_power_savings = 0                  # 禁用多核省电模式
kernel.sched_smt_power_savings = 0                 # 禁用超线程省电模式
$(if [ -f /sys/devices/system/cpu/intel_pstate/status ]; then
    echo "intel_pstate=active                       # 使用Intel P-State驱动"
    echo "intel_pstate.min_perf_pct=50              # 最小性能百分比"
    echo "intel_pstate.max_perf_pct=100             # 最大性能百分比"
    echo "intel_pstate.no_turbo=0                   # 启用Turbo Boost"
fi)
EOF
    )
elif [ "$cpu_type" = "amd" ]; then
    # AMD CPU优化
    cpu_specific_params=$(cat << EOF
# AMD CPU优化参数
kernel.sched_cfs_bandwidth_slice_us = 5000         # 调整调度带宽切片
kernel.sched_nr_migrate = 32                       # 增加迁移任务数
$(if [ -f /sys/devices/system/cpu/amd_pstate/status ]; then
    echo "amd_pstate=active                         # 使用AMD P-State驱动"
    echo "amd_pstate.shared_mem=1                   # 启用共享内存接口"
fi)
$(if [ "$cpu_cores" -ge 16 ]; then
    echo "kernel.numa_balancing=1                   # 启用NUMA平衡"
    echo "kernel.numa_balancing_scan_delay=1000     # NUMA扫描延迟"
fi)
EOF
    )
else
    # 通用CPU优化
    cpu_specific_params=$(cat << EOF
# 通用CPU优化参数
kernel.sched_mc_power_savings = 1                  # 启用基本多核省电
EOF
    )
fi

# 9. 连接管理参数（按带宽和RTT调整）
if [ "$is_small_bandwidth" -eq 1 ]; then
    somaxconn=32768
    tcp_max_tw_buckets=500000
elif [ "$is_medium_bandwidth" -eq 1 ]; then
    somaxconn=65536
    tcp_max_tw_buckets=800000
else
    somaxconn=100000
    tcp_max_tw_buckets=1500000
fi

# 高延迟场景需要更多连接资源
if [ "$rtt_category" = "high" ]; then
    somaxconn=$(echo "$somaxconn * 1.5" | bc | awk '{print int($1)}')
    tcp_max_tw_buckets=$(echo "$tcp_max_tw_buckets * 1.5" | bc | awk '{print int($1)}')
fi

tcp_max_syn_backlog=$(( somaxconn / 2 ))

# 10. 系统限制参数（高延迟场景更高限制）
if [ "$is_small_bandwidth" -eq 1 ]; then
    fs_file_max=1048576
    fs_nr_open=2097152
elif [ "$is_medium_bandwidth" -eq 1 ]; then
    fs_file_max=2097152
    fs_nr_open=4194304
else
    fs_file_max=4194304
    fs_nr_open=8388608
fi

# 高延迟场景增加文件描述符限制
if [ "$rtt_category" = "high" ]; then
    fs_file_max=$(echo "$fs_file_max * 1.5" | bc | awk '{print int($1)}')
    fs_nr_open=$(echo "$fs_nr_open * 1.5" | bc | awk '{print int($1)}')
fi

# 11. 处理器调度参数（按CPU类型、带宽和RTT调整）
if [ "$cpu_type" = "intel" ]; then
    # Intel CPU调度优化
    sched_latency=5000000
    sched_wakeup_granularity=500000
elif [ "$cpu_type" = "amd" ]; then
    # AMD CPU调度优化（更多核心优化）
    sched_latency=6000000
    sched_wakeup_granularity=750000
else
    # 通用调度参数
    sched_latency=5500000
    sched_wakeup_granularity=600000
fi

# 根据带宽调整
if [ "$is_large_bandwidth" -eq 1 ]; then
    sched_latency=$(echo "$sched_latency * 0.7" | bc | awk '{print int($1)}')
fi

# 根据RTT调整调度延迟
if [ "$rtt_category" = "high" ]; then
    sched_latency=$(echo "$sched_latency * 0.7" | bc | awk '{print int($1)}')
elif [ "$rtt_category" = "low" ]; then
    sched_latency=$(echo "$sched_latency * 1.2" | bc | awk '{print int($1)}')
fi

if [ "$cpu_cores" -ge 4 ]; then
    sched_latency=3000000
fi

# 12. 其他参数计算
single_stream_allowance=0
min_free_kbytes=0
dirty_ratio=0
dirty_background_ratio=0
tcp_fin_timeout=0
tcp_keepalive_time=0
tcp_keepalive_intvl=0
rx_tx_offload=0
tcp_lro=0

# 单流带宽允许值（按带宽和RTT调整）
if [ "$is_small_bandwidth" -eq 1 ]; then
    stream_ratio=0.05
elif [ "$is_medium_bandwidth" -eq 1 ]; then
    stream_ratio=0.08
else
    stream_ratio=0.12
fi

# 高延迟场景增加流比率
if [ "$rtt_category" = "high" ]; then
    stream_ratio=$(echo "scale=2; $stream_ratio * 1.4" | bc)
elif [ "$rtt_category" = "medium" ]; then
    stream_ratio=$(echo "scale=2; $stream_ratio * 1.2" | bc)
fi

single_stream_1=$(echo "$max_window * 3" | bc | awk '{print int($1)}')
single_stream_2=$(echo "$memory_bytes * $stream_ratio" | bc | awk '{print int($1)}')
single_stream_allowance=$(echo "if ($single_stream_1 < $single_stream_2) $single_stream_1 else $single_stream_2" | bc | awk '{print int($1)}')

# 最小空闲内存（高延迟场景保留更多）
if [ "$is_small_bandwidth" -eq 1 ]; then
    min_free_kbytes=131072  # 128MB
elif [ "$is_medium_bandwidth" -eq 1 ]; then
    min_free_kbytes=262144  # 256MB
else
    min_free_kbytes=524288  # 512MB
fi

# 高延迟场景保留更多内存
if [ "$rtt_category" = "high" ]; then
    min_free_kbytes=$(echo "$min_free_kbytes * 1.5" | bc | awk '{print int($1)}')
fi

if (( $(echo "$memory_gb >= 16" | bc -l) )); then
    min_free_kbytes=1048576  # 1GB（大内存）
fi

# 内存管理参数（高延迟场景允许更多脏页）
dirty_ratio=15
dirty_background_ratio=5
if [ "$is_medium_bandwidth" -eq 1 ]; then
    dirty_ratio=20
    dirty_background_ratio=8
elif [ "$is_large_bandwidth" -eq 1 ]; then
    dirty_ratio=30
    dirty_background_ratio=15
fi

# 高延迟场景允许更多缓存
if [ "$rtt_category" = "high" ]; then
    dirty_ratio=$(echo "$dirty_ratio * 1.3" | bc | awk '{print int($1)}')
    dirty_background_ratio=$(echo "$dirty_background_ratio * 1.3" | bc | awk '{print int($1)}')
fi

# 超时参数（高延迟场景需要更长超时）
tcp_fin_timeout=4
if [ "$is_large_bandwidth" -eq 1 ]; then
    tcp_fin_timeout=2
fi
if [ "$cpu_cores" -ge 4 ]; then
    tcp_fin_timeout=2
fi

# 高延迟场景增加超时时间
if [ "$rtt_category" = "high" ]; then
    tcp_fin_timeout=$(( tcp_fin_timeout + 2 ))
fi

# 超时与保活参数（高延迟场景更频繁保活）
tcp_keepalive_time=120
tcp_keepalive_intvl=15
if [ "$is_medium_bandwidth" -eq 1 ]; then
    tcp_keepalive_time=90
    tcp_keepalive_intvl=12
elif [ "$is_large_bandwidth" -eq 1 ]; then
    tcp_keepalive_time=60
    tcp_keepalive_intvl=10
fi

# 高延迟场景更频繁保活
if [ "$rtt_category" = "high" ]; then
    tcp_keepalive_time=$(echo "$tcp_keepalive_time * 0.7" | bc | awk '{print int($1)}')
    tcp_keepalive_intvl=$(echo "$tcp_keepalive_intvl * 0.7" | bc | awk '{print int($1)}')
fi

# 网络接口硬件加速（高带宽和高延迟全面启用）
tcp_lro=0
if [ "$is_low_memory" -eq 0 ] && [ "$is_single_core" -eq 0 ]; then
    tcp_lro=1  # 多核启用LRO
fi
if [ "$is_large_bandwidth" -eq 1 ] || [ "$rtt_category" = "high" ]; then
    tcp_lro=1  # 大带宽或高延迟强制启用LRO
    rx_tx_offload=1
else
    rx_tx_offload=0
fi

# 计算用于注释的MB值
min_window_mb=$(echo "scale=2; $min_window / 1024 / 1024" | bc || echo "0.00")
default_window_mb=$(echo "scale=2; $default_window / 1024 / 1024" | bc || echo "0.00")
max_window_mb=$(echo "scale=2; $max_window / 1024 / 1024" | bc || echo "0.00")
max_window_ratio_pct=$(echo "scale=0; $max_window_ratio * 100" | bc || echo "0")
tcp_limit_output_mb=$(echo "scale=2; $tcp_limit_output / 1024 / 1024" | bc || echo "0.00")
single_stream_allowance_mb=$(echo "scale=2; $single_stream_allowance / 1024 / 1024" | bc || echo "0.00")
min_free_kbytes_mb=$(echo "scale=0; $min_free_kbytes / 1024" | bc || echo "0")
sched_latency_ms=$(echo "scale=0; $sched_latency / 1000000" | bc || echo "0")
bbr_min_rtt_window_ms=$(echo "scale=0; $bbr_min_rtt_window / 1000000" | bc || echo "0")

# 生成配置内容
config=$(cat << EOF
# 网络优化配置 - 自动生成
# 带宽: ${bandwidth_mbps}Mbps ($(if [ "$is_small_bandwidth" -eq 1 ]; then echo "小带宽"; elif [ "$is_medium_bandwidth" -eq 1 ]; then echo "中带宽"; else echo "大带宽"; fi))
# CPU: ${cpu_cores}核 ($(echo $cpu_type | tr '[:lower:]' '[:upper:]') - $cpu_model)
# 内存: ${memory_gb}G | BBR版本: $(echo $bbr_version | tr '[:lower:]' '[:upper:]')
# 典型网络延迟: ${typical_rtt}ms ($(if [ "$rtt_category" = "low" ]; then echo "低延迟"; elif [ "$rtt_category" = "medium" ]; then echo "中等延迟"; else echo "高延迟"; fi))
# 主要通信区域: $(if [ "$primary_region" = "domestic" ]; then echo "国内"; else echo "国际"; fi)

# BDP计算（带宽时延积）:
# ${bandwidth_mbps}Mbps = ${bandwidth_mb_per_sec}MB/s | 延迟: ${typical_rtt}ms = ${rtt_seconds}秒
# BDP = ${bdp_mb}MB | BDP乘数: ${bdp_multiplier} | 内存窗口占比: ${max_window_ratio_pct}%

# 1. TCP窗口核心优化（根据BDP和RTT优化）
net.ipv4.tcp_rmem = ${min_window} ${default_window} ${max_window}  # 接收窗口：${min_window_mb}MB - ${default_window_mb}MB - ${max_window_mb}MB
net.ipv4.tcp_wmem = ${min_window} ${default_window} ${max_window}  # 发送窗口：${min_window_mb}MB - ${default_window_mb}MB - ${max_window_mb}MB
net.core.rmem_default = ${default_window}               # 默认接收缓冲区${default_window_mb}MB
net.core.wmem_default = ${default_window}               # 默认发送缓冲区${default_window_mb}MB
net.core.rmem_max = ${max_window}                       # 最大接收缓冲区${max_window_mb}MB
net.core.wmem_max = ${max_window}                       # 最大发送缓冲区${max_window_mb}MB
net.ipv4.tcp_window_scaling = 1                        # 启用窗口缩放（必须开启）
net.ipv4.tcp_moderate_rcvbuf = $(if [ "$is_large_bandwidth" -eq 1 ] || [ "$rtt_category" = "high" ]; then echo 0; else echo 1; fi)  # $(if [ "$is_large_bandwidth" -eq 1 ] || [ "$rtt_category" = "high" ]; then echo "禁用自动调整（固定大缓冲区）"; else echo "启用智能调整"; fi)

# 2. BBR拥塞控制优化（根据带宽、延迟和CPU类型调整）
net.ipv4.tcp_congestion_control = $(if [ "$bbr_version" = "bbr2" ]; then echo "bbr2"; else echo "bbr"; fi)
net.ipv4.tcp_bbr_high_gain = ${bbr_high_gain}           # 高增益系数
net.ipv4.tcp_bbr_low_gain = ${bbr_low_gain}             # 低增益系数
net.ipv4.tcp_bbr_rtt_scaling = ${bbr_rtt_scaling}        # RTT缩放系数
net.ipv4.tcp_bbr_probe_rtt_mode = ${bbr_probe_rtt_mode}  # $(if [ "$bbr_probe_rtt_mode" -eq 1 ]; then echo "启用主动RTT探测"; else echo "禁用主动RTT探测"; fi)
net.ipv4.tcp_bbr_cwnd_gain = ${bbr_cwnd_gain}           # 拥塞窗口增益
net.ipv4.tcp_bbr_min_rtt_window = ${bbr_min_rtt_window}  # 最小RTT窗口（${bbr_min_rtt_window_ms}ms）
net.ipv4.tcp_slow_start_after_idle = 0                  # 空闲不重置慢启动
net.ipv4.tcp_no_metrics_save = 0                         # 保存连接状态（提高复用率）

# 3. 单线程性能优化
net.ipv4.tcp_limit_output_bytes = ${tcp_limit_output}    # 单次发送上限${tcp_limit_output_mb}MB（适配${rtt_category}延迟）
net.ipv4.tcp_single_stream_allowance = ${single_stream_allowance}  # 单流允许带宽${single_stream_allowance_mb}MB
net.ipv4.tcp_push_pending_frames = $(if [ "$is_large_bandwidth" -eq 1 ] || [ "$rtt_category" = "high" ]; then echo 0; else echo 1; fi)  # $(if [ "$is_large_bandwidth" -eq 1 ] || [ "$rtt_category" = "high" ]; then echo "批量发送（提高吞吐量）"; else echo "立即发送（降低延迟）"; fi)
net.ipv4.tcp_nodelay = $(if [ "$rtt_category" = "high" ]; then echo 0; else echo 1; fi)  # $(if [ "$rtt_category" = "high" ]; then echo "启用Nagle（提高吞吐量）"; else echo "禁用Nagle（降低延迟）"; fi)
$(if [ "$cpu_cores" -ge 4 ]; then echo "net.ipv4.tcp_tw_recycle = 1  # 启用TIME_WAIT快速回收"; fi)

# 4. 网络设备队列优化（根据延迟和带宽调整）
net.core.netdev_max_backlog = ${netdev_max_backlog}      # 接收队列${netdev_max_backlog}（${rtt_category}延迟适配）
net.core.dev_weight = ${dev_weight}                      # 设备处理权重
net.core.busy_poll = ${busy_poll}                        # 忙轮询值（${busy_poll}ns）
net.core.busy_read = ${busy_poll}                        # 忙读值（与忙轮询一致）
net.core.netdev_budget = ${netdev_budget}                # 单次中断处理包数（${netdev_budget}）

# 5. 连接管理优化
net.core.somaxconn = ${somaxconn}                       # 最大连接队列${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${tcp_max_syn_backlog}    # SYN队列${tcp_max_syn_backlog}
net.ipv4.tcp_max_tw_buckets = ${tcp_max_tw_buckets}      # TIME_WAIT桶数量
net.ipv4.tcp_fin_timeout = ${tcp_fin_timeout}            # FIN等待时间${tcp_fin_timeout}秒
net.ipv4.tcp_tw_reuse = 1                               # 重用TIME_WAIT连接
net.ipv4.tcp_orphan_retries = 1                          # 减少孤儿连接重试

# 6. 超时与保活优化
net.ipv4.tcp_keepalive_time = ${tcp_keepalive_time}      # 保活探测时间${tcp_keepalive_time}秒
net.ipv4.tcp_keepalive_intvl = ${tcp_keepalive_intvl}    # 保活间隔${tcp_keepalive_intvl}秒
net.ipv4.ip_local_port_range = 1024 65535                # 全端口范围（提高并发）

# 7. 内存管理优化
vm.swappiness = 0                                        # 禁用交换（提高性能）
vm.min_free_kbytes = ${min_free_kbytes}                  # 保留${min_free_kbytes_mb}MB空闲内存
vm.dirty_ratio = ${dirty_ratio}                          # 脏页比率${dirty_ratio}%
vm.dirty_background_ratio = ${dirty_background_ratio}    # 后台脏页比率${dirty_background_ratio}%
vm.dirty_writeback_centisecs = 1000                      # 1秒写回脏页（平衡缓存与IO）
vm.page-cluster = 2                                       # 适度页面聚类

# 8. 系统限制优化
fs.file-max = ${fs_file_max}                             # 系统最大文件描述符
fs.nr_open = ${fs_nr_open}                               # 进程最大文件描述符
net.ipv4.ip_unprivileged_port_start = 0                  # 允许所有端口使用

# 9. 处理器调度优化
kernel.sched_migration_cost_ns = 100000                 # 快速进程迁移（多核负载均衡）
kernel.sched_autogroup_enabled = 0                       # 禁用自动分组（精细化调度）
kernel.sched_latency_ns = ${sched_latency}               # 调度延迟${sched_latency_ms}ms
kernel.sched_wakeup_granularity_ns = ${sched_wakeup_granularity}  # 唤醒粒度$(echo "scale=1; $sched_wakeup_granularity / 1000000" | bc)ms

# 10. 网络接口硬件加速
net.ipv4.tcp_tso = 1                                    # 启用TCP分段卸载
net.ipv4.tcp_gro = 1                                    # 启用通用接收卸载
net.ipv4.tcp_lro = ${tcp_lro}                            # 启用大型接收卸载
$(if [ "$rx_tx_offload" -eq 1 ]; then echo "net.ipv4.tcp_rx_vlan_offload = 1\nnet.ipv4.tcp_tx_vlan_offload = 1  # 启用VLAN卸载"; fi)
net.core.default_qdisc = fq_codel                        # 启用先进队列管理

# 11. CPU特定优化
$cpu_specific_params
EOF
)

# 保存到文件
output_file="/etc/sysctl.d/99-simplified-network-optimize.conf"
if echo "$config" > "$output_file"; then
    log_success "配置已成功生成并保存到 $output_file"
    log_success "带宽场景: $(if [ "$is_small_bandwidth" -eq 1 ]; then echo "小带宽(500-2000Mbps)"; elif [ "$is_medium_bandwidth" -eq 1 ]; then echo "中带宽(2000-5000Mbps)"; else echo "大带宽(5000-10000Mbps)"; fi)"
    log_success "延迟场景: $(if [ "$rtt_category" = "low" ]; then echo "低延迟(<30ms)"; elif [ "$rtt_category" = "medium" ]; then echo "中等延迟(30-70ms)"; else echo "高延迟(>70ms)"; fi)"
    log_success "BBR版本: $(echo $bbr_version | tr '[:lower:]' '[:upper:]') | CPU优化: $(echo $cpu_type | tr '[:lower:]' '[:upper:]')"
    log_info "请执行以下命令使配置生效:"
    echo "sudo sysctl --system"
else
    log_error "权限错误: 无法写入文件 $output_file"
    log_info "请使用sudo运行脚本，例如:"
    echo "sudo $0 $1 $2 $3"
    exit 1
fi