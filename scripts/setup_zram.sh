#!/bin/bash
# ZRAM 一键配置脚本（传统版，适用于所有 Linux Mint 版本）
set -euo pipefail

[[ "$EUID" -ne 0 ]] && echo "请使用 sudo 运行" && exit 1

log_info() { echo "[INFO] $1"; }
log_info "配置 ZRAM..."

# 创建自定义服务（不覆盖系统文件）
sudo tee /usr/local/sbin/zram-setup <<'EOF'
#!/bin/bash
mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
zram_size=$((mem_total * 1024 / 2))  # 50% 内存，单位字节

# 卸载旧设备
swapoff /dev/zram0 2>/dev/null || true
rmmod zram 2>/dev/null || true

# 加载模块
modprobe zram num_devices=1

# 设置压缩算法（优先 zstd，否则 lz4）
if [ -f /sys/block/zram0/comp_algorithm ]; then
    if grep -q zstd /sys/block/zram0/comp_algorithm; then
        echo zstd > /sys/block/zram0/comp_algorithm
    elif grep -q lz4 /sys/block/zram0/comp_algorithm; then
        echo lz4 > /sys/block/zram0/comp_algorithm
    fi
fi

# 设置大小
echo $zram_size > /sys/block/zram0/disksize

# 启用 swap
mkswap /dev/zram0
swapon -p 100 /dev/zram0
EOF

sudo chmod +x /usr/local/sbin/zram-setup

# 创建 systemd 服务
sudo tee /etc/systemd/system/zram-setup.service <<'EOF'
[Unit]
Description=ZRAM Setup Service
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zram-setup
RemainAfterExit=yes

[Install]
WantedBy=swap.target
EOF

# 启用服务
sudo systemctl daemon-reload
sudo systemctl enable zram-setup.service
sudo systemctl start zram-setup.service

# 验证
echo "验证 ZRAM 配置："
swapon --show
zramctl

echo "✅ ZRAM 配置完成！"
