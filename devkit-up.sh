#!/usr/bin/env bash
# ============================================================================
# devkit-up.sh —— 宿主机侧启动 ubuntu:20.04 母机，并按“root 装依赖、
#                  普通用户装 home 工具”的边界执行。
# ----------------------------------------------------------------------------
# 用法：
#   ./devkit-up.sh            启动容器并进入普通用户 shell
#   ./devkit-up.sh --setup    以 root 装 apt 依赖，再以同名普通用户装全部工具
#   ./devkit-up.sh --apt      只以 root 装 apt 依赖，然后进入普通用户 shell
#
# 环境变量（都会透传给容器内 setup）：
#   IMAGE=myreg/ubuntu20.04:tag   基础镜像（默认 ubuntu:20.04，可用内网自制镜像）
#   APT_MIRROR=off                保留镜像内已有 apt 源；也可填内网镜像地址
#   SKIP_APT=1                    镜像已预装系统依赖时，跳过 root 的 apt 阶段
#   RUSTUP_DIST_SERVER / RUSTUP_UPDATE_ROOT / RUSTUP_INIT_URL
#   CARGO_REGISTRY / NPM_REGISTRY / NODE_DIST / GH_MIRRORS
#   PY_MIRROR / PYPI_INDEX / OPENSSL_TARBALL
#   WITH_OPENCODE / OPENCODE_VERSION / HUNK_VERSION / YAZI_VERSION
#   UV_VERSION / PYTHON_VERSION
#   DEVKIT_ROOT / UPDATE_TS_PARSERS / TS_CLI_VERSION
#   FORCE_NVIM / FORCE_TS_CLI / FORCE_RUST_TOOLS / FORCE_LAZYVIM
#
# 进入普通用户的方式与手工操作一致：
#   docker exec -it -u 0 <容器名> su - $USER
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
ENV_FILE=/tmp/devkit-up.env
ENV_KEYS=(MIRROR APT_MIRROR SKIP_APT RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT
  RUSTUP_INIT_URL CARGO_REGISTRY NPM_REGISTRY NODE_DIST GH_MIRRORS
  OPENSSL_TARBALL PY_MIRROR PYPI_INDEX WITH_OPENCODE OPENCODE_VERSION HUNK_VERSION
  YAZI_VERSION UV_VERSION PYTHON_VERSION DEVKIT_ROOT UPDATE_TS_PARSERS TS_CLI_VERSION FORCE_NVIM
  FORCE_TS_CLI FORCE_RUST_TOOLS FORCE_LAZYVIM)

env_file_contents(){
  local k v q
  for k in "${ENV_KEYS[@]}"; do
    v="${!k:-}"
    [ -n "$v" ] || continue
    printf -v q '%q' "$v"
    printf '%s=%s\n' "$k" "$q"
  done
}

case "$MODE" in
  shell|--setup|--apt) ;;
  -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
  *) echo "未知参数：$MODE（可用 --setup / --apt）" >&2; exit 2 ;;
esac

[ -f "$SETUP" ] || { echo "找不到 $SETUP" >&2; exit 1; }

NAME="${HOST_USER}_$(openssl rand -base64 8 | md5sum | cut -c1-8)"
CONTAINER=""

on_error(){
  printf '\n[x] 执行失败。容器 %s 仍保留，可进入排障：\n' "$NAME" >&2
  printf '    docker exec -it -u 0 %s /bin/bash\n' "$NAME" >&2
  printf '    docker exec -it -u 0 %s su - %s\n' "$NAME" "$HOST_USER" >&2
}
trap on_error ERR

# 1) 后台启动容器：日常 shell 由后面的 docker exec 进入
#    --user/--entrypoint 让自制镜像即使默认非 root 或带 ENTRYPOINT 也能常驻；
#    root 操作用下面的 docker exec -u 0。
docker run -d --net=host -h "$HNAME" --name "$NAME" \
  --user 0:0 --entrypoint /bin/sleep \
  -v "/home/$HOST_USER:/home/$HOST_USER" -w "/home/$HOST_USER" \
  "$IMAGE" infinity >/dev/null
CONTAINER="$NAME"

# 2) root：创建与宿主机同 UID/GID 的用户（镜像已有同名用户时跳过并校验）
docker exec -u 0 "$CONTAINER" /bin/bash -c "
  set -e
  if ! getent group '$HOST_USER' >/dev/null 2>&1; then
    groupadd -g $HOST_GID '$HOST_USER'
  else
    cur_gid=\$(getent group '$HOST_USER' | cut -d: -f3)
    if [ \"\$cur_gid\" != '$HOST_GID' ]; then
      echo \"[x] 镜像内已有组 $HOST_USER，但 GID=\$cur_gid，宿主为 $HOST_GID\" >&2
      exit 1
    fi
  fi
  if ! id -u '$HOST_USER' >/dev/null 2>&1; then
    useradd -d /home/$HOST_USER -s /bin/bash -g '$HOST_USER' -u $HOST_UID '$HOST_USER'
  else
    cur_uid=\$(id -u '$HOST_USER'); cur_gid=\$(id -g '$HOST_USER')
    if [ \"\$cur_uid\" != '$HOST_UID' ] || [ \"\$cur_gid\" != '$HOST_GID' ]; then
      echo \"[x] 镜像内已有用户 $HOST_USER，但 UID:GID=\$cur_uid:\$cur_gid，宿主为 $HOST_UID:$HOST_GID\" >&2
      exit 1
    fi
  fi
"

# 3) 把宿主机上的镜像/版本变量写进容器，供 root 和普通用户两个阶段复用
env_file_contents | docker exec -i -u 0 "$CONTAINER" /bin/bash -c "
  set -e
  cat > $ENV_FILE
  chown $HOST_UID:$HOST_GID $ENV_FILE
  chmod 600 $ENV_FILE
"

# 4) root：只装系统依赖（curl / git / 编译工具 / musl 等）
if [ "$MODE" = "--setup" ] || [ "$MODE" = "--apt" ]; then
  echo "[1/2] root 安装系统依赖 ..."
  docker exec -u 0 "$CONTAINER" /bin/bash -c \
    "set -a; . $ENV_FILE; set +a; APT_ONLY=1 bash '$SETUP'"
fi

# 5) 普通用户：装所有 home 内的开发工具
if [ "$MODE" = "--setup" ]; then
  echo "[2/2] 普通用户 $HOST_USER 安装开发工具 ..."
  docker exec -u 0 "$CONTAINER" /bin/bash -c \
    "su - '$HOST_USER' -c 'set -a; . $ENV_FILE; set +a; SKIP_APT=1 bash $SETUP'"
fi

echo
echo "容器名：$NAME"
echo "进入普通用户：docker exec -it -u 0 $NAME su - $HOST_USER"
echo "清理：docker exec -it -u 0 $NAME su - $HOST_USER -c 'bash $CLEANUP'"
echo

# 6) 进入普通用户 shell（只在交互终端下自动进入）
if [ -t 0 ] && [ -t 1 ]; then
  exec docker exec -it -u 0 "$CONTAINER" su - "$HOST_USER"
fi
echo "当前不是交互终端，已跳过自动进入 shell。"
echo "进入普通用户：docker exec -it -u 0 $NAME su - $HOST_USER"
