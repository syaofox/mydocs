#!/bin/bash
# Linux Mint Btrfs 子卷优化脚本（含 Docker btrfs 驱动配置）
# 用途：将系统缓存、日志、开发工具目录隔离为独立子卷，避免 Timeshift 备份占用空间
#       并配置 Docker 使用原生 btrfs 存储驱动
# 版本：2.1
# 作者：根据原始脚本优化并整合 Docker 配置

set -euo pipefail   # 严格模式：出错即停、未定义变量报错、管道失败即停

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
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
ROOT_DEV=$(findmnt -n -o SOURCE /)
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
if [[ "$ROOT_FSTYPE" != "btrfs" ]]; then
    log_error "根文件系统不是 btrfs，无法执行此脚本"
fi
UUID=$(blkid -s UUID -o value "$ROOT_DEV" | head -1)
[[ -z "$UUID" ]] && log_error "无法获取根分区 UUID"

# 挂载参数
MOUNT_OPTS="defaults,noatime,compress=zstd:3,discard=async,space_cache=v2,commit=120"

# 最终隔离矩阵 (格式: 路径:子卷名:NoCoW)
TARGETS=(
    # 系统层面
    "/var/cache:var_cache:false"
    "/var/log:var_log:false"
    "/var/lib/docker:var_lib_docker:false"
    "/var/lib/libvirt/images:var_lib_images:true"
    
    # 用户缓存
    "$USER_HOME/.cache:user_cache:false"
    "$USER_HOME/.local/share/Trash:user_trash:false"
    
    # 开发工具链
    "$USER_HOME/.local/share/uv:user_uv:false"
    "$USER_HOME/.cargo:user_cargo:false"
    "$USER_HOME/.rustup:user_rustup:false"
    "$USER_HOME/go:user_go:false"
    "$USER_HOME/.npm:user_npm_cache:false"
    "$USER_HOME/.local/share/pnpm:user_pnpm_store:false"
    
    # AI 模型
    "$USER_HOME/ComfyUI/models:user_ai_models:false"
    "$USER_HOME/.cache/huggingface:user_hf_models:false"
)

# 备份原有配置文件
BACKUP_DIR="/root/btrfs_optimize_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
log_info "备份原有配置文件到 $BACKUP_DIR"
cp -a /etc/fstab "$BACKUP_DIR/fstab"
cp -a /etc/sysctl.d/* "$BACKUP_DIR/sysctl.d" 2>/dev/null || true
[ -f /etc/docker/daemon.json ] && cp -a /etc/docker/daemon.json "$BACKUP_DIR/daemon.json" 2>/dev/null || true

# 临时挂载点（使用唯一目录）
MNT=$(mktemp -d /tmp/btrfs_mnt_XXXXXX)
trap 'umount -l "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null; exit' INT TERM EXIT
mount "$ROOT_DEV" "$MNT" -o subvolid=5 || log_error "无法挂载 btrfs 根卷"

# 更新根目录 fstab 挂载参数（精确匹配根子卷）
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
    
    # 跳过空行或无效条目
    [[ -z "$DIR" || -z "$SUBVOL_NAME" ]] && continue
    
    # 确保目录存在
    mkdir -p "$DIR"
    
    # 设置权限（如果是用户目录）
    if [[ "$DIR" == "$USER_HOME"* ]]; then
        chown "$REAL_USER":"$REAL_USER" "$DIR"
    fi
    
    # 检查是否已经是子卷
    if btrfs subvolume show "$DIR" &>/dev/null; then
        log_info "✅ $DIR 已经是子卷，跳过"
        continue
    fi
    
    log_info "开始处理 $DIR"
    
    # 停止可能访问该目录的服务（若有）
    case "$DIR" in
        "/var/lib/docker")
            systemctl stop docker.socket docker 2>/dev/null || true
            ;;
        "/var/lib/libvirt/images")
            systemctl stop libvirtd 2>/dev/null || true
            ;;
    esac
    
    # 强制关闭所有访问该目录的进程（危险操作，提示用户）
    if lsof +D "$DIR" &>/dev/null; then
        log_warn "目录 $DIR 正在被以下进程使用："
        lsof +D "$DIR" | head -5
        echo -n "是否强制终止这些进程？(y/N) "
        read -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            fuser -k "$DIR" 2>/dev/null || true
            sleep 2
        else
            log_error "请手动关闭相关进程后重试，或跳过此目录"
        fi
    fi
    
    # 创建子卷（如果不存在）
    SV_PATH="$MNT/@$SUBVOL_NAME"
    if [[ ! -d "$SV_PATH" ]]; then
        btrfs subvolume create "$SV_PATH" || log_error "创建子卷 $SV_PATH 失败"
        log_info "子卷 $SV_PATH 创建成功"
    else
        log_info "子卷 $SV_PATH 已存在，将复用"
    fi
    
    # 设置 NoCoW 属性（在复制数据前）
    if [[ "$NOCOW" == "true" ]]; then
        chattr +C "$SV_PATH" || log_warn "设置 NoCoW 失败，可能内核不支持"
        log_info "已为 $SV_PATH 启用 NoCoW"
    fi
    
    # 迁移数据：重命名原目录 -> 创建新目录 -> 挂载子卷 -> 复制数据 -> 清理备份
    OLD_DIR="${DIR}_bak_$$"
    mv "$DIR" "$OLD_DIR" || log_error "无法移动 $DIR 到 $OLD_DIR"
    mkdir -p "$DIR" || log_error "无法创建新目录 $DIR"
    
    # 复制权限和所有者（从原目录）
    chmod --reference="$OLD_DIR" "$DIR" 2>/dev/null || true
    chown --reference="$OLD_DIR" "$DIR" 2>/dev/null || true
    
    # 挂载子卷
    mount "$ROOT_DEV" "$DIR" -o "subvol=@$SUBVOL_NAME,$MOUNT_OPTS" || {
        # 回滚
        rmdir "$DIR"
        mv "$OLD_DIR" "$DIR"
        log_error "挂载子卷到 $DIR 失败，已回滚"
    }
    
    # 复制数据（使用 rsync 保留属性，若不可用则用 cp）
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
    
    # 删除原目录备份
    rm -rf "$OLD_DIR" || log_warn "无法删除备份目录 $OLD_DIR，请手动清理"
    
    # 添加到 fstab（如果尚未添加）
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
    # 备份 fstab 后再修改
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

# 立即生效（不重启）
sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null 2>&1 || true
sysctl -p /etc/sysctl.d/99-developer-optimizations.conf >/dev/null 2>&1 || true

# ==================== Docker btrfs 驱动配置 ====================
log_info "配置 Docker 使用 btrfs 存储驱动..."
if command -v docker &>/dev/null; then
    # 停止 Docker 服务
    systemctl stop docker docker.socket 2>/dev/null || true
    
    # 备份现有 daemon.json（如果存在）
    if [ -f /etc/docker/daemon.json ]; then
        cp /etc/docker/daemon.json "$BACKUP_DIR/daemon.json"
    fi
    
    # 创建或更新 daemon.json
    if command -v jq >/dev/null 2>&1 && [ -f /etc/docker/daemon.json ]; then
        # 使用 jq 合并
        jq '. + {"storage-driver": "btrfs"}' /etc/docker/daemon.json | tee /etc/docker/daemon.json.tmp >/dev/null
        mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
    else
        # 直接写入
        cat <<EOF > /etc/docker/daemon.json
{
  "storage-driver": "btrfs"
}
EOF
    fi
    
    # 检查 /var/lib/docker 是否存在旧数据（若已有数据且非 btrfs 驱动，需提示迁移）
    if [ -d /var/lib/docker ] && [ ! -f /var/lib/docker/.migrated ]; then
        log_warn "Docker 数据目录已存在，若之前使用其他存储驱动，切换后可能无法访问旧镜像/容器"
        log_warn "建议：备份现有数据后清空 /var/lib/docker/*，或手动迁移"
        echo -n "是否清空 /var/lib/docker 并重新开始？(y/N) "
        read -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            rm -rf /var/lib/docker/*
            log_info "已清空 /var/lib/docker，Docker 将在启动时初始化 btrfs 存储"
        else
            log_info "保留现有数据，启动后请手动检查 Docker 状态"
        fi
    fi
    
    # 启动 Docker
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

# 最终总结
log_info "=========================================="
log_info "所有优化已完成！"
log_info "备份文件保存在: $BACKUP_DIR"
log_info "=========================================="
log_warn "请重启系统以使所有挂载生效，并验证 Timeshift 是否仅备份根子卷 @"
log_warn "重启后，检查 Docker 驱动: docker info | grep 'Storage Driver'"
