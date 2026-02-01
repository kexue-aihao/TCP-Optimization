#!/bin/bash
#============================================
# VPS NAT 切割脚本 - 全新设计版本
# 功能：将单台 VPS 切割成多个独立 NAT 容器
# 用法：bash nat-split.sh [数量]
#============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置参数
SSH_PORT_MIN=1000
SSH_PORT_MAX=65535
HOST_SWAP_SIZE="2G"
CONTAINER_SWAP_SIZE="2.5G"
CONTAINER_MEMORY="512m"
CONTAINER_NAME_PREFIX="nat"
IMAGE_NAME="nat-debian:latest"
INFO_FILE="/root/nat-machines-info.txt"

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}  VPS NAT 切割脚本 v2.0${NC}"
echo -e "${BLUE}======================================${NC}\n"

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 权限运行此脚本${NC}"
   exit 1
fi

#============================================
# 工具函数
#============================================

# 生成18位强密码
generate_password() {
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 18
}

# 获取公网 IPv4
get_public_ipv4() {
    curl -4 -s --connect-timeout 3 ifconfig.me 2>/dev/null || \
    curl -4 -s ipv4.icanhazip.com 2>/dev/null || \
    curl -4 -s api.ipify.org 2>/dev/null || \
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | head -1 || \
    echo "获取失败"
}

# 生成唯一随机端口
generate_unique_port() {
    local used_ports=("$@")
    local port
    for _ in {1..100}; do
        port=$((SSH_PORT_MIN + RANDOM % (SSH_PORT_MAX - SSH_PORT_MIN + 1)))
        local is_used=0
        for used in "${used_ports[@]}"; do
            if [ "$port" -eq "$used" ]; then
                is_used=1
                break
            fi
        done
        if [ $is_used -eq 0 ]; then
            echo "$port"
            return
        fi
    done
    echo $((SSH_PORT_MIN + RANDOM % 1000))
}

# 检测系统资源并计算最大切割数
detect_max_count() {
    local cpu_cores=$(nproc 2>/dev/null || echo 2)
    local mem_total_mb=$(free -m | awk '/^Mem:/{print $2}')
    local disk_avail_mb=$(df / | awk 'NR==2 {print int($4/1024)}')
    
    # 计算限制
    local max_by_cpu=$((cpu_cores * 4))
    local max_by_mem=$(( (mem_total_mb + 2048 - 256) / 512 ))  # 预留256M + 2G swap
    local max_by_disk=$((disk_avail_mb / 2860))  # 每容器约2.8G
    
    # 取最小值，上限12
    local max_count=$max_by_cpu
    [ $max_by_mem -lt $max_count ] && max_count=$max_by_mem
    [ $max_by_disk -lt $max_count ] && max_count=$max_by_disk
    [ $max_count -gt 12 ] && max_count=12
    [ $max_count -lt 1 ] && max_count=1
    
    echo "$max_count|$cpu_cores|$mem_total_mb|$disk_avail_mb"
}

# 交互式选择数量
select_count_interactive() {
    local result=$(detect_max_count)
    local max_count=$(echo "$result" | cut -d'|' -f1)
    local cpu=$(echo "$result" | cut -d'|' -f2)
    local mem=$(echo "$result" | cut -d'|' -f3)
    local disk=$(echo "$result" | cut -d'|' -f4)
    
    echo -e "${CYAN}【系统资源检测】${NC}" >&2
    echo -e "  CPU: ${YELLOW}${cpu}${NC} 核" >&2
    echo -e "  内存: ${YELLOW}${mem}${NC} MB" >&2
    echo -e "  磁盘可用: ${YELLOW}${disk}${NC} MB" >&2
    echo -e "  建议最大切割: ${GREEN}${max_count}${NC} 台\n" >&2
    
    if [ ! -t 0 ]; then
        echo "$max_count"
        return
    fi
    
    echo -ne "${CYAN}请输入要切割的数量 [1-${max_count}]，回车默认 ${max_count}: ${NC}" >&2
    read -r input
    
    if [ -z "$input" ]; then
        echo "$max_count"
    elif [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$max_count" ]; then
        echo "$input"
    else
        echo -e "${YELLOW}输入无效，使用默认值 ${max_count}${NC}" >&2
        echo "$max_count"
    fi
}

#============================================
# 清理函数
#============================================

cleanup_all() {
    echo -e "${YELLOW}【清理旧资源】${NC}"
    
    # 停止并删除容器
    for i in {1..12}; do
        local name="${CONTAINER_NAME_PREFIX}${i}"
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
            docker stop "$name" >/dev/null 2>&1 || true
            docker rm "$name" >/dev/null 2>&1 || true
            echo -e "  ${GREEN}✓${NC} 已删除容器 $name"
        fi
    done
    
    # 删除镜像
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${IMAGE_NAME}$"; then
        docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓${NC} 已删除镜像"
    fi
    
    # 删除信息文件
    [ -f "$INFO_FILE" ] && rm -f "$INFO_FILE" && echo -e "  ${GREEN}✓${NC} 已删除信息文件"
    
    # 删除构建目录
    [ -d "/tmp/nat-build" ] && rm -rf /tmp/nat-build && echo -e "  ${GREEN}✓${NC} 已删除构建目录"
    
    # 删除宿主机 swap
    if [ -f /swapfile ]; then
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        sed -i '\|^/swapfile|d' /etc/fstab 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} 已删除宿主机 swap"
    fi
    
    echo -e "${GREEN}清理完成${NC}\n"
}

#============================================
# 安装与配置函数
#============================================

setup_host_swap() {
    echo -e "${YELLOW}【配置宿主机 Swap】${NC}"
    
    if [ -f /swapfile ] && swapon -s | grep -q '/swapfile'; then
        echo -e "  ${GREEN}✓${NC} Swap 已存在\n"
        return
    fi
    
    echo "  创建 ${HOST_SWAP_SIZE} swap 文件..."
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none 2>/dev/null || \
    fallocate -l ${HOST_SWAP_SIZE} /swapfile 2>/dev/null
    
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile
    
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
    if ! grep -q 'vm.swappiness' /etc/sysctl.conf 2>/dev/null; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi
    
    echo -e "  ${GREEN}✓${NC} Swap 配置完成\n"
}

install_docker() {
    echo -e "${YELLOW}【检查 Docker】${NC}"
    
    if command -v docker &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Docker 已安装\n"
        return
    fi
    
    echo "  正在安装 Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh >/dev/null 2>&1
    rm -f /tmp/get-docker.sh
    
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker
    
    echo -e "  ${GREEN}✓${NC} Docker 安装完成\n"
}

#============================================
# 构建镜像
#============================================

build_image() {
    echo -e "${YELLOW}【构建 NAT 镜像】${NC}"
    
    local build_dir="/tmp/nat-build"
    mkdir -p "$build_dir"
    
    # 创建 Dockerfile
    cat > "$build_dir/Dockerfile" <<'EOF'
FROM debian:11-slim

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server \
        procps \
        net-tools \
        iputils-ping \
        curl \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /run/sshd && \
    sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#*UsePAM.*/UsePAM no/' /etc/ssh/sshd_config && \
    echo 'UseDNS no' >> /etc/ssh/sshd_config && \
    ssh-keygen -A

EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]
EOF
    
    echo "  构建镜像中..."
    docker build -t "$IMAGE_NAME" "$build_dir" >/dev/null 2>&1
    
    rm -rf "$build_dir"
    echo -e "  ${GREEN}✓${NC} 镜像构建完成\n"
}

#============================================
# 创建容器
#============================================

create_containers() {
    local count=$1
    echo -e "${YELLOW}【创建 NAT 容器】${NC}"
    
    local public_ip=$(get_public_ipv4)
    local used_ports=()
    
    > "$INFO_FILE"
    
    for i in $(seq 1 $count); do
        local name="${CONTAINER_NAME_PREFIX}${i}"
        local port=$(generate_unique_port "${used_ports[@]}")
        local password=$(generate_password)
        
        used_ports+=($port)
        
        # 计算总 swap 限制
        local mem_mb=512
        local swap_mb=2560
        local total_mb=$((mem_mb + swap_mb))
        
        # 创建容器
        docker run -d \
            --name "$name" \
            -p ${port}:22 \
            --memory="${CONTAINER_MEMORY}" \
            --memory-swap="${total_mb}m" \
            --restart=unless-stopped \
            -e "ROOT_PASSWORD=${password}" \
            "$IMAGE_NAME" \
            /bin/bash -c "echo 'root:${password}' | chpasswd && exec /usr/sbin/sshd -D" \
            >/dev/null 2>&1
        
        echo "${name}|${port}|${password}" >> "$INFO_FILE"
        echo -e "  ${GREEN}✓${NC} ${name} - 端口 ${port}"
    done
    
    echo "${used_ports[*]}" >> "$INFO_FILE"
    echo -e "\n${GREEN}完成！共创建 ${count} 台 NAT 机器${NC}\n"
}

#============================================
# 显示信息
#============================================

show_info() {
    local public_ip=$(get_public_ipv4)
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  NAT 机器切割完成！${NC}"
    echo -e "${GREEN}========================================${NC}\n"
    
    echo -e "${BLUE}【连接信息】${NC}\n"
    printf "%-10s %-10s %-20s %s\n" "机器名" "SSH端口" "密码(18位)" "SSH命令"
    echo "--------------------------------------------------------------------------------"
    
    while IFS='|' read -r name port password; do
        [ -z "$name" ] || [[ "$name" =~ ^[0-9] ]] && continue
        printf "%-10s %-10s %-20s ssh -p %s root@%s\n" "$name" "$port" "$password" "$port" "$public_ip"
    done < "$INFO_FILE"
    
    echo -e "\n${BLUE}【重要提示】${NC}"
    echo -e "  • 连接 IP: ${YELLOW}${public_ip}${NC} (IPv4)"
    echo -e "  • 用户名: ${YELLOW}root${NC}"
    echo -e "  • 每台机器: 512M 内存 + 2.5G Swap"
    echo -e "  • 请确保云服务商安全组放行相应 SSH 端口"
    echo -e "  • 信息已保存至: ${YELLOW}${INFO_FILE}${NC}\n"
    echo -e "${GREEN}========================================${NC}\n"
}

#============================================
# 主流程
#============================================

main() {
    # 1. 清理旧资源
    cleanup_all
    
    # 2. 确定切割数量
    local count
    if [ -n "$1" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        count=$1
    else
        count=$(select_count_interactive)
    fi
    
    echo -e "${CYAN}准备创建 ${count} 台 NAT 机器...${NC}\n"
    
    # 3. 配置宿主机
    setup_host_swap
    install_docker
    
    # 4. 构建镜像
    build_image
    
    # 5. 创建容器
    create_containers "$count"
    
    # 6. 显示信息
    show_info
}

# 执行主流程
main "$@"
