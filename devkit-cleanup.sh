#!/usr/bin/env bash
# ============================================================================
# devkit-cleanup.sh — 完整删除 setup-ubuntu.sh 安装的制品并清理 .bashrc
# ----------------------------------------------------------------------------
# 删除范围：
#   ~/.devkit（Rust 静态工具、nvim、node、npm 全局包、uv/Python、构建缓存）
#   ~/.bashrc 中带 “devkit” 标记的托管块
#   仅当 setup 创建过时才删除 ~/.config/nvim 与 nvim 的 data/state/cache
#   若 setup 备份过旧的 ~/.config/nvim，则自动还原
#
# 用法：
#   bash devkit-cleanup.sh              # 默认清理 ~/.devkit
#   DEVKIT_ROOT=/path bash devkit-cleanup.sh
#   DRY_RUN=1 bash devkit-cleanup.sh    # 只打印将执行的操作
# ============================================================================
set -Eeuo pipefail

DEVKIT_ROOT="${DEVKIT_ROOT:-$HOME/.devkit}"
DRY_RUN="${DRY_RUN:-0}"
STATE_FILE="$DEVKIT_ROOT/state/setup.env"
RC="$HOME/.bashrc"

log(){ printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
run(){ if [ "$DRY_RUN" = "1" ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }

# 读取 setup 记录；没有记录时按“只清理根目录 + bashrc 块”处理
NVIM_CONFIG_CREATED=0
NVIM_CONFIG_BACKUP=""
NVIM_DATA_CREATED=0
NVIM_STATE_CREATED=0
NVIM_CACHE_CREATED=0
BASH_RC_CREATED=0
UV_LOCAL_PY_CREATED=0
UV_RECEIPT_CREATED=0
UV_SHARE_CREATED=0
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  log "读取安装记录：$STATE_FILE"
else
  warn "无安装记录，将按保守策略清理"
fi

log "清理 .bashrc 托管块"
if [ -f "$RC" ]; then
  run sed -i '/^# >>> devkit (setup-ubuntu.sh) >>>/,/^# <<< devkit (setup-ubuntu.sh) <<</d' "$RC"
  # setup 之前没有 .bashrc 且清理后只剩空行 → 删掉空文件
  if [ "$BASH_RC_CREATED" = "1" ] && [ "$DRY_RUN" != "1" ] \
     && ! grep -qE '^[^[:space:]]' "$RC"; then
    run rm -f "$RC"
  fi
else
  warn "$RC 不存在，跳过"
fi

# 先处理 nvim 配置和运行数据（它们在 ~/.devkit 之外）
managed=0
[ -f "$HOME/.config/nvim/.devkit-managed" ] && managed=1
if [ "$NVIM_CONFIG_BACKUP" != "" ] && [ -e "$NVIM_CONFIG_BACKUP" ]; then
  if [ "$managed" = "1" ] || [ ! -e "$HOME/.config/nvim" ]; then
    log "还原旧 nvim 配置：$NVIM_CONFIG_BACKUP → $HOME/.config/nvim"
    run rm -rf "$HOME/.config/nvim"
    run mv "$NVIM_CONFIG_BACKUP" "$HOME/.config/nvim"
  else
    warn "~/.config/nvim 已是新的用户配置，不覆盖；把备份移到 ~/.config/nvim.devkit-backup"
    run mv "$NVIM_CONFIG_BACKUP" "$HOME/.config/nvim.devkit-backup"
  fi
elif [ "$NVIM_CONFIG_CREATED" = "1" ] && [ "$managed" = "1" ]; then
  log "删除 setup 创建的 ~/.config/nvim"
  run rm -rf "$HOME/.config/nvim"
elif [ "$NVIM_CONFIG_CREATED" = "1" ]; then
  warn "~/.config/nvim 缺少托管标记，保留（如需删除请手动确认）"
else
  log "~/.config/nvim 不是 setup 创建，保留"
fi

for pair in "NVIM_DATA_CREATED:$HOME/.local/share/nvim" \
            "NVIM_STATE_CREATED:$HOME/.local/state/nvim" \
            "NVIM_CACHE_CREATED:$HOME/.cache/nvim"; do
  key="${pair%%:*}"; dir="${pair#*:}"
  eval "flag=\${$key:-0}"
  if [ "$flag" = "1" ]; then
    log "删除 setup 创建的 $dir"
    run rm -rf "$dir"
  else
    log "$dir 不是 setup 创建（或已存在旧数据），保留"
  fi
done

if [ "$UV_LOCAL_PY_CREATED" = "1" ]; then
  log "删除 uv 创建的 ~/.local/bin/python3.12"
  run rm -f "$HOME/.local/bin/python3.12"
fi
if [ "$UV_RECEIPT_CREATED" = "1" ]; then
  log "删除 uv 安装凭据"
  run rm -f "$HOME/.config/uv/uv-receipt.json"
  run rmdir "$HOME/.config/uv" 2>/dev/null || true
fi
if [ "$UV_SHARE_CREATED" = "1" ]; then
  log "删除 uv 创建的 ~/.local/share/uv"
  run rm -rf "$HOME/.local/share/uv"
fi

if [ -d "$DEVKIT_ROOT" ]; then
  log "删除制品根目录：$DEVKIT_ROOT"
  run rm -rf "$DEVKIT_ROOT"
else
  warn "$DEVKIT_ROOT 不存在"
fi

# 清理可能残留的 nvim 编译安装软链（旧版脚本路径，兼容用）
for old in "$HOME/.nvim-kit" "$HOME/.cargo-musl" "$HOME/.rustup-musl"; do
  [ -e "$old" ] && warn "发现旧脚本遗留：$old（本脚本不自动删除，请确认后手动处理）"
done

log "清理完成。请重开 shell 或先执行：exec bash"
