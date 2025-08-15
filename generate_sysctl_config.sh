#!/bin/bash

# 检查参数数量
if [ $# -ne 3 ]; then
    echo "用法: $0 <带宽(Mbps)> <CPU核心数> <内存(GB)>"
    echo "示例: $0 1000 1 0.5"
    exit 1
fi

# 解析参数
bandwidth_mbps=$1
cpu_cores=$2
memory_gb=$3

# 参数验证
if ! [[ "$bandwidth_mbps" =~ ^[0-9]+$ ]] || ! [[ "$cpu_cores" =~ ^[0-9]+$ ]] || ! [[ "$memory_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "参数错误: 带宽和CPU核心数必须为整数，内存可以是小数"
    exit 1
fi

if [ "$bandwidth_mbps" -le 0 ] || [ "$cpu_cores" -le 0 ] || (( $(echo "$memory_gb <= 0" | bc -l) )); then
    echo "参数错误: 所有参数必须为正数"
    exit 1
fi

# 基础计算
memory_bytes=$(echo "$memory_gb * 1024 * 1024 * 1024" | bc)
bandwidth_mb_per_sec=$(echo "scale=2; $bandwidth_mbps / 8" | bc)

# 硬件配置判断
is_low_memory=$(echo "$memory_gb <= 1" | bc -l)
is_single_core=$([ "$cpu_cores" -eq 1 ] && echo 1 || echo 0)
is_high_bandwidth=$([ "$bandwidth_mbps" -ge 2000 ] && echo 1 || echo 0)

# 1. TCP窗口核心参数计算
bdp_mb=$(echo "scale=2; $bandwidth_mb_per_sec * 0.02" | bc)

if [ "$is_low_memory" -eq 1 ]; then
    max_window_ratio=0.01
else
    max_window_ratio=0.05
fi

bdp_limit=$(echo "$bdp_mb * 4 * 1024 * 1024" | bc | awk '{print int($1)}')
memory_limit=$(echo "$memory_bytes * $max_window_ratio" | bc | awk '{print int($1)}')
max_window_bytes=$(( bdp_limit < memory_limit ? bdp_limit : memory_limit ))

min_window=$(echo "$bdp_mb * 0.5 * 1024 * 1024" | bc | awk '{print int($1)}')
if [ $min_window -lt 262144 ]; then
    min_window=262144
fi

default_window=$(echo "$bdp_mb * 1.5 * 1024 * 1024" | bc | awk '{print int($1)}')
if [ $default_window -lt 1048576 ]; then
    default_window=1048576
fi

max_window=$max_window_bytes

# 2. BBR拥塞控制参数
if [ "$is_single_core" -eq 1 ]; then
    bbr_high_gain=2500000000
    bbr_rtt_scaling=4
else
    bbr_high_gain=3000000000
    bbr_rtt_scaling=2
fi

if [ "$is_high_bandwidth" -eq 1 ] && [ "$is_single_core" -eq 0 ]; then
    bbr_high_gain=3200000000
fi

# 3. 单线程性能参数
tcp_limit_output=1048576  # 1MB
if [ "$cpu_cores" -ge 2 ]; then
    tcp_limit_output=2097152  # 2MB
fi
if [ "$cpu_cores" -ge 4 ] && [ "$bandwidth_mbps" -ge 2000 ]; then
    tcp_limit_output=8388608  # 8MB
fi

single_stream_1=$(echo "$max_window * 2" | bc)
single_stream_2=$(echo "$memory_bytes * 0.03" | bc)
single_stream_allowance=$(echo "if ($single_stream_1 < $single_stream_2) $single_stream_1 else $single_stream_2" | bc | awk '{print int($1)}')

# 4. 网络设备队列参数
netdev_max_backlog=10000
if [ "$is_single_core" -eq 0 ]; then
    netdev_max_backlog=30000
fi
if [ "$cpu_cores" -ge 4 ] && [ "$is_high_bandwidth" -eq 1 ]; then
    netdev_max_backlog=50000
fi

dev_weight=64
if [ "$is_single_core" -eq 0 ]; then
    dev_weight=128
fi
if [ "$cpu_cores" -ge 4 ]; then
    dev_weight=256
fi

busy_poll=0
if [ "$is_single_core" -eq 0 ]; then
    busy_poll=50
fi
if [ "$cpu_cores" -ge 4 ]; then
    busy_poll=100
fi

# 5. 连接管理参数
somaxconn=8192
if [ "$is_low_memory" -eq 0 ]; then
    somaxconn=32768
fi
if [ "$cpu_cores" -ge 4 ] && (( $(echo "$memory_gb >= 8" | bc -l) )); then
    somaxconn=100000
fi

tcp_max_syn_backlog=$(( somaxconn / 2 ))

tcp_max_tw_buckets=100000
if [ "$is_low_memory" -eq 0 ]; then
    tcp_max_tw_buckets=500000
fi
if (( $(echo "$memory_gb >= 8" | bc -l) )); then
    tcp_max_tw_buckets=1000000
fi

tcp_fin_timeout=5
if [ "$is_single_core" -eq 0 ]; then
    tcp_fin_timeout=4
fi
if [ "$cpu_cores" -ge 4 ]; then
    tcp_fin_timeout=2
fi

# 6. 超时与保活参数
tcp_keepalive_time=120
if [ "$is_single_core" -eq 0 ]; then
    tcp_keepalive_time=90
fi
if [ "$cpu_cores" -ge 4 ]; then
    tcp_keepalive_time=60
fi

tcp_keepalive_intvl=15
if [ "$is_single_core" -eq 0 ]; then
    tcp_keepalive_intvl=12
fi
if [ "$cpu_cores" -ge 4 ]; then
    tcp_keepalive_intvl=10
fi

ip_local_port_start=49152
if [ "$is_low_memory" -eq 0 ]; then
    ip_local_port_start=32768
fi
if [ "$cpu_cores" -ge 4 ] && (( $(echo "$memory_gb >= 8" | bc -l) )); then
    ip_local_port_start=1024
fi

# 7. 内存管理参数
swappiness=20
if [ "$is_low_memory" -eq 0 ]; then
    swappiness=10
fi
if (( $(echo "$memory_gb >= 8" | bc -l) )); then
    swappiness=0
fi

min_free_kbytes=65536  # 64MB
if (( $(echo "$memory_gb >= 2" | bc -l) )); then
    min_free_kbytes=98304  # 96MB
fi
if (( $(echo "$memory_gb >= 8" | bc -l) )); then
    min_free_kbytes=262144  # 256MB
fi

dirty_ratio=10
if [ "$is_low_memory" -eq 0 ]; then
    dirty_ratio=15
fi
if (( $(echo "$memory_gb >= 8" | bc -l) )); then
    dirty_ratio=30
fi

dirty_background_ratio=3
if [ "$is_low_memory" -eq 0 ]; then
    dirty_background_ratio=5
fi
if (( $(echo "$memory_gb >= 8" | bc -l) )); then
    dirty_background_ratio=15
fi

dirty_writeback_centisecs=500
if [ "$is_single_core" -eq 0 ]; then
    dirty_writeback_centisecs=300
fi
if [ "$cpu_cores" -ge 4 ]; then
    dirty_writeback_centisecs=100
fi

page_cluster=4
if [ "$is_low_memory" -eq 0 ]; then
    page_cluster=3
fi
if [ "$cpu_cores" -ge 4 ]; then
    page_cluster=2
fi

overcommit_memory=0
if [ "$is_low_memory" -eq 1 ]; then
    overcommit_memory=1
fi

# 8. 系统限制参数
fs_file_max=131072
if [ "$is_low_memory" -eq 0 ]; then
    fs_file_max=524288
fi
if (( $(echo "$memory_gb >= 8" | bc -l) )); then
    fs_file_max=2097152
fi

fs_nr_open=262144
if [ "$is_low_memory" -eq 0 ]; then
    fs_nr_open=1048576
fi
if (( $(echo "$memory_gb >= 8" | bc -l) )); then
    fs_nr_open=4194304
fi

ip_unprivileged_port_start=1024
if [ "$is_low_memory" -eq 0 ] && [ "$is_single_core" -eq 0 ]; then
    ip_unprivileged_port_start=0
fi

# 9. 处理器调度参数
sched_migration_cost=1000000
if [ "$is_single_core" -eq 0 ]; then
    sched_migration_cost=500000
fi
if [ "$cpu_cores" -ge 4 ]; then
    sched_migration_cost=50000
fi

sched_autogroup_enabled=1
if [ "$is_single_core" -eq 0 ]; then
    sched_autogroup_enabled=0
fi
if [ "$cpu_cores" -ge 4 ]; then
    sched_autogroup_enabled=0
fi

sched_latency=6000000
if [ "$is_single_core" -eq 0 ]; then
    sched_latency=5000000
fi
if [ "$cpu_cores" -ge 4 ]; then
    sched_latency=3000000
fi

# 10. 网络接口硬件加速
tcp_lro=0
if [ "$is_low_memory" -eq 0 ] && [ "$is_single_core" -eq 0 ]; then
    tcp_lro=1
fi

# 计算用于注释的MB值
min_window_mb=$(echo "scale=2; $min_window / 1024 / 1024" | bc)
default_window_mb=$(echo "scale=2; $default_window / 1024 / 1024" | bc)
max_window_mb=$(echo "scale=2; $max_window / 1024 / 1024" | bc)
max_window_ratio_pct=$(echo "scale=0; $max_window_ratio * 100" | bc)
tcp_limit_output_mb=$(echo "scale=2; $tcp_limit_output / 1024 / 1024" | bc)
single_stream_allowance_mb=$(echo "scale=2; $single_stream_allowance / 1024 / 1024" | bc)
min_free_kbytes_mb=$(echo "scale=0; $min_free_kbytes / 1024" | bc)
sched_latency_ms=$(echo "scale=0; $sched_latency / 1000000" | bc)

# 生成配置内容
config=$(cat << EOF
# ${bandwidth_mbps}Mbps带宽${cpu_cores}核${memory_gb}G内存优化配置
# 自动生成的系统参数配置，针对当前硬件环境优化

# BDP计算（针对当前硬件）：
# ${bandwidth_mbps}Mbps = ${bandwidth_mb_per_sec}MB/s（理论速度）
# 假设RTT=20ms，所需窗口=${bdp_mb}MB
# 内存限制下，窗口上限控制在${max_window_mb}MB（总内存${max_window_ratio_pct}%）

# 1. TCP窗口核心优化
net.ipv4.tcp_rmem = ${min_window} ${default_window} ${max_window}  # 接收窗口：${min_window_mb}MB - ${default_window_mb}MB - ${max_window_mb}MB
net.ipv4.tcp_wmem = ${min_window} ${default_window} ${max_window}  # 发送窗口：${min_window_mb}MB - ${default_window_mb}MB - ${max_window_mb}MB
net.core.rmem_default = ${default_window}               # 默认接收缓冲区${default_window_mb}MB
net.core.wmem_default = ${default_window}               # 默认发送缓冲区${default_window_mb}MB
net.core.rmem_max = ${max_window}                       # 最大接收缓冲区${max_window_mb}MB
net.core.wmem_max = ${max_window}                       # 最大发送缓冲区${max_window_mb}MB
net.ipv4.tcp_window_scaling = 1                        # 启用窗口缩放（必须开启）
net.ipv4.tcp_moderate_rcvbuf = 1                       # $(if [ "$is_low_memory" -eq 1 ]; then echo "强制自动调整（防止内存耗尽）"; else echo "启用智能调整（负载均衡）"; fi)

# 2. BBR拥塞控制优化
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_bbr_high_gain = ${bbr_high_gain}           # $(if [ "$is_single_core" -eq 1 ]; then echo "低增益（最小化单核计算量）"; else echo "提高BBR增益（多核可承载更高计算量）"; fi)
net.ipv4.tcp_bbr_rtt_scaling = ${bbr_rtt_scaling}        # $(if [ "$is_single_core" -eq 1 ]; then echo "高RTT敏感度（减少调整频率）"; else echo "优化RTT响应（平衡速度与稳定性）"; fi)
net.ipv4.tcp_slow_start_after_idle = 0                  # 空闲不重置慢启动（核心）
net.ipv4.tcp_no_metrics_save = $(if [ "$is_single_core" -eq 1 ]; then echo 1; else echo 0; fi)  # $(if [ "$is_single_core" -eq 1 ]; then echo "不保存连接状态（省内存）"; else echo "保存连接状态（多核可承担开销）"; fi)

# 3. 单线程性能优化
net.ipv4.tcp_limit_output_bytes = ${tcp_limit_output}    # 单次发送上限${tcp_limit_output_mb}MB（${cpu_cores}核处理能力）
net.ipv4.tcp_single_stream_allowance = ${single_stream_allowance}  # 单流允许带宽${single_stream_allowance_mb}MB
net.ipv4.tcp_push_pending_frames = 1                    # 立即发送pending帧
net.ipv4.tcp_nodelay = 1                                # 禁用Nagle算法（减少延迟）
$(if [ "$cpu_cores" -ge 4 ]; then echo "net.ipv4.tcp_tw_recycle = 1  # 启用TIME_WAIT快速回收（多核优势）"; fi)

# 4. 网络设备队列优化
net.core.netdev_max_backlog = ${netdev_max_backlog}      # 接收队列${netdev_max_backlog}（${cpu_cores}核可处理上限）
net.core.dev_weight = ${dev_weight}                      # 设备处理权重（适配${cpu_cores}核负载）
net.core.busy_poll = ${busy_poll}                        # $(if [ "$busy_poll" -eq 0 ]; then echo "禁用忙轮询（省CPU）"; else echo "启用忙轮询（减少延迟）"; fi)
net.core.busy_read = ${busy_poll}                        # $(if [ "$busy_poll" -eq 0 ]; then echo "禁用忙读（避免空转）"; else echo "启用忙读（提升响应速度）"; fi)
$(if [ "$cpu_cores" -ge 4 ]; then echo "net.core.netdev_budget = 600  # 提高单次中断处理包数"; else echo "net.core.netdev_budget = 300  # 降低单次中断处理量"; fi)

# 5. 连接管理优化
net.core.somaxconn = ${somaxconn}                       # 最大连接队列${somaxconn}（${memory_gb}G内存安全值）
net.ipv4.tcp_max_syn_backlog = ${tcp_max_syn_backlog}    # SYN队列${tcp_max_syn_backlog}（${cpu_cores}核可控范围）
net.ipv4.tcp_max_tw_buckets = ${tcp_max_tw_buckets}      # TIME_WAIT桶${tcp_max_tw_buckets}（控制内存占用）
net.ipv4.tcp_fin_timeout = ${tcp_fin_timeout}            # $(if [ "$tcp_fin_timeout" -eq 5 ]; then echo "延长FIN等待至5秒（减少重建）"; else echo "FIN等待时间${tcp_fin_timeout}秒"; fi)
net.ipv4.tcp_tw_reuse = 1                               # 重用TIME_WAIT连接
net.ipv4.tcp_orphan_retries = $(if [ "$is_single_core" -eq 1 ]; then echo 2; else echo 1; fi)  # $(if [ "$is_single_core" -eq 1 ]; then echo "适度重试（平衡稳定性）"; else echo "减少重试（多核效率优先）"; fi)

# 6. 超时与保活优化
net.ipv4.tcp_keepalive_time = ${tcp_keepalive_time}      # 保活探测时间${tcp_keepalive_time}秒
net.ipv4.tcp_keepalive_intvl = ${tcp_keepalive_intvl}    # 保活间隔${tcp_keepalive_intvl}秒
net.ipv4.ip_local_port_range = ${ip_local_port_start} 65535  # $(if [ "$ip_local_port_start" -gt 32768 ]; then echo "大幅缩小端口范围（省内存）"; else echo "端口范围（平衡并发与内存）"; fi)

# 7. 内存管理优化
vm.swappiness = ${swappiness}                            # $(if [ "$swappiness" -gt 0 ]; then echo "启用交换（小内存必备）"; else echo "禁用交换（内存充足）"; fi)
vm.min_free_kbytes = ${min_free_kbytes}                  # 保留${min_free_kbytes_mb}MB空闲内存（安全阈值）
vm.dirty_ratio = ${dirty_ratio}                          # 脏页比率${dirty_ratio}%（$(if [ "$is_low_memory" -eq 1 ]; then echo "避免OOM"; else echo "提高吞吐量"; fi)）
vm.dirty_background_ratio = ${dirty_background_ratio}    # 后台脏页比率${dirty_background_ratio}%
vm.dirty_writeback_centisecs = ${dirty_writeback_centisecs}  # ${dirty_writeback_centisecs}ms写回脏页（$(if [ "$is_single_core" -eq 1 ]; then echo "减少IO压力"; else echo "更频繁"; fi)）
vm.page-cluster = ${page_cluster}                        # $(if [ "$page_cluster" -gt 3 ]; then echo "强化页面聚类（最大化内存利用）"; else echo "适度页面聚类（平衡延迟与效率）"; fi)
$(if [ "$is_low_memory" -eq 1 ]; then echo "vm.overcommit_memory = 1   # 允许内存适度超配（紧急保护）"; fi)

# 8. 系统限制优化
fs.file-max = ${fs_file_max}                             # 文件描述符${fs_file_max}（${cpu_cores}核处理上限）
fs.nr_open = ${fs_nr_open}                               # 进程文件描述符${fs_nr_open}
net.ipv4.ip_unprivileged_port_start = ${ip_unprivileged_port_start}  # $(if [ "$ip_unprivileged_port_start" -gt 0 ]; then echo "限制非特权端口（减少开销）"; else echo "允许所有端口使用（灵活度优先）"; fi)

# 9. 处理器调度优化
kernel.sched_migration_cost_ns = ${sched_migration_cost}  # $(if [ "$is_single_core" -eq 1 ]; then echo "禁止进程迁移（唯一核心）"; else echo "优化进程迁移（平衡多核负载）"; fi)
kernel.sched_autogroup_enabled = ${sched_autogroup_enabled}  # $(if [ "$sched_autogroup_enabled" -eq 1 ]; then echo "启用自动分组（优化调度）"; else echo "禁用自动分组（精细化调度）"; fi)
kernel.sched_latency_ns = ${sched_latency}               # 调度延迟${sched_latency_ms}ms（$(if [ "$is_single_core" -eq 1 ]; then echo "稳定性优先"; else echo "提升响应速度"; fi)）
$(if [ "$cpu_cores" -ge 4 ]; then echo "kernel.sched_wakeup_granularity_ns = 500000  # 唤醒粒度0.5ms"; fi)

# 10. 网络接口硬件加速
net.ipv4.tcp_tso = 1                                    # 启用TCP分段卸载
net.ipv4.tcp_gro = 1                                    # 启用通用接收卸载
$(if [ "$tcp_lro" -eq 1 ]; then echo "net.ipv4.tcp_lro = 1  # 启用大型接收卸载（多核可承载）"; else echo "net.ipv4.tcp_lro = 0  # 禁用大型接收卸载（省内存）"; fi)
$(if [ "$cpu_cores" -ge 4 ]; then echo "net.core.default_qdisc = fq_codel  # 启用先进队列管理"; fi)
EOF
)

# 保存到文件
output_file="/etc/sysctl.d/99-sysctl.conf"
if echo "$config" > "$output_file"; then
    echo "配置已成功生成并保存到 $output_file"
    echo "请执行以下命令使配置生效:"
    echo "sudo sysctl --system"
    echo "建议重启系统以确保所有参数正确加载"
else
    echo "权限错误: 无法写入文件 $output_file"
    echo "请使用sudo运行脚本，例如:"
    echo "sudo $0 $1 $2 $3"
    exit 1
fi