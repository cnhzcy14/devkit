#!/usr/bin/env bash
# ============================================================================
# devkit-up.sh —— 宿主机侧启动 ubuntu:20.04 母机，并按“root 装依赖、
#                  普通用户装 home 工具”的边界执行。
# ----------------------------------------------------------------------------
# 用法：
#   ./devkit-up.sh            启动容器并进入普通用户 shell
#   ./devkit-up.sh --rust     以 root 装 apt 依赖，再以普通用户只装 Rust 工具
#   ./devkit-up.sh --setup    以 root 装 apt 依赖，再以同名普通用户装全部工具
#   ./devkit-up.sh --apt      只以 root 装 apt 依赖，然后进入普通用户 shell
#
# 进入普通用户的方式与手工操作一致：
#   docker exec -it <容器名> su - $USER
#
# 容器名、hostname、home 挂载、UID/GID 与你现有启动脚本保持一致；
# 容器后台常驻，退出 shell 后仍可用 docker exec 进入。
# ============================================================================
set -Eeuo pipefail

HOST_USER="${USER:?USER 未设置}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
HNAME="$(hostname)"
IMAGE="${IMAGE:-ubuntu:20.04}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$SCRIPT_DIR/setup-ubuntu.sh"
CLEANUP="$SCRIPT_DIR/devkit-cleanup.sh"
MODE="${1:-shell}"

case "$MODE" in
  shell|--setup|--apt|--rust) ;;
  -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  *) echo "未知参数：$MODE（可用 --rust / --setup / --apt）" >&2; exit 2 ;;
esac

[ -f "$SETUP" ] || { echo "找不到 $SETUP" >&2; exit 1; }

NAME="${HOST_USER}_$(openssl rand -base64 8 | md5sum | cut -c1-8)"
CONTAINER=""

on_error(){
  printf '\n[x] 执行失败。容器 %s 仍保留，可进入排障：\n' "$NAME" >&2
  printf '    docker exec -it %s /bin/bash\n' "$NAME" >&2
  printf '    docker exec -it %s su - %s\n' "$NAME" "$HOST_USER" >&2
}
trap on_error ERR

# 1) 后台启动容器：日常 shell 由后面的 docker exec 进入
docker run -d --net=host -h "$HNAME" --name "$NAME" \
  -v "/home/$HOST_USER:/home/$HOST_USER" -w "/home/$HOST_USER" \
  "$IMAGE" sleep infinity >/dev/null
CONTAINER="$NAME"

# 2) root：创建与宿主机同 UID/GID 的用户（与你的 docker run 命令一致）
docker exec "$CONTAINER" /bin/bash -c "
  set -e
  groupadd -g $HOST_GID '$HOST_USER'
  useradd -d /home/$HOST_USER -s /bin/bash -g '$HOST_USER' -u $HOST_UID '$HOST_USER'
"

# 3) root：只装系统依赖（curl / git / 编译工具 / musl 等）
if [ "$MODE" = "--setup" ] || [ "$MODE" = "--apt" ] || [ "$MODE" = "--rust" ]; then
  echo "[1/2] root 安装系统依赖 ..."
  docker exec "$CONTAINER" /bin/bash -c "APT_ONLY=1 bash '$SETUP'"
fi

# 4) 普通用户：装所有 home 内的开发工具
if [ "$MODE" = "--setup" ] || [ "$MODE" = "--rust" ]; then
  echo "[2/2] 普通用户 $HOST_USER 安装开发工具 ..."
  EXTRA=""
  [ "$MODE" = "--rust" ] && EXTRA="RUST_ONLY=1"
  docker exec "$CONTAINER" /bin/bash -c "su - '$HOST_USER' -c '$EXTRA SKIP_APT=1 bash $SETUP'"
fi

echo
echo "容器名：$NAME"
echo "进入普通用户：docker exec -it $NAME su - $HOST_USER"
echo "清理：docker exec -it $NAME su - $HOST_USER -c 'bash $CLEANUP'"
echo

# 5) 进入普通用户 shell
exec docker exec -it "$CONTAINER" su - "$HOST_USER"
