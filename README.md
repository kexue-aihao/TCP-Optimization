# TCP优化参数实例存储

---

## 参数文件命名规范及其注意事项

- 机器硬件参数配置+VPS区域+带宽+VPS厂商+机器产品实例名称

- 仓库的TCP参数可以拿去直接用，也可以复制下来，自行修改，然后再应用

- 本仓库存储的参数，皆为实测过没有使用问题的参数，尽可能保证速度优先的情况下，保证抖动不高

---

## 其他VPS厂商的机器如果有需要补充参数可以提交PR合并

---

脚本快捷复制命令

---

### AWS光帆日本调参命令

	wget -N https://raw.githubusercontent.com/kexue-aihao/TCP-Optimization/refs/heads/master/2C1G_Amazon_micro_JP_install.sh && bash 2C1G_Amazon_micro_JP_install.sh

### 一键切割NAT脚本

	wget -N https://raw.githubusercontent.com/kexue-aihao/TCP-Optimization/refs/heads/master/nat.sh && bash nat.sh
	
### 拉黑Ucloud快捷命令

	wget -N https://raw.githubusercontent.com/kexue-aihao/TCP-Optimization/refs/heads/master/block_as135377.sh && bash block_as135377.sh
