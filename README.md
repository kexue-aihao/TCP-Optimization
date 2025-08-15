# TCP-Optimization
---
## TCP 优化脚本使用文档

使用方法：

---
	git clone https://github.com/kexue-aihao/TCP-Optimization.git
---	
	chmod +x generate_sysctl_config.sh
---
	./generate_sysctl_config.sh <单线程期望峰值> <CPU核心数量> <内存>
---	

## TCP Optimization Script Usage Documentation

Instructions:

---
	git clone https://github.com/kexue-aihao/TCP-Optimization.git
---
	chmod +x generate_sysctl_config.sh
---
	./generate_sysctl_config.sh <single-thread expected peak performance> <number of CPU cores> <memory>


## 使用注意事项：
	
### 1.使用前务必备份系统数据，不保证跨系统兼容性

### 2.不建议太小配置的机器使用该脚本

### 3.脚本最低运行配置，1核心1G运行内存

## Usage Notes:

### 1. Be sure to back up your system data before use. Cross-system compatibility is not guaranteed.

### 2. This script is not recommended for machines with undersized configurations.

### 3. The script requires a single core and 1GB of RAM.