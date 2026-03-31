#!/bin/bash
# Linux Mint Btrfs 子卷优化脚本（含 Docker btrfs 驱动配置）
# 版本：2.3 - 扩展子卷隔离范围，优化 NoCoW 策略

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 检查是否为 root
[[ "$EUID" -ne 0 ]] && log_error "请使用 sudo 运行此脚本"

# 获取真实用户
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER=$(logname 2>/dev/null || echo "")
    [[ -z "$REAL_USER" ]] && log_error "无法确定普通用户名，请使用 sudo 运行"
fi
USER_HOME=$(eval echo "~$REAL_USER")
[[ ! -d "$USER_HOME" ]] && log_error "用户 $REAL_USER 的家目录 $USER_HOME 不存在"

# 检查根文件系统是否为 btrfs
ROOT_DEV_RAW=$(findmnt -n -o SOURCE /)
# 提取设备路径（去掉子卷后缀，如 /dev/sda1[/@] -> /dev/sda1）
ROOT_DEV=$(echo "$ROOT_DEV_RAW" | cut -d '[' -f1)
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
if [[ "$ROOT_FSTYPE" != "btrfs" ]]; then
    log_error "根文件系统不是 btrfs，无法执行此脚本"
fi
UUID=$(blkid -s UUID -o value "$ROOT_DEV" | head -1)
[[ -z "$UUID" ]] && log_error "无法获取根分区 UUID（设备：$ROOT_DEV）"

# 挂载参数
MOUNT_OPTS="defaults,noatime,compress=zstd:3,discard=async,space_cache=v2,commit=120,x-gvfs-hide"

# 目标列表 (格式: 路径:子卷名:NoCoW)
# 说明：
# - 系统核心目录隔离（便于快照回滚时保留数据）
# - 用户缓存及开发工具目录启用 NoCoW 提升性能
TARGETS=(
    # 系统数据隔离
    "/opt:opt:false"
    "/srv:srv:false"
    "/usr/local:usr_local:false"
    # 系统日志与缓存（日志启用 NoCoW）
    "/var/cache:var_cache:false"
    "/var/log:var_log:true"
    "/var/lib/docker:var_lib_docker:false"
    "/var/lib/libvirt/images:var_lib_images:true"
    # 用户缓存（部分启用 NoCoW）
    "$USER_HOME/.cache:user_cache:false"
    "$USER_HOME/.local/share/Trash:user_trash:true"       # 回收站，NoCoW 更佳
    "$USER_HOME/.local/share/uv:user_uv:false"
    "$USER_HOME/.cargo:user_cargo:true"
    "$USER_HOME/.rustup:user_rustup:false"
    "$USER_HOME/.npm:user_npm_cache:true"
    "$USER_HOME/.local/share/pnpm:user_pnpm_store:true"
    "$USER_HOME/.ComfyUI/models:user_ai_models:false"
    "$USER_HOME/.cache/huggingface:user_hf_models:false"
    # 可选：浏览器缓存（大量小文件，建议启用 NoCoW，取消注释即可）
    "$USER_HOME/.cache/google-chrome:user_chrome_cache:true"
    "$USER_HOME/.cache/chromium:user_chromium_cache:true"
    "$USER_HOME/.config/BraveSoftware/Brave-Browser:brave_browser:true"
)

# 备份配置
BACKUP_DIR="/root/btrfs_optimize_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
log_info "备份原有配置文件到 $BACKUP_DIR"
cp -a /etc/fstab "$BACKUP_DIR/fstab"
cp -a /etc/sysctl.d/* "$BACKUP_DIR/sysctl.d" 2>/dev/null || true
[ -f /etc/docker/daemon.json ] && cp -a /etc/docker/daemon.json "$BACKUP_DIR/daemon.json" 2>/dev/null || true

# 临时挂载点（btrfs 根卷）
MNT=$(mktemp -d /tmp/btrfs_mnt_XXXXXX)
trap 'umount -l "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null; exit' INT TERM EXIT
mount "$ROOT_DEV" "$MNT" -o subvolid=5 || log_error "无法挂载 btrfs 根卷"

# 更新根目录 fstab 挂载参数
log_info "优化根目录挂载参数..."
if grep -q "^[^#]*$UUID.*subvol=@[ ,]" /etc/fstab; then
    sed -i.bak "s|\(^[^#]*$UUID.*\)subvol=@\([ ,]\)|\1${MOUNT_OPTS},subvol=@\2|g" /etc/fstab
    log_info "根目录挂载参数已更新"
else
    log_warn "未在 fstab 中找到根子卷 @ 的挂载行，请手动检查"
fi

# 处理每个目标
for t in "${TARGETS[@]}"; do
    IFS=':' read -r DIR SUBVOL_NAME NOCOW <<< "$t"
    [[ -z "$DIR" || -z "$SUBVOL_NAME" ]] && continue

    # 确保父目录存在
    mkdir -p "$(dirname "$DIR")" 2>/dev/null || true
    mkdir -p "$DIR" 2>/dev/null || true

    # 对于用户目录，修正所有权（如果目录已存在且属于 root）
    if [[ "$DIR" == "$USER_HOME"* ]]; then
        chown "$REAL_USER":"$REAL_USER" "$DIR" 2>/dev/null || true
    fi

    # 检查是否已经是子卷
    if btrfs subvolume show "$DIR" &>/dev/null; then
        log_info "✅ $DIR 已经是子卷，跳过"
        continue
    fi

    log_info "开始处理 $DIR"

    # 停止相关服务
    case "$DIR" in
        "/var/lib/docker") systemctl stop docker.socket docker 2>/dev/null || true ;;
        "/var/lib/libvirt/images") systemctl stop libvirtd 2>/dev/null || true ;;
    esac

    # 检查目录是否被占用（仅对非 /usr/local 等关键系统目录警告，不强制终止）
    if lsof +D "$DIR" &>/dev/null; then
        log_warn "目录 $DIR 正在被以下进程使用："
        lsof +D "$DIR" | head -5
        if [[ "$DIR" == "/usr/local" || "$DIR" == "/opt" || "$DIR" == "/srv" ]]; then
            log_warn "关键系统目录 $DIR 被占用，将跳过迁移（风险较高）"
            continue
        else
            echo -n "是否强制终止这些进程？(y/N) "
            read -r ans
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                fuser -k "$DIR" 2>/dev/null || true
                sleep 2
            else
                log_error "请手动关闭相关进程后重试，或跳过此目录"
            fi
        fi
    fi

    # 子卷路径（挂载在根卷下，前缀 @）
    SV_PATH="$MNT/@$SUBVOL_NAME"
    if [[ ! -d "$SV_PATH" ]]; then
        btrfs subvolume create "$SV_PATH" || log_error "创建子卷 $SV_PATH 失败"
        log_info "子卷 $SV_PATH 创建成功"
    else
        log_info "子卷 $SV_PATH 已存在，将复用"
    fi

    # 设置 NoCoW（必须在新创建的空子卷上立即执行）
    if [[ "$NOCOW" == "true" ]]; then
        chattr +C "$SV_PATH" || log_warn "设置 NoCoW 失败，可能内核不支持"
        log_info "已为 $SV_PATH 启用 NoCoW"
    fi

    # 移动原目录内容到备份，并创建新挂载点
    OLD_DIR="${DIR}_bak_$$"
    mv "$DIR" "$OLD_DIR" || log_error "无法移动 $DIR 到 $OLD_DIR"
    mkdir -p "$DIR" || log_error "无法创建新目录 $DIR"

    # 保留原权限和属主
    chmod --reference="$OLD_DIR" "$DIR" 2>/dev/null || true
    chown --reference="$OLD_DIR" "$DIR" 2>/dev/null || true

    # 挂载子卷
    mount "$ROOT_DEV" "$DIR" -o "subvol=@$SUBVOL_NAME,$MOUNT_OPTS" || {
        rmdir "$DIR"
        mv "$OLD_DIR" "$DIR"
        log_error "挂载子卷到 $DIR 失败，已回滚"
    }

    # 复制数据
    if command -v rsync &>/dev/null; then
        rsync -aAX "$OLD_DIR"/ "$DIR"/ || {
            umount "$DIR"
            rmdir "$DIR"
            mv "$OLD_DIR" "$DIR"
            log_error "数据复制失败，已回滚"
        }
    else
        cp -a --reflink=auto "$OLD_DIR"/. "$DIR"/ || {
            umount "$DIR"
            rmdir "$DIR"
            mv "$OLD_DIR" "$DIR"
            log_error "数据复制失败，已回滚"
        }
    fi

    rm -rf "$OLD_DIR" || log_warn "无法删除备份目录 $OLD_DIR，请手动清理"

    # 添加 fstab 条目（如果不存在）
    if ! grep -q "subvol=@$SUBVOL_NAME[ ,]" /etc/fstab; then
        echo "UUID=$UUID  $DIR  btrfs  $MOUNT_OPTS,subvol=@$SUBVOL_NAME  0  0" >> /etc/fstab
        log_info "已添加 $DIR 挂载项到 fstab"
    else
        log_info "$DIR 挂载项已存在于 fstab，跳过添加"
    fi

    log_info "✅ $DIR 处理完成"
done

# 清理临时挂载
umount "$MNT" && rmdir "$MNT"
trap - INT TERM EXIT

# 优化 Swap 优先级
log_info "调整 Swap 优先级..."
if grep -q "^[^#]*swap" /etc/fstab; then
    cp /etc/fstab "$BACKUP_DIR/fstab_after"
    sed -i 's/\(^[^#]*swap.*\)defaults\(.*\)/\1defaults,pri=100\2/g' /etc/fstab
    sed -i 's/\(^[^#]*swap.*\)sw\(.*\)/\1sw,pri=100\2/g' /etc/fstab
    log_info "Swap 优先级已提升至 100"
else
    log_warn "未找到 swap 条目，请手动检查"
fi

# 内核参数优化
log_info "应用内核参数优化..."
cat << 'EOF' > /etc/sysctl.d/99-swappiness.conf
vm.swappiness=10
EOF
cat << 'EOF' > /etc/sysctl.d/99-developer-optimizations.conf
fs.inotify.max_user_watches=524288
vm.max_map_count=262144
EOF
sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null 2>&1 || true
sysctl -p /etc/sysctl.d/99-developer-optimizations.conf >/dev/null 2>&1 || true

# Docker btrfs 驱动配置
log_info "配置 Docker 使用 btrfs 存储驱动..."
if command -v docker &>/dev/null; then
    systemctl stop docker docker.socket 2>/dev/null || true
    if [ -f /etc/docker/daemon.json ]; then
        cp /etc/docker/daemon.json "$BACKUP_DIR/daemon.json"
    fi
    if command -v jq >/dev/null 2>&1 && [ -f /etc/docker/daemon.json ]; then
        jq '. + {"storage-driver": "btrfs"}' /etc/docker/daemon.json | tee /etc/docker/daemon.json.tmp >/dev/null
        mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
    else
        cat <<EOF > /etc/docker/daemon.json
{
  "storage-driver": "btrfs"
}
EOF
    fi
    if [ -d /var/lib/docker ] && [ ! -f /var/lib/docker/.migrated ]; then
        log_warn "Docker 数据目录已存在，若之前使用其他存储驱动，切换后可能无法访问旧镜像/容器"
        echo -n "是否清空 /var/lib/docker 并重新开始？(y/N) "
        read -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            rm -rf /var/lib/docker/*
            log_info "已清空 /var/lib/docker，Docker 将在启动时初始化 btrfs 存储"
        else
            log_info "保留现有数据，启动后请手动检查 Docker 状态"
        fi
    fi
    systemctl start docker
    sleep 2
    if docker info 2>/dev/null | grep -q "Storage Driver: btrfs"; then
        log_info "✅ Docker 存储驱动已成功设置为 btrfs"
    else
        log_warn "Docker 存储驱动可能未生效，请手动检查：docker info | grep 'Storage Driver'"
    fi
else
    log_warn "Docker 未安装，跳过 Docker 配置"
fi

log_info "=========================================="
log_info "所有优化已完成！"
log_info "备份文件保存在: $BACKUP_DIR"
log_info "=========================================="
log_warn "请重启系统以使所有挂载生效，并验证 Timeshift 是否仅备份根子卷 @"
log_warn "重启后，检查 Docker 驱动: docker info | grep 'Storage Driver'"
log_warn "建议检查: mount | grep btrfs 查看所有子卷挂载"
