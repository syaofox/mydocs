#!/bin/bash
# ZRAM 一键配置脚本（zram-generator 版）
# 用途：使用 zstd 压缩，将部分内存作为压缩交换空间，缓解内存压力
# 适用于：Linux Mint / Ubuntu 系列

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 检查 root 权限
[[ "$EUID" -ne 0 ]] && log_error "请使用 sudo 运行此脚本"

# 安装 zram-generator
if ! command -v systemd-zram-setup &>/dev/null; then
    log_info "正在安装 zram-generator..."
    apt update && apt install -y zram-generator
else
    log_info "zram-generator 已安装"
fi

# 备份现有配置（如果存在）
CONF_FILE="/etc/systemd/zram-generator.conf"
if [[ -f "$CONF_FILE" ]]; then
    BACKUP="${CONF_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$CONF_FILE" "$BACKUP"
    log_info "已备份原有配置到 $BACKUP"
fi

# 写入新配置
log_info "配置 ZRAM：使用 50% 物理内存，zstd 压缩，优先级 100"
cat <<EOF > "$CONF_FILE"
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF

# 重启 ZRAM 服务
log_info "重启 ZRAM 服务..."
systemctl restart systemd-zram-setup@zram0.service

# 验证
log_info "验证 ZRAM 配置："
echo "--- swap 设备 ---"
swapon --show
echo "--- ZRAM 设备详情 ---"
zramctl

log_info "✅ ZRAM 配置完成！"
log_info "说明："
log_info "  - 使用 50% 物理内存（${mem} KB）作为 ZRAM 压缩空间"
log_info "  - 压缩算法：zstd"
log_info "  - 优先级：100（高于其他交换设备，如有）"
log_info "  - 如需调整比例，请编辑 ${CONF_FILE} 并运行：systemctl restart systemd-zram-setup@zram0.service"