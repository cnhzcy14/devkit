#!/usr/bin/env bash
# ============================================================================
# setup-ubuntu.sh — 共享 home 开发工具母机（Ubuntu 20.04/22.04 容器内运行）
# ----------------------------------------------------------------------------
# 设计目标
#   * 在官方 ubuntu:20.04/22.04 容器里，把通用工具装进共享 home，其他容器直接复用；
#   * Rust 工具全部编译为 x86_64-unknown-linux-musl 静态二进制，任何 glibc 容器可跑；
#   * Neovim 在构建容器内源码编译（20.04→glibc 2.31，22.04→glibc 2.35）；
#   * hunk / Trellis 走 Node + npm，Python 由 uv 托管 3.12；
#   * 所有制品集中在 ~/.devkit，便于 devkit-cleanup.sh 完整删除；
#   * .bashrc 只写一段带标记的块，重复执行自动替换，不碰用户其他内容；
#   * 默认全部使用国内镜像，可用 MIRROR=official 切回官方。
#
# 章节结构（函数按章节组织，实际执行顺序见文件末尾 main）：
#   1 预检与系统依赖
#   2 Rust 工具链与 CLI（musl 静态；含 uv、tree-sitter CLI、yazi、neocmakelsp、emmylua_ls）
#   3 C/C++ 工具（clangd、静态 git）
#   4 Neovim / LazyVim / Treesitter
#   5 Node.js 与 TS/JS 工具（hunk / Trellis / opencode）
#   6 Python 运行时与工具 venv / shim
#   7 .bashrc 托管块
#   8 验收与清理
#
# 运行方式（ubuntu:20.04 默认无 sudo，推荐分两步）：
#   1) root 装系统依赖：
#      APT_ONLY=1 bash /home/$USER/work/project/devkit/setup-ubuntu.sh
#   2) 同名普通用户装 home 制品：
#      su - $USER -c 'SKIP_APT=1 bash /home/$USER/work/project/devkit/setup-ubuntu.sh'
#   或直接使用宿主机侧 devkit-up.sh --setup 一键完成。
#
# 常用开关：
#   MIRROR=official        整套默认源切回官方（默认 cn）
#   APT_MIRROR=...         deb 源：默认 cn(清华)；可填 ustc、off、主机名或完整 URL
#   RUSTUP_DIST_SERVER=... rustup 工具链源（默认 https://rsproxy.cn）
#   RUSTUP_UPDATE_ROOT=... rustup 自更新源（默认 $RUSTUP_DIST_SERVER/rustup）
#   RUSTUP_INIT_URL=...    rustup-init.sh 地址（默认随 RUSTUP_DIST_SERVER）
#   CARGO_REGISTRY=...     cargo 源：默认 sparse+https://rsproxy.cn/index/；
#                         填 official 用 crates.io，或公司 sparse/git 索引 URL
#   NPM_REGISTRY=...       npm 源；默认 cn=npmmirror，official=npmjs
#   NODE_DIST=...          Node tarball 根 URL；默认 cn=npmmirror，official=nodejs.org
#   PYPI_INDEX=...         uv/PyPI 源；默认 cn=清华，official 留空走 pypi.org
#   GH_MIRRORS=...         GitHub 镜像前缀（空格分隔）；none 表示只用直连
#   OPENSSL_TARBALL=...    musl 静态 OpenSSL 源码 tarball 地址（ducker 用）
#   SKIP_APT=1             跳过 apt（镜像已预装依赖）
#   FORCE_NVIM=1           重新编译 nvim
#   FORCE_TS_CLI=1         重编 tree-sitter CLI（musl 静态）
#   UPDATE_TS_PARSERS=1    安装/更新 LazyVim ensure_installed 的 Treesitter parser
#   TS_CLI_VERSION=...     tree-sitter CLI 版本（默认 0.27.2，必须 >=0.26.1）
#   FORCE_RUST_TOOLS=1     重编所有 Rust 工具
#   FORCE_LAZYVIM=1        备份旧配置并重建 LazyVim
#   WITH_OPENCODE=0        跳过 opencode（默认通过 npm 安装 @opencode/cli）
#   OPENCODE_VERSION=...   opencode 版本（默认 latest）
#   HUNK_VERSION=0.24.0    hunk 版本（0.24.1 的 linux 包尚未同步到 npmmirror）
#   YAZI_VERSION=...       yazi 版本（默认从 rsproxy 解析最新）
#   SHUCK_VERSION=...      shuck-cli 版本（默认 0.2.11）
#   STYLUA_VERSION=...     stylua 版本（默认 2.6.0）
#   NEOCMAKELSP_VERSION=... neocmakelsp 版本（默认 0.12.0）
#   EMMYLUA_VERSION=...    emmylua_ls（EmmyLua Analyzer Rust）版本（默认 0.25.1）
#   GIT_VERSION=...        静态 git 版本（默认从 kernel.org 解析最新）
#   CURL_VERSION=...       静态 libcurl 版本（默认自动；OpenSSL 1.1.1 封顶 8.17.0）
#   CLANGD_VERSION=...     clangd 版本（默认 22.1.6；置空则解析最新 release）
#   FORCE_CLANG=1          重新下载 clangd
#   FORCE_GIT=1            重新编译静态 git
#   DEVKIT_ROOT=...        自定义制品根目录（默认 ~/.devkit）
# ============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

MIRROR="${MIRROR:-cn}"
SKIP_APT="${SKIP_APT:-0}"
FORCE_NVIM="${FORCE_NVIM:-0}"
FORCE_RUST_TOOLS="${FORCE_RUST_TOOLS:-0}"
FORCE_LAZYVIM="${FORCE_LAZYVIM:-0}"
WITH_OPENCODE="${WITH_OPENCODE:-1}"
FORCE_TS_CLI="${FORCE_TS_CLI:-0}"
UPDATE_TS_PARSERS="${UPDATE_TS_PARSERS:-0}"
TS_CLI_VERSION="${TS_CLI_VERSION:-0.27.2}"
HUNK_VERSION="${HUNK_VERSION:-0.24.0}"
OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"
UV_VERSION="${UV_VERSION:-}"
GIT_VERSION="${GIT_VERSION:-}"
CURL_VERSION="${CURL_VERSION:-}"
CLANGD_VERSION="${CLANGD_VERSION:-22.1.6}"
FORCE_CLANG="${FORCE_CLANG:-0}"
FORCE_GIT="${FORCE_GIT:-0}"
SHUCK_VERSION="${SHUCK_VERSION:-0.2.11}"
STYLUA_VERSION="${STYLUA_VERSION:-2.6.0}"
NEOCMAKELSP_VERSION="${NEOCMAKELSP_VERSION:-0.12.0}"
EMMYLUA_VERSION="${EMMYLUA_VERSION:-0.25.1}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
DEVKIT_ROOT="${DEVKIT_ROOT:-$HOME/.devkit}"
APT_MIRROR="${APT_MIRROR:-}"
RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-}"
RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT:-}"
RUSTUP_INIT_URL="${RUSTUP_INIT_URL:-}"
CARGO_REGISTRY="${CARGO_REGISTRY:-}"
PY_MIRROR="${PY_MIRROR:-}"
PYPI_INDEX="${PYPI_INDEX:-}"
MUSL_PREFIX="$DEVKIT_ROOT/musl"
MUSL_BIN="$MUSL_PREFIX/bin"
UV_BIN="$MUSL_BIN/uv"

export PATH="$MUSL_BIN:$DEVKIT_ROOT/nvim/bin:$DEVKIT_ROOT/node/bin:$DEVKIT_ROOT/cargo/bin:$PATH"
export RUSTUP_HOME="$DEVKIT_ROOT/rustup"
export CARGO_HOME="$DEVKIT_ROOT/cargo"
export CC_x86_64_unknown_linux_musl="${CC_x86_64_unknown_linux_musl:-musl-gcc}"
# musl-gcc 默认不搜内核 UAPI 头；用 -idirafter 让标准头仍优先走 musl
export CFLAGS="${CFLAGS:--idirafter /usr/include -idirafter /usr/include/x86_64-linux-gnu}"
export CXXFLAGS="${CXXFLAGS:-$CFLAGS}"
export CFLAGS_x86_64_unknown_linux_musl="$CFLAGS"
export CXXFLAGS_x86_64_unknown_linux_musl="$CXXFLAGS"
export NPM_CONFIG_PREFIX="$DEVKIT_ROOT/npm-global"
export NPM_CONFIG_CACHE="$DEVKIT_ROOT/cache/npm"
export UV_PYTHON_INSTALL_DIR="$DEVKIT_ROOT/uv-python"
export UV_PYTHON_BIN_DIR="$DEVKIT_ROOT/python-bin"
export UV_PYTHON_INSTALL_BIN=1
export UV_CACHE_DIR="$DEVKIT_ROOT/cache/uv"
export UV_TOOL_DIR="$DEVKIT_ROOT/uv-tools"
export UV_TOOL_BIN_DIR="$DEVKIT_ROOT/uv-tool-bin"

STATE_DIR="$DEVKIT_ROOT/state"
BACKUP_DIR="$DEVKIT_ROOT/backups"
NVIM_SRC="$DEVKIT_ROOT/src/neovim"
NVIM_PREFIX="$DEVKIT_ROOT/nvim"
NODE_PREFIX="$DEVKIT_ROOT/node"
NPM_PREFIX="$DEVKIT_ROOT/npm-global"
VENV_DIR="$DEVKIT_ROOT/venvs"
SHIM_DIR="$DEVKIT_ROOT/shims"
OPENSSL_MUSL="$DEVKIT_ROOT/openssl-musl"
CLANG_PREFIX="$DEVKIT_ROOT/clang"
GIT_PREFIX="$DEVKIT_ROOT/git"
NEOCMAKELSP_BIN="$MUSL_BIN/neocmakelsp"
EMMYLUA_BIN="$MUSL_BIN/emmylua_ls"
MUSL_TARGET="x86_64-unknown-linux-musl"
NVIM_CONFIG="$HOME/.config/nvim"

if [ "$MIRROR" = "cn" ]; then
  if [ -z "${GH_MIRRORS:-}" ]; then
    GH_MIRRORS=("https://ghfast.top/" "https://gh-proxy.com/")
  elif [ "${GH_MIRRORS}" = "none" ]; then
    GH_MIRRORS=("")
  else
    read -r -a GH_MIRRORS <<< "${GH_MIRRORS}"
  fi
  : "${APT_MIRROR:=cn}"
  : "${RUSTUP_DIST_SERVER:=https://rsproxy.cn}"
  : "${CARGO_REGISTRY:=sparse+https://rsproxy.cn/index/}"
  NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
  NODE_DIST="${NODE_DIST:-https://npmmirror.com/mirrors/node}"
  : "${PY_MIRROR:=https://mirrors.nju.edu.cn/github-release/astral-sh/python-build-standalone}"
  : "${PYPI_INDEX:=https://pypi.tuna.tsinghua.edu.cn/simple}"
  : "${OPENSSL_TARBALL:=https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/main/o/openssl/openssl_1.1.1f.orig.tar.gz}"

  # 国内镜像在部分办公网/代理环境下不可达：逐个探测，不通就自动回退官方源。
  probe(){
    curl -fsS -o /dev/null --max-time 6 "$1" 2>/dev/null
  }
  fallback_note(){ MIRROR_FALLBACKS+=("$*"); }
  if ! probe "https://rsproxy.cn/"; then
    fallback_note "rsproxy.cn 不可达，rustup/cargo 回退官方源"
    RUSTUP_DIST_SERVER="https://static.rust-lang.org"
    RUSTUP_UPDATE_ROOT="https://static.rust-lang.org/rustup"
    RUSTUP_INIT_URL="https://sh.rustup.rs"
    CARGO_REGISTRY="official"
  fi
  if ! probe "https://registry.npmmirror.com/-/binary/node/"; then
    fallback_note "npmmirror 不可达，npm/Node 回退官方源"
    NPM_REGISTRY="https://registry.npmjs.org"
    NODE_DIST="https://nodejs.org/dist"
  fi
  if ! probe "https://mirrors.nju.edu.cn/"; then PY_MIRROR=""; fi
  if ! probe "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/"; then
    OPENSSL_TARBALL="https://www.openssl.org/source/openssl-1.1.1f.tar.gz"
  fi
  if ! probe "https://pypi.tuna.tsinghua.edu.cn/simple/"; then
    fallback_note "清华 PyPI 不可达，uv 回退 pypi.org"
    PYPI_INDEX=""
  fi
  if ! probe "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"; then
    [ -n "${APT_MIRROR:-}" ] || APT_MIRROR=off
    fallback_note "清华 apt 源不可达，保留镜像自带 apt 源"
  fi
else
  if [ -z "${GH_MIRRORS:-}" ] || [ "${GH_MIRRORS}" = "none" ]; then
    GH_MIRRORS=("")
  else
    read -r -a GH_MIRRORS <<< "${GH_MIRRORS}"
  fi
  : "${APT_MIRROR:=off}"
  : "${RUSTUP_DIST_SERVER:=https://static.rust-lang.org}"
  : "${CARGO_REGISTRY:=official}"
  NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
  NODE_DIST="${NODE_DIST:-https://nodejs.org/dist}"
  PY_MIRROR="${PY_MIRROR:-}"
  : "${OPENSSL_TARBALL:=https://www.openssl.org/source/openssl-1.1.1f.tar.gz}"
fi

[ "$RUSTUP_DIST_SERVER" = "official" ] && RUSTUP_DIST_SERVER="https://static.rust-lang.org"
[ "$CARGO_REGISTRY" = "official" ] && CARGO_REGISTRY=""
if [ -z "$RUSTUP_UPDATE_ROOT" ]; then
  RUSTUP_UPDATE_ROOT="${RUSTUP_DIST_SERVER%/}/rustup"
fi
if [ -z "$RUSTUP_INIT_URL" ]; then
  case "$RUSTUP_DIST_SERVER" in
    https://rsproxy.cn*) RUSTUP_INIT_URL="https://rsproxy.cn/rustup-init.sh" ;;
    *) RUSTUP_INIT_URL="https://sh.rustup.rs" ;;
  esac
fi

PHASE="init"
MIRROR_FALLBACKS=()
log(){ printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
step(){ PHASE="$1"; log "───────── 阶段：$1 ─────────"; }
trap 'printf "\033[1;31m[x]\033[0m 失败于阶段 %s（约第 %d 行）。可修复后重跑（幂等）。\n" "$PHASE" "$LINENO"' ERR

as_root(){
  if [ "$(id -u)" = "0" ]; then env DEBIAN_FRONTEND=noninteractive "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo env DEBIAN_FRONTEND=noninteractive "$@"
  else die "需要 root 或 sudo：$*"
  fi
}

# GitHub 直连失败时依次尝试镜像前缀
gh_url(){
  local u="$1" out="$2" m
  curl -fSL --retry 2 --connect-timeout 8 -o "$out" "$u" && return 0
  for m in "${GH_MIRRORS[@]}"; do
    [ -n "$m" ] || continue
    curl -fSL --retry 2 --connect-timeout 8 -o "$out" "${m}${u}" && return 0
  done
  return 1
}
gh_clone(){
  local u="$1" dir="$2"; shift 2
  local m
  rm -rf "$dir"
  git clone --depth 1 "$u" "$dir" "$@" && return 0
  case "$u" in
    https://github.com/*) ;;
    *) return 1 ;;
  esac
  for m in "${GH_MIRRORS[@]}"; do
    [ -n "$m" ] || continue
    rm -rf "$dir"
    git clone --depth 1 "${m}${u}" "$dir" "$@" && return 0
  done
  return 1
}
is_static(){
  local b="$1"
  # static-PIE 在 file 里也可能显示 dynamically linked，但不会带 PT_INTERP
  readelf -l "$b" 2>/dev/null | grep -q 'INTERP' && return 1
  ldd "$b" 2>&1 | grep -qE '=>|ld-linux|ld-musl' && return 1
  return 0
}
runtime_ok(){
  local b="$1" out rc
  if out=$("$b" --version 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -ge 128 ] && return 1
  return 0
}
state_set(){
  mkdir -p "$STATE_DIR"; touch "$STATE_DIR/setup.env"
  local key="$1" val="$2" tmp="$STATE_DIR/setup.env.tmp"
  grep -v "^${key}=" "$STATE_DIR/setup.env" > "$tmp" || true
  printf '%s=%q\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$STATE_DIR/setup.env"
}
state_set_once(){
  [ -f "$STATE_DIR/setup.env" ] && grep -q "^$1=" "$STATE_DIR/setup.env" && return 0
  state_set "$1" "$2"
}
state_get(){ [ -f "$STATE_DIR/setup.env" ] || return 1; . "$STATE_DIR/setup.env"; eval "printf '%s' \"\${$1:-}\""; }
backup_path(){
  mkdir -p "$BACKUP_DIR"
  printf '%s/%s-%s' "$BACKUP_DIR" "$1" "$(date +%F-%H%M%S)"
}

# ============================================================================
# 1. 预检与系统依赖
# ============================================================================
preflight(){
  step "预检"
  local m
  for m in ${MIRROR_FALLBACKS+"${MIRROR_FALLBACKS[@]}"}; do warn "$m"; done
  [ -r /etc/os-release ] || die "无法识别系统"
  . /etc/os-release
  log "系统：${ID:-?} ${VERSION_ID:-?}  架构：$(uname -m)"
  if [ ! -e /.dockerenv ] && [ ! -e /run/.containerenv ]; then
    die "setup-ubuntu.sh 只允许在 Ubuntu 容器内运行，宿主机只负责启动容器。
请用: ./devkit-up.sh --setup
或先 docker run 一个 Ubuntu 容器，再进入容器执行本脚本。"
  fi
  [ "${ID:-}" = "ubuntu" ] || die "需要 Ubuntu 容器，当前是 ${ID:-?} ${VERSION_ID:-?}"
  [ "$(uname -m)" = "x86_64" ] || die "本脚本目前只支持 x86_64"
  if [ "${VERSION_ID:-}" != "20.04" ]; then
    warn "推荐在 ubuntu:20.04 中运行；当前版本编译的 nvim 兼容基线会变高"
  fi
  if [ "${APT_ONLY:-0}" != "1" ]; then
    mkdir -p "$DEVKIT_ROOT" "$STATE_DIR" "$BACKUP_DIR"
  fi
  if [ "$(id -u)" = "0" ] && [ "${APT_ONLY:-0}" != "1" ]; then
    die "完整安装禁止以 root 运行；root 只用于 APT_ONLY=1。请用: su - <同名普通用户> -c 'SKIP_APT=1 bash ...'"
  fi
  if [ "$SKIP_APT" != "1" ] && [ "$(id -u)" != "0" ] \
     && ! command -v sudo >/dev/null 2>&1; then
    warn "当前用户没有 sudo，apt 阶段可能失败；可 SKIP_APT=1"
  fi
  if [ "${APT_ONLY:-0}" != "1" ] && [ -d "$DEVKIT_ROOT" ]; then
    local bad
    bad=$(find "$DEVKIT_ROOT" ! -user "$(id -u)" -print -quit 2>/dev/null || true)
    if [ -n "$bad" ]; then
      die "发现非当前用户属主的制品：$bad
请先修正属主再重跑：sudo chown -R $(id -u):$(id -g) \"$DEVKIT_ROOT\"
（或运行 devkit-cleanup.sh 后重装）"
    fi
  fi
  if [ "${APT_ONLY:-0}" != "1" ]; then touch "$STATE_DIR/setup.env"; fi
}

apt_mirror_base(){
  case "$APT_MIRROR" in
    ""|off) return 1 ;;
    cn|tuna) printf 'http://mirrors.tuna.tsinghua.edu.cn/ubuntu' ;;
    ustc)   printf 'http://mirrors.ustc.edu.cn/ubuntu' ;;
    official) return 1 ;;  # 保留镜像自带官方源，不替换
    http://*|https://*) printf '%s' "${APT_MIRROR%/}" ;;
    *)      printf 'http://%s/ubuntu' "${APT_MIRROR%/}" ;;
  esac
}

apt_set_mirror(){
  local base="$1"
  # 20.04 基础镜像默认没有 ca-certificates；首次装依赖先用 HTTP 落地证书
  if ! as_root test -f /etc/ssl/certs/ca-certificates.crt; then
    base="${base/#https:\/\//http://}"
  fi
  # 把 sources.list 里任意 ubuntu 仓库基址（官方或别的镜像）整体替换为目标源
  as_root bash -c "set -e; f=/etc/apt/sources.list; cp -n \"\$f\" \"\$f.devkit.bak\" 2>/dev/null || true;
    sed -ri 's#(https?://[^ /]+(/[^ /]+)*?)/ubuntu#${base}#g' \"\$f\"
    for x in /etc/apt/sources.list.d/*.list; do [ -f \"\$x\" ] || continue;
      sed -ri 's#(https?://[^ /]+(/[^ /]+)*?)/ubuntu#${base}#g' \"\$x\"; done"
}

apt_phase(){
  step "apt 依赖"
  if [ "$SKIP_APT" = "1" ]; then warn "SKIP_APT=1，跳过"; return 0; fi
  local base=""
  base=$(apt_mirror_base) || true
  if [ -n "$base" ] && as_root grep -qE 'archive|security\.ubuntu\.com' /etc/apt/sources.list 2>/dev/null; then
    log "apt 源 → $base"
    apt_set_mirror "$base"
  fi
  if ! as_root apt-get update -y; then
    if [ "$APT_MIRROR" = "cn" ]; then
      warn "apt update 失败，尝试 USTC 镜像"
      apt_set_mirror "http://mirrors.ustc.edu.cn/ubuntu"
      as_root apt-get update -y
    else
      die "apt update 失败（APT_MIRROR=$APT_MIRROR），请检查源或改 APT_MIRROR=cn/off"
    fi
  fi
  as_root apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip tar gzip xz-utils file \
    build-essential cmake ninja-build gettext pkg-config perl \
    autoconf automake libtool libtool-bin \
    libncurses-dev libssl-dev zlib1g-dev libexpat1-dev libpcre2-dev linux-libc-dev \
    musl-tools musl-dev python3 python3-pip binutils libclang-dev
  [ -x /usr/bin/musl-gcc ] || die "musl-gcc 未安装成功"
  log "apt 依赖就绪"
}

# ============================================================================
# 2. Rust 工具链与 CLI（musl 静态）
# ============================================================================
# ---------------------------- 2.1 rustup 与 musl 工具链 --------------------
rust_phase(){
  step "Rust musl 工具链"
  if [ -x "$CARGO_HOME/bin/rustup" ]; then
    log "rustup 已存在：$("$CARGO_HOME/bin/rustup" --version | head -1)"
  else
    export RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT
    curl -fsSL --retry 3 "$RUSTUP_INIT_URL" -o /tmp/rustup-init.sh
    sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain stable --no-modify-path
  fi
  "$CARGO_HOME/bin/rustup" target add "$MUSL_TARGET"
  mkdir -p "$CARGO_HOME"
  # 不要指定 linker=musl-gcc：Ubuntu 20.04 的 musl 1.1.24 与 Rust 自包含 musl
  # 不兼容，会生成启动即 SIGSEGV 的二进制。交给 Rust 自己的 musl 链接即可。
  {
    printf '%s\n' '# >>> devkit (setup-ubuntu.sh) >>>'
    if [ -n "$CARGO_REGISTRY" ]; then
      cat <<EOF
[source.crates-io]
replace-with = "devkit-mirror"
[source.devkit-mirror]
registry = "$CARGO_REGISTRY"
EOF
    fi
    cat <<EOF
[net]
git-fetch-with-cli = true
[target.$MUSL_TARGET]
rustflags = ["-C", "target-feature=+crt-static"]
# <<< devkit (setup-ubuntu.sh) <<<
EOF
  } > "$CARGO_HOME/config.toml"
  log "rustup dist：$RUSTUP_DIST_SERVER"
  log "cargo 源：${CARGO_REGISTRY:-crates.io（official）}"
  log "cargo/rustc：$("$CARGO_HOME/bin/rustc" --version)（目标 $MUSL_TARGET）"
}

# 为 ducker 准备 musl 静态 OpenSSL（openssl-sys 需要 OPENSSL_STATIC）
ensure_musl_openssl(){
  [ -f "$OPENSSL_MUSL/lib/libssl.a" ] && return 0
  step "编译 musl 静态 OpenSSL"
  mkdir -p "$OPENSSL_MUSL"
  rm -rf /tmp/devkit-openssl
  mkdir -p /tmp/devkit-openssl
  local tar=/tmp/devkit-openssl/openssl.tar.gz
  # 先用配置的源；失败再依次试官方站与 GitHub（镜像不通时仍能完成）
  curl -fSL --retry 3 -o "$tar" "$OPENSSL_TARBALL" \
    || curl -fSL --retry 3 -o "$tar" "https://www.openssl.org/source/openssl-1.1.1f.tar.gz" \
    || curl -fSL --retry 3 -o "$tar" "https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1f/openssl-1.1.1f.tar.gz" \
    || die "OpenSSL 源码下载失败（OPENSSL_TARBALL=$OPENSSL_TARBALL）"
  tar -xzf "$tar" -C /tmp/devkit-openssl --strip-components=1 \
    || die "OpenSSL 源码解压失败（下载内容不是 tar.gz）"
  cd /tmp/devkit-openssl
  CFLAGS="-idirafter /usr/include -idirafter /usr/include/x86_64-linux-gnu" \
  CC=musl-gcc AR=ar RANLIB=ranlib ./Configure --prefix="$OPENSSL_MUSL" --libdir=lib \
    no-shared no-tests no-asm no-zlib linux-x86_64
  make -j"$(nproc)"
  make install_sw
  cd - >/dev/null
  rm -rf /tmp/devkit-openssl
  [ -f "$OPENSSL_MUSL/lib/libssl.a" ] || die "musl OpenSSL 编译失败"
  log "musl OpenSSL → $OPENSSL_MUSL"
}

# uv 是 Rust 编写的 musl 静态工具，因此和 Rust CLI 一起安装到 musl/bin。
install_uv_binary(){
  local dest="$UV_BIN" destx="$MUSL_BIN/uvx" tag asset url tmpd uv_bin uvx_bin
  if [ -x "$dest" ] && [ -x "$destx" ] && [ "$FORCE_RUST_TOOLS" != "1" ] \
     && "$dest" --version 2>/dev/null | grep -q 'linux-musl'; then
    log "uv 已存在，跳过（FORCE_RUST_TOOLS=1 重装）"
  else
    tag="${UV_VERSION#v}"
    if [ -z "$tag" ]; then
      tag=$(curl -fsSL --max-time 20 https://api.github.com/repos/astral-sh/uv/releases/latest 2>/dev/null \
            | sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p' | head -1 || true)
    fi
    [ -n "$tag" ] || tag="0.13.7"
    asset="uv-x86_64-unknown-linux-musl.tar.gz"
    url="https://github.com/astral-sh/uv/releases/download/$tag/$asset"
    tmpd=$(mktemp -d) || return 1
    if ! gh_url "$url" "$tmpd/$asset"; then rm -rf "$tmpd"; return 1; fi
    tar -xzf "$tmpd/$asset" -C "$tmpd" || { rm -rf "$tmpd"; return 1; }
    uv_bin=$(find "$tmpd" -type f -name uv | head -1)
    uvx_bin=$(find "$tmpd" -type f -name uvx | head -1)
    [ -n "$uv_bin" ] && [ -n "$uvx_bin" ] || { rm -rf "$tmpd"; return 1; }
    install -m 0755 "$uv_bin" "$dest"
    install -m 0755 "$uvx_bin" "$destx"
    rm -rf "$tmpd"
    # 旧版本曾把 uv 放在 ~/.devkit/bin；迁移后删除，避免两份。
    rm -f "$DEVKIT_ROOT/bin/uv" "$DEVKIT_ROOT/bin/uvx"
    log "uv musl 静态包安装完成：$(basename "$url")"
  fi
  [ -x "$dest" ] || { warn "uv 未生成"; return 1; }
  is_static "$dest" || { warn "uv 不是静态链接：$(file "$dest")"; return 1; }
  "$dest" --version 2>/dev/null | grep -q 'linux-musl' \
    || { warn "uv 不是 linux-musl 版本：$("$dest" --version 2>&1 | head -1)"; return 1; }
  log "uv 静态校验通过：$("$dest" --version | head -1)"
}

# ---------------------------- 2.2 Rust CLI 工具 -----------------------------
# 格式：crate|binary|额外环境（none|openssl）
RUST_TOOLS=(
  # 格式：crate|binary|额外环境（none|openssl）|features|version
  "keifu|keifu|none||"
  "gitui|gitui|none||"
  "skim|sk|none||"
  "ducker|ducker|openssl||"
  "eza|eza|none||"
  "bat|bat|none||"
  "ripgrep|rg|none||"
  "fd-find|fd|none||"
  # bottom 默认 deploy 包含 nvidia；NVML 只支持 glibc，故关闭 nvidia，
  # 但保留 gpu 以启用 Linux 上的 AMD/Intel GPU 监控。
  "bottom|btm|none|battery,zfs,gpu|"
  "zoxide|zoxide|none||"
  "shuck-cli|shuck|none||$SHUCK_VERSION"
  "stylua|stylua|none||$STYLUA_VERSION"
)

install_rust_tool(){
  local crate="$1" bin="$2" kind="$3" feat="${4:-}" ver="${5:-}"
  local dest="$MUSL_BIN/$2" envs=() force=() feats=() vargs=()
  [ -n "$ver" ] && vargs=(--version "$ver")
  if [ -x "$dest" ] && [ "$FORCE_RUST_TOOLS" != "1" ]; then
    log "$bin 已存在，跳过（FORCE_RUST_TOOLS=1 重编）"
  else
    [ "$FORCE_RUST_TOOLS" = "1" ] && force=(--force)
    if [ -n "$feat" ]; then feats=(--no-default-features --features "$feat"); fi
    if [ "$kind" = "openssl" ]; then
      ensure_musl_openssl
      envs=(OPENSSL_DIR="$OPENSSL_MUSL" OPENSSL_STATIC=1 OPENSSL_NO_PKG_CONFIG=1)
    fi
    log "编译 $crate → $bin（musl 静态）"
    local logf=/tmp/devkit-cargo-$bin.log
    if env "${envs[@]}" "$CARGO_HOME/bin/cargo" install "${force[@]}" "${feats[@]}" "${vargs[@]}" \
         --locked --root "$MUSL_PREFIX" --target "$MUSL_TARGET" "$crate" 2>&1 | tee "$logf"; then
      :
    elif grep -qE 'no Cargo\.lock|Cargo\.lock.*not found|needs to be updated but --locked' "$logf"; then
      warn "$crate 未提供 Cargo.lock，改为不带 --locked 重试"
      env "${envs[@]}" "$CARGO_HOME/bin/cargo" install "${force[@]}" "${feats[@]}" "${vargs[@]}" \
        --root "$MUSL_PREFIX" --target "$MUSL_TARGET" "$crate" || return 1
    else
      return 1
    fi
  fi
  [ -x "$dest" ] || { warn "$bin 未生成"; return 1; }
  if ! is_static "$dest"; then
    die "$bin 不是静态链接：$(file "$dest")"
  fi
  local out rc
  if out=$("$dest" --version 2>&1); then rc=0; else rc=$?; fi
  [ "$rc" -ge 128 ] && die "$bin 运行时崩溃（退出码 $rc）：$(printf '%s' "$out" | head -1)"
  log "$bin 静态校验通过：$(printf '%s' "$out" | head -1)"
}

rust_tools_phase(){
  step "Rust 工具（musl 静态）"
  mkdir -p "$MUSL_BIN"
  local failed=() spec crate bin kind feat ver
  for spec in "${RUST_TOOLS[@]}"; do
    IFS='|' read -r crate bin kind feat ver <<< "$spec"
    if ! install_rust_tool "$crate" "$bin" "$kind" "$feat" "$ver"; then
      warn "安装失败：$crate → $bin"
      failed+=("$crate")
    fi
  done
  if ! install_uv_binary; then
    warn "安装失败：uv（Rust musl 静态）"
    failed+=("uv")
  fi
  if [ "${#failed[@]}" -gt 0 ]; then
    die "以下 Rust 工具安装失败：${failed[*]}"
  fi
  for bin in rg fd btm; do
    printf '%-56s %s\n' "$MUSL_BIN/$bin" "$(file "$MUSL_BIN/$bin" | cut -d: -f2-)"
  done
  log "Rust 工具全部就绪"
}

# ---------------------------- 2.3 yazi / ya --------------------------------
yazi_version(){
  local v idx=""
  case "$CARGO_REGISTRY" in
    sparse+http*) idx="${CARGO_REGISTRY#sparse+}" ;;
    "") idx="https://index.crates.io/" ;;
  esac
  if [ -n "$idx" ]; then
    idx="${idx%/}/"
    v=$(curl -fsSL --max-time 20 "${idx}ya/zi/yazi-fm" 2>/dev/null \
        | tail -1 | sed -n 's/.*"vers":"\([^"]*\)".*/\1/p' || true)
  fi
  [ -n "$v" ] || v="${YAZI_VERSION:-26.5.6}"
  printf '%s' "$v"
}

install_yazi(){
  local ver tag dest_yazi="$MUSL_BIN/yazi" dest_ya="$MUSL_BIN/ya"
  if [ -x "$dest_yazi" ] && [ -x "$dest_ya" ] && [ "$FORCE_RUST_TOOLS" != "1" ]; then
    log "yazi/ya 已存在，跳过（FORCE_RUST_TOOLS=1 重装）"
    return 0
  fi
  ver=$(yazi_version); tag="v$ver"
  log "yazi 版本：$tag"

  # 优先官方 musl 预编译包（GitHub release 经镜像）
  local tmpd asset url
  tmpd=$(mktemp -d) || return 1
  for asset in "yazi-x86_64-unknown-linux-musl.zip" "yazi-x86_64-unknown-linux-musl.tar.gz"; do
    url="https://github.com/sxyazi/yazi/releases/download/$tag/$asset"
    if gh_url "$url" "$tmpd/$asset"; then
      log "下载预编译包：$asset"
      if [[ "$asset" == *.zip ]]; then
        unzip -q "$tmpd/$asset" -d "$tmpd/x" || { rm -rf "$tmpd"; break; }
      else
        mkdir -p "$tmpd/x"; tar -xzf "$tmpd/$asset" -C "$tmpd/x" || { rm -rf "$tmpd"; break; }
      fi
      local y a
      y=$(find "$tmpd/x" -type f -name yazi | head -1)
      a=$(find "$tmpd/x" -type f -name ya | head -1)
      if [ -n "$y" ] && [ -n "$a" ]; then
        cp -f "$y" "$dest_yazi"; cp -f "$a" "$dest_ya"
        chmod 0755 "$dest_yazi" "$dest_ya"
        if is_static "$dest_yazi" && is_static "$dest_ya" \
           && runtime_ok "$dest_yazi" && runtime_ok "$dest_ya"; then
          rm -rf "$tmpd"
          log "yazi/ya 预编译安装完成"
          return 0
        fi
        warn "预编译包不是静态链接，改源码编译"
        rm -f "$dest_yazi" "$dest_ya"
      fi
      rm -rf "$tmpd"; break
    fi
  done
  rm -rf "$tmpd"

  # 回退：从源码仓库编译（crates.io 的 yazi-fm 包缺 preset 文件）
  local src="$DEVKIT_ROOT/src/yazi"
  gh_clone "https://github.com/sxyazi/yazi.git" "$src" --branch "$tag" \
    || gh_clone "https://github.com/sxyazi/yazi.git" "$src" --branch main \
    || gh_clone "https://gitee.com/mirrors/yazi.git" "$src" --branch "$tag" \
    || gh_clone "https://gitee.com/mirrors/yazi.git" "$src" --branch main \
    || die "yazi 源码克隆失败"
  log "源码编译 yazi/ya（musl 静态）"
  if ! "$CARGO_HOME/bin/cargo" build --locked --release --target "$MUSL_TARGET" \
       -p yazi-fm -p yazi-cli --manifest-path "$src/Cargo.toml"; then
    warn "locked 编译失败，去掉 --locked 重试"
    "$CARGO_HOME/bin/cargo" build --release --target "$MUSL_TARGET" \
      -p yazi-fm -p yazi-cli --manifest-path "$src/Cargo.toml" || return 1
  fi
  cp -f "$src/target/$MUSL_TARGET/release/yazi" "$dest_yazi"
  cp -f "$src/target/$MUSL_TARGET/release/ya" "$dest_ya"
  chmod 0755 "$dest_yazi" "$dest_ya"
  is_static "$dest_yazi" && is_static "$dest_ya" || die "yazi/ya 不是静态链接"
  runtime_ok "$dest_yazi" && runtime_ok "$dest_ya" || die "yazi/ya 运行时崩溃"
  log "yazi/ya 源码编译完成"
}

# neocmakelsp 官方只发 x86_64-unknown-linux-musl 预编译包，正好满足静态要求。
install_neocmakelsp(){
  local ver="$NEOCMAKELSP_VERSION" url tmpd asset src_bin
  if [ -x "$NEOCMAKELSP_BIN" ] && [ "$FORCE_RUST_TOOLS" != "1" ] \
     && "$NEOCMAKELSP_BIN" --version 2>/dev/null | grep -q "$ver"; then
    log "neocmakelsp 已存在，跳过"; return 0
  fi
  step "neocmakelsp $ver（musl 静态）"
  url="https://github.com/neocmakelsp/neocmakelsp/releases/download/v$ver/neocmakelsp-x86_64-unknown-linux-musl.tar.gz"
  tmpd=$(mktemp -d) || return 1
  asset="$tmpd/n.tgz"
  gh_url "$url" "$asset" || { rm -rf "$tmpd"; warn "neocmakelsp 下载失败"; return 1; }
  tar -xzf "$asset" -C "$tmpd" || { rm -rf "$tmpd"; warn "neocmakelsp 解包失败"; return 1; }
  src_bin=$(find "$tmpd" -type f -name neocmakelsp | head -1)
  [ -n "$src_bin" ] || { rm -rf "$tmpd"; warn "neocmakelsp 包结构异常"; return 1; }
  mkdir -p "$MUSL_BIN"
  install -m 0755 "$src_bin" "$NEOCMAKELSP_BIN"
  rm -rf "$tmpd"
  is_static "$NEOCMAKELSP_BIN" || die "neocmakelsp 不是静态链接"
  runtime_ok "$NEOCMAKELSP_BIN" || die "neocmakelsp 运行时崩溃"
  log "neocmakelsp → $NEOCMAKELSP_BIN"
}

# EmmyLua Analyzer Rust（emmylua_ls）官方提供 x86_64-unknown-linux-musl 静态包，
# 正好满足 devkit 的“Lua LSP 也用 Rust musl 静态”原则，替代原来的 lua-language-server。
install_emmylua(){
  local ver="${EMMYLUA_VERSION#v}" url tmpd tar src_bin
  if [ -x "$EMMYLUA_BIN" ] && [ "$FORCE_RUST_TOOLS" != "1" ] \
     && "$EMMYLUA_BIN" --version 2>/dev/null | grep -q "$ver"; then
    log "emmylua_ls 已存在，跳过"; return 0
  fi
  step "emmylua_ls $ver（EmmyLua Analyzer Rust，musl 静态）"
  url="https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases/download/$ver/emmylua_ls-linux-musl.tar.gz"
  tmpd=$(mktemp -d) || return 1
  tar="$tmpd/e.tgz"
  gh_url "$url" "$tar" || { rm -rf "$tmpd"; warn "emmylua_ls 下载失败"; return 1; }
  tar -xzf "$tar" -C "$tmpd" || { rm -rf "$tmpd"; warn "emmylua_ls 解包失败"; return 1; }
  src_bin=$(find "$tmpd" -type f -name emmylua_ls | head -1)
  [ -n "$src_bin" ] || { rm -rf "$tmpd"; warn "emmylua_ls 包结构异常"; return 1; }
  mkdir -p "$MUSL_BIN"
  install -m 0755 "$src_bin" "$EMMYLUA_BIN"
  rm -rf "$tmpd"
  is_static "$EMMYLUA_BIN" || die "emmylua_ls 不是静态链接"
  runtime_ok "$EMMYLUA_BIN" || die "emmylua_ls 运行时崩溃"
  log "emmylua_ls → $EMMYLUA_BIN"
}

# ---------------------------- 2.4 tree-sitter CLI（供 Neovim 用） ----------
ts_cli_phase(){
  step "tree-sitter CLI（musl 静态）"
  mkdir -p "$MUSL_BIN"
  local real="$MUSL_BIN/tree-sitter.real" wrap="$MUSL_BIN/tree-sitter"
  local installed=""
  if [ -x "$real" ] && [ "$FORCE_TS_CLI" != "1" ]; then
    installed=$("$real" --version 2>/dev/null | head -1 || true)
  fi
  if [ -n "$installed" ] && [ "$installed" = "tree-sitter $TS_CLI_VERSION" ]; then
    log "$installed 已存在，跳过（FORCE_TS_CLI=1 重编）"
  else
    local llvm_lib musl_inc gcc_inc
    llvm_lib=$(compgen -G '/usr/lib/llvm-*/lib/libclang.so*' 2>/dev/null | head -1 || true)
    [ -n "$llvm_lib" ] || die "缺少 libclang；请先以 root 执行 APT_ONLY=1（包含 libclang-dev）"
    llvm_lib=$(dirname "$llvm_lib")
    musl_inc=/usr/include/x86_64-linux-musl
    gcc_inc=$(cc -print-file-name=include)
    log "编译 tree-sitter-cli $TS_CLI_VERSION → $real（约 1 分钟）"
    LIBCLANG_PATH="$llvm_lib" \
    BINDGEN_EXTRA_CLANG_ARGS_x86_64_unknown_linux_musl="-isystem $musl_inc -isystem $gcc_inc" \
    RUSTFLAGS="-C target-feature=+crt-static -C link-arg=-L/usr/lib/x86_64-linux-musl" \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=cc \
      "$CARGO_HOME/bin/cargo" install tree-sitter-cli --version "$TS_CLI_VERSION" \
        --locked --force --root "$DEVKIT_ROOT/ts-cli" --target "$MUSL_TARGET"
    install -m 0755 "$DEVKIT_ROOT/ts-cli/bin/tree-sitter" "$real"
  fi

  cat > "$wrap" <<'EOF'
#!/usr/bin/env bash
# static-musl tree-sitter cannot dlopen the parser it just built.
set -u
real="$(dirname "$0")/tree-sitter.real"
if [ "${1:-}" = "build" ]; then
  out="parser.so"; prev=""
  for a in "$@"; do
    if [ "$prev" = "-o" ] || [ "$prev" = "--output" ]; then out="$a"; fi
    prev="$a"
  done
  "$real" "$@"; rc=$?
  if [ "$rc" -ne 0 ] && [ -s "$out" ] && readelf -h "$out" >/dev/null 2>&1; then
    exit 0
  fi
  exit "$rc"
fi
exec "$real" "$@"
EOF
  chmod 0755 "$wrap"
  is_static "$real" || die "tree-sitter CLI 不是静态链接：$(file "$real")"
  "$wrap" --version
  log "tree-sitter CLI 静态校验通过"
}

# ============================================================================
# 3. C/C++ 工具（clangd、静态 git）
# ============================================================================
# * clangd 是官方包，libstdc++ 等已静态链接，只依赖系统 glibc（官方保证 2.18+），
#   20.04 母机可直接运行；LSP、内置 clang-format、内置 clang-tidy 都由它提供。
# * 暂不安装独立的 clang-format / clang-tidy：LazyVim 保存时走 clangd 的 LSP
#   格式化（lsp_format = "fallback"），诊断走 clangd --clang-tidy；命令行/CI
#   需要时再单独装。
# * git：源码编译为静态 + HTTPS，替代上游 static-git（那个没有 libcurl，
#   无法 clone https:// 仓库，opencode 不可用）。
# TLS 与 https 传输都静态链入，避免依赖各宿主机/容器的 libcurl 版本。

CLANG_TOOLS_BIN="$CLANG_PREFIX/bin"
CLANG_RESOURCE_DIR="$CLANG_PREFIX/lib/clang"
GIT_BIN="$GIT_PREFIX/bin/git"

# clangd 官方发布（libstdc++ 静态，glibc 2.18+）
CLANGD_BASE="https://github.com/clangd/clangd/releases/download"

latest_clangd_version(){
  local v
  v=$(curl -fsSL --max-time 25 "https://api.github.com/repos/clangd/clangd/releases/latest" 2>/dev/null \
      | sed -n 's/^\s*"tag_name": *"\([0-9][0-9.]*\)".*/\1/p' | head -1 || true)
  [ -n "$v" ] || v="$CLANGD_VERSION"
  printf '%s' "$v"
}

# 下载并安全解包一个 zip/tar 到目标目录（先解到临时目录，成功后再替换）
install_clangd(){
  local ver="${CLANGD_VERSION:-}" name zip tmp
  [ -n "$ver" ] || ver=$(latest_clangd_version)
  [ -n "$ver" ] || { warn "无法解析 clangd 版本"; return 1; }
  compgen -G "$CLANG_TOOLS_BIN/clangd" >/dev/null && [ "$FORCE_CLANG" != "1" ] \
    && "$CLANG_TOOLS_BIN/clangd" --version 2>/dev/null | grep -q "clangd version $ver" \
    && { log "clangd 已存在：$("$CLANG_TOOLS_BIN/clangd" --version | head -1)"; return 0; }
  step "clangd $ver（官方包，libstdc++ 静态 / glibc 2.18+）"
  name="clangd-linux-$ver.zip"
  zip="/tmp/devkit-clangd-$ver.zip"
  gh_url "$CLANGD_BASE/$ver/$name" "$zip" || { warn "clangd 下载失败"; return 1; }
  tmp=$(mktemp -d)
  unzip -q -o "$zip" -d "$tmp" || { warn "clangd 解包失败"; rm -rf "$tmp" "$zip"; return 1; }
  local src="$tmp/clangd_$ver"
  [ -x "$src/bin/clangd" ] || { warn "clangd 包结构异常"; rm -rf "$tmp" "$zip"; return 1; }
  mkdir -p "$CLANG_TOOLS_BIN" "$CLANG_RESOURCE_DIR"
  # 包内 lib/clang/<ver> 提供 clang 内置头（stddef.h 等），clangd 内置头需要
  install -m 0755 "$src/bin/clangd" "$CLANG_TOOLS_BIN/clangd"
  if [ -d "$src/lib/clang" ]; then
    cp -a "$src/lib/clang/." "$CLANG_RESOURCE_DIR/"
  fi
  rm -rf "$tmp" "$zip"
  log "clangd → $CLANG_TOOLS_BIN/clangd"
}

clang_phase(){
  step "C/C++ LSP（clangd）"
  install_clangd || { warn "clangd 安装失败（C/C++ LSP 不可用）"; return 1; }
  [ -x "$CLANG_TOOLS_BIN/clangd" ] || { warn "clangd 缺失"; return 1; }
  # 旧版本装过独立的 clang-format / clang-tidy；现在格式化与诊断统一走 clangd 内置能力。
  local stale
  for stale in clang-format clang-tidy clang-tidy.real; do
    if [ -e "$CLANG_TOOLS_BIN/$stale" ]; then
      rm -f "$CLANG_TOOLS_BIN/$stale"
      log "清理旧版独立工具：$stale（改用 clangd 内置）"
    fi
  done
  # 官方包只依赖系统 glibc（2.18+）；LSP、内置 clang-format、内置 clang-tidy 都由它提供。
  runtime_ok "$CLANG_TOOLS_BIN/clangd" \
    || warn "clangd 无法运行（检查母机 glibc 是否 >= 2.18）"
  export PATH="$CLANG_TOOLS_BIN:$PATH"
}

# git 源码编译：静态链接 + HTTP(S)。上游 static-git 关闭了 libcurl，
# 只能走 ssh/local，opencode 克隆 https 仓库会直接失败，因此自己编。
latest_git_version(){
  local v
  v=$(curl -fsSL --max-time 25 "https://www.kernel.org/pub/software/scm/git/" 2>/dev/null \
      | grep -oE 'git-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' | sed 's/^git-//; s/\.tar\.xz$//' | sort -V | tail -1 || true)
  [ -n "$v" ] || v="$GIT_VERSION"
  printf '%s' "$v"
}

# Ubuntu 自带 libcurl.a 依赖 idn2/rtmp/ssh/psl/nghttp2/brotli 等一长串静态库，
# 全静态链接不现实。自编一个只启用 OpenSSL+zlib、只要 http/https 的精简静态 libcurl。
# 保留 proxy 支持：公司内网常用 http_proxy/https_proxy，git 必须能识别。
# curl 8.18 起硬性要求 OpenSSL >= 3.0；20.04/22.04 的 1.1.1 只能用 8.17.0。
CURL_STATIC="$DEVKIT_ROOT/curl-static"
CURL_LAST_OPENSSL11="8.17.0"

resolve_curl_version(){
  local want="${1:-}" host latest
  host=$(pkg-config --modversion openssl 2>/dev/null || true)
  if [ -z "$want" ]; then
    latest=$(curl -fsSL --max-time 25 "https://curl.se/download/" 2>/dev/null \
      | grep -oE 'curl-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' | sed 's/^curl-//; s/\.tar\.gz$//' | sort -V | tail -1 || true)
    want="$latest"
  fi
  [ -n "$want" ] || { warn "无法解析 curl 版本" >&2; return 1; }
  case "$host" in
    3.*|[4-9].*) ;;
    *)
      # 宿主 OpenSSL < 3.0（或无法识别）：封顶到最后一个兼容版本
      if [ "$(printf '%s\n%s\n' "$CURL_LAST_OPENSSL11" "$want" | sort -V | head -1)" = "$CURL_LAST_OPENSSL11" ] \
         && [ "$want" != "$CURL_LAST_OPENSSL11" ]; then
        warn "宿主 OpenSSL ${host:-未知} < 3.0，curl $want 无法编译，改用 $CURL_LAST_OPENSSL11" >&2
        want="$CURL_LAST_OPENSSL11"
      fi
      ;;
  esac
  printf '%s' "$want"
}

ensure_static_libcurl(){
  local ver="" tar src="$DEVKIT_ROOT/src/curl"
  if [ -f "$CURL_STATIC/lib/libcurl.a" ] && [ "$FORCE_GIT" != "1" ]; then
    log "静态 libcurl 已存在：$CURL_STATIC/lib/libcurl.a"; return 0
  fi
  step "编译静态 libcurl（仅 HTTPS，供静态 git 使用）"
  ver=$(resolve_curl_version "${CURL_VERSION:-}") || return 1
  tar="$DEVKIT_ROOT/src/curl-$ver.tar.gz"
  mkdir -p "$(dirname "$src")"
  if [ ! -s "$tar" ]; then
    curl -fsSL --retry 3 --max-time 600 "https://curl.se/download/curl-$ver.tar.gz" -o "$tar" \
      || { warn "curl 源码下载失败"; return 1; }
  fi
  rm -rf "$src"; mkdir -p "$src"
  tar xzf "$tar" -C "$src" --strip-components=1
  (
    cd "$src"
    # 注意：老版本 curl 的 --without-ldap 不会真正关掉 LDAP 协议，必须用 --disable-ldap；
    # 否则没有 libldap 头时 make 会在 ldap.c 报错。
    if ! ./configure --prefix="$CURL_STATIC" --disable-shared --enable-static \
      --with-ssl=/usr --with-zlib=/usr \
      --without-libidn2 --without-librtmp --without-libssh --without-libssh2 \
      --without-libpsl --without-nghttp2 --without-brotli --without-zstd \
      --without-libgsasl --without-gssapi \
      --disable-ldap --disable-ldaps \
      --disable-ftp --disable-file --disable-rtsp \
      --disable-dict --disable-telnet --disable-tftp --disable-pop3 \
      --disable-imap --disable-smb --disable-smtp --disable-gopher \
      --disable-mqtt --disable-manual --disable-libcurl-option >configure.log 2>&1; then
      tail -40 configure.log; exit 1
    fi
    if ! make -j"$(nproc)" >build.log 2>&1; then
      tail -60 build.log; exit 1
    fi
    if ! make install >install.log 2>&1; then
      tail -40 install.log; exit 1
    fi
  ) || { warn "静态 libcurl 编译失败"; return 1; }
  [ -f "$CURL_STATIC/lib/libcurl.a" ] || { warn "libcurl.a 未生成"; return 1; }
  rm -rf "$src" "$tar"
  log "静态 libcurl $ver → $CURL_STATIC"
}

git_phase(){
  step "git（源码编译，静态 + HTTPS）"
  local ver="${GIT_VERSION:-}" src="$DEVKIT_ROOT/src/git" tar
  [ -n "$ver" ] || ver=$(latest_git_version)
  [ -n "$ver" ] || { warn "无法解析 git 版本"; return 1; }
  # 已装好的 git 也要进 PATH：否则后面的 LazyVim 克隆仍走系统 git。
  if [ -x "$GIT_BIN" ]; then
    export PATH="$GIT_PREFIX/bin:$PATH"
  fi
  if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
    export GIT_SSL_CAINFO="/etc/ssl/certs/ca-certificates.crt"
  fi
  if [ -x "$GIT_BIN" ] && [ "$FORCE_GIT" != "1" ] \
     && "$GIT_BIN" --version 2>/dev/null | grep -q " $ver" \
     && [ -x "$GIT_PREFIX/libexec/git-core/git-remote-https" ]; then
    log "git 已存在：$("$GIT_BIN" --version)（FORCE_GIT=1 重编）"
    return 0
  fi
  ensure_static_libcurl || { warn "跳过静态 git（缺少静态 libcurl）"; return 1; }
  log "目标版本：git $ver"
  tar="/tmp/devkit-git-$ver.tar.xz"
  if [ ! -s "$tar" ]; then
    for u in "https://www.kernel.org/pub/software/scm/git/git-$ver.tar.xz" \
             "https://mirrors.edge.kernel.org/pub/software/scm/git/git-$ver.tar.xz"; do
      curl -fsSL --retry 3 --max-time 600 "$u" -o "$tar" && break || rm -f "$tar"
    done
  fi
  [ -s "$tar" ] || { warn "git 源码下载失败；其他工具不受影响（自动克隆用系统 git）"; return 1; }
  rm -rf "$src"; mkdir -p "$src" "$(dirname "$GIT_PREFIX")"
  tar xJf "$tar" -C "$src" --strip-components=1
  # 关键参数（已实测）：
  #   * 不走 make configure：configure 的 AC_CHECK_LIB 在 -static 下链接静态 libcurl
  #     时缺少 ssl/zlib，直接把 NO_CURL=YesPlease 写进 config.mak.autogen，
  #     结果没有 git-remote-https。这里直接给 make 传参（命令行为最终值）。
  #   * CURL_LIBCURL / EXTLIBS 必须单独传；configure 会静默丢弃 LIBS=。
  #   * NO_RUST=YesPlease：git 2.56 起默认编译 Rust 组件（cargo），母机没有就失败。
  #   * -ldl -lpthread 放在最后，否则静态链接时报 pthread_create 未定义。
  local mk_args=(
    prefix="$GIT_PREFIX"
    NO_PERL=YesPlease NO_PYTHON=YesPlease NO_TCLTK=YesPlease
    NO_GETTEXT=YesPlease NO_RUST=YesPlease NO_INSTALL_HARDLINKS=YesPlease
    NO_CURL=
    CURL_CONFIG="$CURL_STATIC/bin/curl-config"
    CFLAGS="-O2 -I$CURL_STATIC/include"
    LDFLAGS="-static -L$CURL_STATIC/lib"
    CURL_LIBCURL="-L$CURL_STATIC/lib -lcurl"
    EXTLIBS="-lssl -lcrypto -lz -lexpat -lpcre2-8 -ldl -lpthread"
  )
  (
    cd "$src"
    if ! make "${mk_args[@]}" -j"$(nproc)" >build.log 2>&1; then
      tail -60 build.log; exit 1
    fi
    if ! make "${mk_args[@]}" install >install.log 2>&1; then
      tail -40 install.log; exit 1
    fi
  ) || { warn "git 静态编译失败（保留系统 git）"; return 1; }
  rm -f "$tar"
  is_static "$GIT_BIN" || die "git 不是静态链接：$(file "$GIT_BIN")"
  [ -x "$GIT_PREFIX/libexec/git-core/git-remote-https" ] \
    || die "静态 git 不含 git-remote-https（HTTPS 不可用，opencode 无法克隆仓库）"
  runtime_ok "$GIT_BIN" || die "静态 git 运行时崩溃"
  log "git → $GIT_BIN（$("$GIT_BIN" --version)）"
}

# ============================================================================
# 4. Neovim / LazyVim / Treesitter
# ============================================================================
track_nvim_dir(){
  local dir="$1" key="$2"
  if [ -e "$dir" ]; then state_set_once "$key" 0; else state_set_once "$key" 1; fi
}

# tree-sitter CLI 本身是 musl 构建，其 cc crate 会按 musl target 默认选 musl-gcc。
# nvim-treesitter 编译 parser 时继承本脚本的环境，所以必须先切到 glibc 编译器。
use_glibc_cc_for_nvim(){
  export CC=/usr/bin/cc CXX=/usr/bin/c++
  export CC_x86_64_unknown_linux_musl=/usr/bin/cc
  export CXX_x86_64_unknown_linux_musl=/usr/bin/c++
  unset CFLAGS CXXFLAGS CFLAGS_x86_64_unknown_linux_musl CXXFLAGS_x86_64_unknown_linux_musl
}

# 托管 LazyVim 配置：只对带 .devkit-managed 的配置写入，重跑幂等覆盖。
# 关闭 Mason，改用 devkit 提供的 clangd / basedpyright / emmylua_ls / shuck / stylua 等。
write_lazyvim_devkit_config(){
  local plugin_dir="$NVIM_CONFIG/lua/plugins"
  local opts_file="$NVIM_CONFIG/lua/config/options.lua"
  mkdir -p "$plugin_dir"
  cat > "$plugin_dir/devkit.lua" <<'LUA'
-- 由 devkit setup-ubuntu.sh 生成，重跑会覆盖；自定义请另建文件。
return {
  -- 关闭 Mason：LSP / formatter 统一由 devkit 安装。
  { "mason-org/mason.nvim", enabled = false },
  { "mason-org/mason-lspconfig.nvim", enabled = false },
  { "williamboman/mason.nvim", enabled = false },
  { "williamboman/mason-lspconfig.nvim", enabled = false },
  { "stevearc/conform.nvim", dependencies = {} },

  { import = "lazyvim.plugins.extras.lang.clangd" },
  { import = "lazyvim.plugins.extras.lang.cmake" },
  { import = "lazyvim.plugins.extras.lang.python" },

  {
    -- Lua LSP：用 EmmyLua Analyzer Rust（emmylua_ls）替代 lua-language-server。
    -- LazyVim 自带 lua_ls 配置，这里显式关闭，避免两个 Lua LSP 同时启动。
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        lua_ls = { enabled = false },
        emmylua_ls = {
          on_init = function(client)
            -- 项目自带 .emmyrc.json / .luarc.json 时，交给项目配置，避免覆盖。
            if client.workspace_folders then
              local path = client.workspace_folders[1].name
              if path ~= vim.fn.stdpath("config")
                and (vim.uv.fs_stat(path .. "/.emmyrc.json") or vim.uv.fs_stat(path .. "/.luarc.json")) then
                client.config.settings = {}
              end
            end
          end,
          settings = {
            emmylua = {
              -- Neovim 使用 LuaJIT；同时把 Neovim runtime 与 lazy 插件目录交给 LSP。
              runtime = { version = "LuaJIT" },
              diagnostics = { globals = { "vim" } },
              workspace = {
                library = {
                  vim.env.VIMRUNTIME,
                  vim.fn.stdpath("data") .. "/lazy",
                },
              },
            },
          },
        },
      },
    },
  },

  {
    "stevearc/conform.nvim",
    opts = {
      -- C/C++ 不配 formatter：LazyVim 默认 lsp_format = "fallback"，
      -- 保存时由 clangd 的内置 clang-format 完成格式化。
      formatters_by_ft = {
        sh = { "shuck" },
      },
      formatters = {
        shuck = { command = "shuck", args = { "format", "--stdin-filename", "$FILENAME", "-" } },
      },
    },
  },
}
LUA
  mkdir -p "$(dirname "$opts_file")"
  if [ -f "$opts_file" ]; then
    grep -q 'lazyvim_python_lsp' "$opts_file" \
      || printf '\n-- devkit: 使用 devkit 安装的 basedpyright\nvim.g.lazyvim_python_lsp = "basedpyright"\n' >> "$opts_file"
  else
    printf '%s\n' '-- devkit: 使用 devkit 安装的 basedpyright' 'vim.g.lazyvim_python_lsp = "basedpyright"' > "$opts_file"
  fi
}

# extras 引入的 cpp/cmake/ninja/rst parser 不一定是 LazyVim 默认集，sync 后补装。
ensure_lazyvim_parsers(){
  local script=/tmp/devkit-ts-extra.lua
  [ -x "$NVIM_PREFIX/bin/nvim" ] || return 0
  use_glibc_cc_for_nvim
  export PATH="$MUSL_BIN:$NVIM_PREFIX/bin:$PATH"
  cat > "$script" <<'LUA'
local TS = require("nvim-treesitter")
TS.install({ "cpp", "cmake", "ninja", "rst" }):await(function(err)
  if err then
    vim.cmd("cquit 1")
  else
    vim.cmd("qa")
  end
end)
LUA
  if "$NVIM_PREFIX/bin/nvim" --headless -c "luafile $script"; then
    log "extras parser 就绪（cpp/cmake/ninja/rst）"
  else
    warn "extras parser 未完成（可重跑脚本或手动 :TSInstall cpp cmake ninja rst）"
  fi
  rm -f "$script"
}

# ---------------------------- 4.1 Neovim（源码编译） -----------------------
latest_nvim_tag(){
  local refs tag m
  refs=$(timeout 25 git ls-remote --tags --refs https://github.com/neovim/neovim.git 2>/dev/null || true)
  if [ -z "$refs" ]; then
    for m in "${GH_MIRRORS[@]}"; do
      [ -n "$m" ] || continue
      refs=$(timeout 25 git ls-remote --tags --refs "${m}https://github.com/neovim/neovim.git" 2>/dev/null || true)
      [ -n "$refs" ] && break
    done
  fi
  tag=$(printf '%s\n' "$refs" | sed -n 's#.*refs/tags/\(v[0-9][0-9.]*\)$#\1#p' | sort -V | tail -1)
  [ -n "$tag" ] || tag="stable"
  printf '%s' "$tag"
}

preseed_nvim_deps(){
  local manifest="$NVIM_SRC/cmake.deps/deps.txt" out="$NVIM_SRC/.deps/build/downloads"
  [ -f "$manifest" ] || { warn "无 deps.txt，跳过预播种"; return 0; }
  mkdir -p "$out"
  local -A U=() H=()
  local k v name low url fn hash ok=0 bad=0
  while read -r k v; do
    [ -n "${k:-}" ] || continue
    case "$k" in
      *_URL) U["${k%_URL}"]="$v" ;;
      *_SHA256) H["${k%_SHA256}"]="$v" ;;
    esac
  done < "$manifest"
  for name in "${!U[@]}"; do
    url="${U[$name]}"; hash="${H[$name]:-}"; low="${name,,}"
    case "$url" in *'${'*|'') continue ;; esac
    fn=$(basename "${url%%\?*}"); [ -n "$fn" ] || continue
    mkdir -p "$out/$low"
    if [ -f "$out/$low/$fn" ] && { [ -z "$hash" ] || printf '%s  %s\n' "$hash" "$out/$low/$fn" | sha256sum -c >/dev/null 2>&1; }; then
      ok=$((ok+1)); continue
    fi
    if gh_url "$url" "$out/$low/$fn.part" \
       && { [ -z "$hash" ] || printf '%s  %s\n' "$hash" "$out/$low/$fn.part" | sha256sum -c >/dev/null 2>&1; }; then
      mv "$out/$low/$fn.part" "$out/$low/$fn"; ok=$((ok+1))
    else
      rm -f "$out/$low/$fn.part"; bad=$((bad+1))
    fi
  done
  log "nvim 依赖预播种：$ok 个就位，$bad 个未成（未成的由 cmake 自行下载）"
}

nvim_phase(){
  step "Neovim 最新 tag 源码编译"
  # 必须在第一次调用 nvim 之前记录目录是否已存在：nvim 自检会先创建它们，
  # 否则 cleanup 会误判为“安装前已存在”而保留 devkit 生成的插件/parser。
  track_nvim_dir "$HOME/.local/share/nvim" NVIM_DATA_CREATED
  track_nvim_dir "$HOME/.local/state/nvim" NVIM_STATE_CREATED
  track_nvim_dir "$HOME/.cache/nvim" NVIM_CACHE_CREATED
  mkdir -p "$NVIM_PREFIX" "$(dirname "$NVIM_SRC")"
  if [ -x "$NVIM_PREFIX/bin/nvim" ] && [ "$FORCE_NVIM" != "1" ] && ! grep -qa 'ld-musl' "$NVIM_PREFIX/bin/nvim"; then
    log "nvim 已存在：$("$NVIM_PREFIX/bin/nvim" --version | head -1)（FORCE_NVIM=1 重编）"
  else
    local tag; tag=$(latest_nvim_tag); log "目标 tag：$tag"
    if [ -d "$NVIM_SRC/.git" ] && [ "$FORCE_NVIM" = "1" ]; then
      git -C "$NVIM_SRC" fetch --depth 1 origin "$tag"
      git -C "$NVIM_SRC" checkout -q FETCH_HEAD
    elif [ ! -d "$NVIM_SRC/.git" ]; then
      rm -rf "$NVIM_SRC"
      gh_clone "https://github.com/neovim/neovim.git" "$NVIM_SRC" --branch "$tag" \
        || die "neovim 克隆失败（检查 GH_MIRRORS）"
    fi
    preseed_nvim_deps
    log "编译中（-j$(nproc)）"
    if ! make -C "$NVIM_SRC" CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX="$NVIM_PREFIX" -j"$(nproc)"; then
      warn "首次编译失败，清 .deps 后重试一次"
      rm -rf "$NVIM_SRC/.deps"
      make -C "$NVIM_SRC" CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX="$NVIM_PREFIX" -j"$(nproc)"
    fi
    make -C "$NVIM_SRC" CMAKE_INSTALL_PREFIX="$NVIM_PREFIX" install
    grep -qa 'ld-musl' "$NVIM_PREFIX/bin/nvim" && die "nvim 产物误为 musl 链接"
    log "nvim 安装完成：$("$NVIM_PREFIX/bin/nvim" --version | head -1)"
  fi
  "$NVIM_PREFIX/bin/nvim" --headless +qa >/dev/null 2>&1 || warn "nvim headless 自检异常"
}

# ---------------------------- 4.2 LazyVim -----------------------------------
lazyvim_phase(){
  step "LazyVim"
  local managed=0 do_sync=0
  [ -f "$NVIM_CONFIG/.devkit-managed" ] && managed=1
  if [ -d "$NVIM_CONFIG" ] && [ "$FORCE_LAZYVIM" != "1" ]; then
    if [ "$managed" = "1" ]; then
      log "$NVIM_CONFIG 是本工具安装的 LazyVim，保留"
      state_set NVIM_CONFIG_CREATED 1
      do_sync=1
    else
      warn "$NVIM_CONFIG 已存在且非本工具创建，保留不动（FORCE_LAZYVIM=1 可备份重建）"
      state_set NVIM_CONFIG_CREATED 0
      do_sync=0
    fi
  else
    if [ -d "$NVIM_CONFIG" ]; then
      local bak; bak=$(backup_path nvim)
      mv "$NVIM_CONFIG" "$bak"
      state_set NVIM_CONFIG_BACKUP "$bak"
      log "旧 nvim 配置备份 → $bak"
    fi
    mkdir -p "$(dirname "$NVIM_CONFIG")"
    gh_clone "https://github.com/LazyVim/starter.git" "$NVIM_CONFIG" \
      || die "LazyVim starter 克隆失败"
    rm -rf "$NVIM_CONFIG/.git"
    touch "$NVIM_CONFIG/.devkit-managed"
    managed=1
    # 容器内无 X11：用 OSC52 通过终端访问宿主机剪贴板
    sed -i '1i vim.g.clipboard = "osc52"' "$NVIM_CONFIG/init.lua"
    state_set NVIM_CONFIG_CREATED 1
    log "LazyVim starter 已安装到 $NVIM_CONFIG"
    do_sync=1
  fi

  if [ "$do_sync" != "1" ]; then
    log "跳过 Lazy sync（配置不属于本工具）"
    return 0
  fi
  if [ ! -x "$NVIM_PREFIX/bin/nvim" ]; then
    warn "nvim 缺失，跳过 Lazy sync"; return 0
  fi
  if [ "$managed" = "1" ]; then
    write_lazyvim_devkit_config
    log "LazyVim 托管配置：已禁用 Mason，启用 clangd/cmake/python extras"
  fi
  log "headless Lazy! sync（插件下载走 GitHub；失败可重跑续传）"
  use_glibc_cc_for_nvim
  if "$NVIM_PREFIX/bin/nvim" --headless "+Lazy! sync" +qa; then
    log "Lazy sync 完成"
    if [ "$managed" = "1" ]; then
      ensure_lazyvim_parsers
    fi
  else
    warn "Lazy sync 未完成，网络好转后重跑本脚本"
  fi
}

# ---------------------------- 4.3 Treesitter parser（glibc） ---------------
ts_parsers_phase(){
  step "Treesitter parser（glibc）"
  if [ "$UPDATE_TS_PARSERS" != "1" ]; then
    log "UPDATE_TS_PARSERS=0，跳过"
    return 0
  fi
  [ -x "$MUSL_BIN/tree-sitter.real" ] || die "tree-sitter CLI 缺失，无法更新 parser"
  [ -x "$NVIM_PREFIX/bin/nvim" ] || die "nvim 缺失，无法更新 parser"
  [ -d "$NVIM_CONFIG" ] || die "LazyVim 配置缺失，无法更新 parser"
  # tree-sitter CLI 本身是 musl 构建，必须把 target 专用编译器指向 glibc cc，
  # 否则 parser 会链接到 musl 的 libc.so，Neovim（glibc）无法 dlopen。
  use_glibc_cc_for_nvim
  export PATH="$MUSL_BIN:$NVIM_PREFIX/bin:$PATH"
  local script=/tmp/devkit-ts-update.lua
  local musl_langs="" so lang
  for so in "$HOME/.local/share/nvim/site/parser"/*.so; do
    [ -e "$so" ] || continue
    if readelf -d "$so" 2>/dev/null | grep -q 'Shared library: \[libc\.so\]'; then
      lang=$(basename "$so" .so)
      musl_langs+="\"$lang\", "
    fi
  done
  if [ -n "$musl_langs" ]; then
    warn "发现 musl 版 parser，强制用 glibc 重编：$musl_langs"
    cat > "$script" <<LUA
local TS = require("nvim-treesitter")
TS.install({ $musl_langs }, { force = true }):await(function()
  vim.cmd("qa")
end)
LUA
  else
    cat > "$script" <<'LUA'
local TS = require("nvim-treesitter")
TS.update(nil, { summary = true }):await(function()
  vim.cmd("qa")
end)
LUA
  fi
  log "headless TSUpdate（在构建容器内编译 glibc parser）"
  if "$NVIM_PREFIX/bin/nvim" --headless -c "luafile $script"; then
    log "Treesitter parser 更新完成"
  else
    warn "TSUpdate 未完成，可稍后重跑"
  fi
  rm -f "$script"
  local count
  count=$(find "$HOME/.local/share/nvim/site/parser" -maxdepth 1 -name '*.so' 2>/dev/null | wc -l)
  log "parser 数量：$count（$HOME/.local/share/nvim/site/parser）"
  local bad=0 so
  for so in "$HOME/.local/share/nvim/site/parser"/*.so; do
    [ -e "$so" ] || continue
    if readelf -d "$so" 2>/dev/null | grep -q 'Shared library: \[libc\.so\]'; then
      warn "parser 链接到 musl libc：$(basename "$so")"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ] || die "parser 的 libc 链接异常，Neovim 无法 dlopen；请检查 CC_x86_64_unknown_linux_musl"
}

# ============================================================================
# 5. Node.js 与 TS/JS 工具
# ============================================================================
# ---------------------------- 5.1 Node.js 22 LTS ---------------------------
node_phase(){
  step "Node.js 22 LTS"
  mkdir -p "$NODE_PREFIX" "$NPM_PREFIX"
  if [ -x "$NODE_PREFIX/bin/node" ]; then
    log "node 已存在：$("$NODE_PREFIX/bin/node" --version)"
  else
    local arch=x64 ver="" file="" url tmp
    [ "$(uname -m)" = "aarch64" ] && arch=arm64
    tmp=$(mktemp)
    if curl -fsSL --retry 2 --connect-timeout 8 \
      "https://registry.npmmirror.com/-/binary/node/latest-v22.x/" -o "$tmp"; then
      file=$(grep -oE "node-v22\.[0-9]+\.[0-9]+-linux-${arch}\.tar\.xz" "$tmp" | sort -uV | tail -1)
    fi
    if [ -z "$file" ]; then
      curl -fsSL --retry 2 "https://nodejs.org/dist/latest-v22.x/" -o "$tmp"
      file=$(grep -oE "node-v22\.[0-9]+\.[0-9]+-linux-${arch}\.tar\.xz" "$tmp" | head -1)
    fi
    rm -f "$tmp"
    [ -n "$file" ] || die "无法解析 Node 22 版本号"
    ver="${file#node-v}"; ver="${ver%-linux-${arch}.tar.xz}"
    url="$NODE_DIST/v${ver}/${file}"
    log "下载 $url"
    curl -fSL --retry 3 -o /tmp/devkit-node.tar.xz "$url" \
      || curl -fSL --retry 3 -o /tmp/devkit-node.tar.xz "https://nodejs.org/dist/v${ver}/${file}"
    rm -rf /tmp/devkit-node-dir; mkdir -p /tmp/devkit-node-dir
    tar -xJf /tmp/devkit-node.tar.xz -C /tmp/devkit-node-dir
    rm -rf "$NODE_PREFIX"; mv "/tmp/devkit-node-dir/node-v${ver}-linux-${arch}" "$NODE_PREFIX"
    rm -rf /tmp/devkit-node-dir /tmp/devkit-node.tar.xz
    log "node 安装完成：$("$NODE_PREFIX/bin/node" --version)"
  fi
  "$NODE_PREFIX/bin/node" -v
  "$NODE_PREFIX/bin/npm" --version
}

# ---------------------------- 5.2 npm 工具（hunk / Trellis / opencode） -----
npm_tools_phase(){
  step "hunk / Trellis"
  mkdir -p "$NPM_PREFIX" "$SHIM_DIR"
  local npm="$NODE_PREFIX/bin/npm" opts=(--global --prefix "$NPM_PREFIX"
    --registry "$NPM_REGISTRY" --no-audit --no-fund)
  export PATH="$NPM_PREFIX/bin:$PATH"

  if ! command -v hunk >/dev/null 2>&1; then
    log "安装 hunkdiff@$HUNK_VERSION"
    if ! "$npm" install "${opts[@]}" "hunkdiff@$HUNK_VERSION"; then
      warn "hunk $HUNK_VERSION 失败，尝试 0.23.0"
      "$npm" install "${opts[@]}" "hunkdiff@0.23.0" || warn "hunk 安装失败"
    fi
  fi
  if command -v hunk >/dev/null 2>&1; then
    log "hunk ✓ $(hunk --version 2>/dev/null | head -1 || echo '')"
  else
    warn "hunk 不在 PATH，检查 npm 可选平台包是否可用"
  fi

  if ! command -v trellis >/dev/null 2>&1; then
    log "安装 @mindfoldhq/trellis@latest"
    "$npm" install "${opts[@]}" "@mindfoldhq/trellis@latest" || warn "Trellis 安装失败"
  fi
  if command -v trellis >/dev/null 2>&1; then
    log "trellis ✓ $(trellis --version 2>/dev/null | head -1 || echo '')"
  else
    warn "trellis 不在 PATH"
  fi

  if [ "$WITH_OPENCODE" = "1" ]; then
    local oc="$NPM_PREFIX/bin/opencode"
    if [ -x "$oc" ] && "$oc" --version >/dev/null 2>&1; then
      log "opencode 已存在：$("$oc" --version 2>/dev/null | head -1 || echo '')"
    else
      log "安装 @opencode/cli@$OPENCODE_VERSION"
      "$npm" install "${opts[@]}" "@opencode/cli@$OPENCODE_VERSION" || warn "opencode 安装失败"
      if [ -x "$oc" ] && "$oc" --version >/dev/null 2>&1; then
        log "opencode ✓ $("$oc" --version 2>/dev/null | head -1 || echo '')"
      else
        warn "opencode 不可用，检查 npm postinstall 是否被禁用、平台包是否可用"
      fi
    fi
  fi
  log "npm 工具就绪（Python venv 与 shim 在下一阶段创建）"
}

# ============================================================================
# 6. Python 运行时与工具环境
# ============================================================================
# ---------------------------- 6.1 Python 3.12 + 工具 venv ------------------
ensure_tool_venv(){
  local name="$1"
  local py="$2"
  local venv="$VENV_DIR/$name"
  if [ -x "$venv/bin/python" ]; then
    log "$name venv 已存在：$venv"
    return 0
  fi
  log "创建 $name venv：$venv（$("$py" --version)）"
  "$UV_BIN" venv --python "$py" --seed "$venv" \
    || return 1
  [ -x "$venv/bin/python" ] || { warn "$name venv 未生成"; return 1; }
}

python_env_phase(){
  step "Python $PYTHON_VERSION + 工具专用 venv"
  mkdir -p "$UV_PYTHON_INSTALL_DIR" "$UV_PYTHON_BIN_DIR" "$VENV_DIR" "$SHIM_DIR"
  [ -x "$UV_BIN" ] || die "uv 缺失：请先执行 Rust 工具阶段（$UV_BIN）"

  # 迁移旧布局：不再向 ~/.devkit/bin 暴露 python3/python。
  rm -f "$DEVKIT_ROOT/bin/python3" "$DEVKIT_ROOT/bin/python"

  if [ -n "$PY_MIRROR" ]; then export UV_PYTHON_INSTALL_MIRROR="$PY_MIRROR"; fi
  if ! "$UV_BIN" python install "$PYTHON_VERSION"; then
    warn "uv 镜像下载失败，改试官方源"
    unset UV_PYTHON_INSTALL_MIRROR
    "$UV_BIN" python install "$PYTHON_VERSION" || die "Python $PYTHON_VERSION 安装失败"
  fi
  local py
  py=$("$UV_BIN" python find "$PYTHON_VERSION" --managed-python 2>/dev/null \
       || "$UV_BIN" python find "$PYTHON_VERSION")
  [ -x "$py" ] || die "找不到 uv 托管的 Python $PYTHON_VERSION"
  ln -sf "$py" "$UV_PYTHON_BIN_DIR/python3"
  ln -sf "$py" "$UV_PYTHON_BIN_DIR/python"
  log "Python $PYTHON_VERSION → $py（$("$py" --version)）"

  ensure_tool_venv trellis "$py" || die "Trellis venv 创建失败"
  [ "$WITH_OPENCODE" = "1" ] && { ensure_tool_venv opencode "$py" || die "opencode venv 创建失败"; }
  log "trellis venv python：$("$VENV_DIR/trellis/bin/python" --version)"
  log "Python 运行时与工具 venv 就绪"
}

# ---------------------------- 6.2 公共开发工具（uv tool） -------------------
install_uv_tool(){
  local pkg="$1" bin="$2" py="$3" exe="$UV_TOOL_BIN_DIR/$2"
  if [ -x "$exe" ] && "$exe" --version >/dev/null 2>&1; then
    log "$bin 已存在：$("$exe" --version 2>/dev/null | head -1)"
    return 0
  fi
  log "uv tool install $pkg"
  "$UV_BIN" tool install --force --python "$py" "$pkg" || return 1
  [ -x "$exe" ] || { warn "$pkg 未生成 $exe"; return 1; }
}

python_tools_phase(){
  step "公共开发工具（basedpyright / ruff）"
  [ -x "$UV_BIN" ] || die "uv 缺失：请先执行 Rust 工具阶段（$UV_BIN）"
  local py
  py=$("$UV_BIN" python find "$PYTHON_VERSION" --managed-python 2>/dev/null \
       || "$UV_BIN" python find "$PYTHON_VERSION")
  [ -x "$py" ] || die "找不到 uv 托管的 Python $PYTHON_VERSION"
  if [ -n "$PYPI_INDEX" ]; then export UV_DEFAULT_INDEX="$PYPI_INDEX"; fi
  install_uv_tool basedpyright basedpyright "$py" || die "basedpyright 安装失败"
  install_uv_tool ruff ruff "$py" || die "ruff 安装失败"
  export PATH="$UV_TOOL_BIN_DIR:$PATH"
  log "basedpyright：$("$UV_TOOL_BIN_DIR/basedpyright" --version 2>&1 | head -1)"
  log "ruff：$("$UV_TOOL_BIN_DIR/ruff" --version 2>&1 | head -1)"
}

# ---------------------------- 6.3 工具专用 shim ----------------------------
write_tool_shim(){
  local name="$1" venv="$2" real="$NPM_PREFIX/bin/$1" shim="$SHIM_DIR/$1"
  [ -e "$real" ] || { warn "$name 未安装，跳过 shim"; return 0; }
  cat > "$shim" <<EOF
#!/usr/bin/env bash
set -euo pipefail
venv="$VENV_DIR/$venv"
export VIRTUAL_ENV="\$venv"
export PATH="\$venv/bin:\$PATH"
export PYTHONNOUSERSITE=1
export PIP_REQUIRE_VIRTUALENV=1
unset PYTHONPATH PYTHONHOME
exec "$real" "\$@"
EOF
  chmod +x "$shim"
  log "shim：$name → $venv venv"
}

shims_phase(){
  step "工具专用 Python shim"
  mkdir -p "$SHIM_DIR"
  write_tool_shim trellis trellis
  [ -e "$NPM_PREFIX/bin/tl" ] && write_tool_shim tl trellis
  if [ "$WITH_OPENCODE" = "1" ]; then
    write_tool_shim opencode opencode
    [ -e "$NPM_PREFIX/bin/opencode2" ] && write_tool_shim opencode2 opencode
  fi
  log "工具 shim 就绪：$SHIM_DIR"
}

# ============================================================================
# 7. .bashrc 托管块
# ============================================================================
bashrc_phase(){
  step ".bashrc 托管块"
  local rc="$HOME/.bashrc" created=0
  if [ ! -f "$rc" ]; then touch "$rc"; created=1; fi
  state_set_once BASH_RC_CREATED "$created"
  sed -i '/^# >>> devkit (setup-ubuntu.sh) >>>/,/^# <<< devkit (setup-ubuntu.sh) <<</d' "$rc"
  cat >> "$rc" <<'EOF'
# >>> devkit (setup-ubuntu.sh) >>>
# musl 工具、node/npm、cargo、uv/Python 在宿主机和容器都可用。
# python-bin 故意不加入 PATH：每个工具通过 shim 使用自己的 venv。
if [ -d "$HOME/.devkit" ]; then
  case ":$PATH:" in *":$HOME/.devkit/shims:"*) ;; *)
    export PATH="$HOME/.devkit/shims:$HOME/.devkit/musl/bin:$HOME/.devkit/node/bin:$HOME/.devkit/npm-global/bin:$HOME/.devkit/uv-tool-bin:$HOME/.devkit/cargo/bin:$PATH" ;;
  esac
  # clangd 只依赖系统 glibc（2.18+）；放在 nvim 的 PATH 之后、系统 PATH 之前，
  # 这样 Neovim 的 C/C++ LSP 与命令行都用 devkit 这一份。
  case ":$PATH:" in *":$HOME/.devkit/clang/bin:"*) ;; *)
    export PATH="$HOME/.devkit/clang/bin:$PATH" ;;
  esac
  # 静态编译的 git（含 HTTPS 传输）：优先于发行版 git，供 opencode 等工具使用。
  case ":$PATH:" in *":$HOME/.devkit/git/bin:"*) ;; *)
    export PATH="$HOME/.devkit/git/bin:$PATH" ;;
  esac
  # 静态 OpenSSL 不带 CA 证书链；指到系统 bundle，否则 https 克隆报
  # "unable to get local issuer certificate"。只在文件存在时设置。
  [ -f /etc/ssl/certs/ca-certificates.crt ] && \
    export GIT_SSL_CAINFO="/etc/ssl/certs/ca-certificates.crt"
  export NPM_CONFIG_PREFIX="$HOME/.devkit/npm-global"
  export NPM_CONFIG_CACHE="$HOME/.devkit/cache/npm"
  export RUSTUP_HOME="$HOME/.devkit/rustup"
  export CARGO_HOME="$HOME/.devkit/cargo"
  export UV_PYTHON_INSTALL_DIR="$HOME/.devkit/uv-python"
  export UV_PYTHON_BIN_DIR="$HOME/.devkit/python-bin"
  export UV_PYTHON_INSTALL_BIN=1
  export UV_CACHE_DIR="$HOME/.devkit/cache/uv"
  export UV_TOOL_DIR="$HOME/.devkit/uv-tools"
  export UV_TOOL_BIN_DIR="$HOME/.devkit/uv-tool-bin"
fi
# Neovim 使用构建容器的 glibc 基线（20.04→2.31，22.04→2.35）：宿主与共享
# 同一 home、glibc 不低于该基线的容器都可直接使用；更老的容器不行。
case ":$PATH:" in *":$HOME/.devkit/nvim/bin:"*) ;; *)
  [ -d "$HOME/.devkit/nvim/bin" ] && export PATH="$HOME/.devkit/nvim/bin:$PATH" ;;
esac
# yazi: 用 y 启动，退出时切换到 Yazi 中最后浏览的目录（官方 Shell wrapper）
# https://yazi-rs.github.io/docs/quick-start/#shell-wrapper
function y() {
  local tmp cwd
  tmp="$(mktemp -t "yazi-cwd.XXXXXX")" || return
  command yazi "$@" --cwd-file="$tmp"
  IFS= read -r -d '' cwd < "$tmp"
  [ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd" || builtin true
  command rm -f -- "$tmp"
}
# <<< devkit (setup-ubuntu.sh) <<<
EOF
  log ".bashrc 已写入托管块（重开 shell 或 source ~/.bashrc）"
}

# ============================================================================
# 8. 验收与清理
# ============================================================================
# ---------------------------- 8.1 验收 -------------------------------------
verify_phase(){
  step "验收"
  export PATH="$UV_TOOL_BIN_DIR:$SHIM_DIR:$MUSL_BIN:$CLANG_TOOLS_BIN:$GIT_PREFIX/bin:$NVIM_PREFIX/bin:$NODE_PREFIX/bin:$NPM_PREFIX/bin:$CARGO_HOME/bin:$PATH"
  local bin p v static_ok=0 static_bad=0 other_bad=0
  printf '\n%-10s %-8s %-52s %s\n' 工具 类型 路径 版本
  for bin in keifu yazi ya gitui sk ducker eza bat rg fd btm zoxide uv uvx shuck stylua neocmakelsp emmylua_ls; do
    p=$(command -v "$bin" 2>/dev/null || true)
    if [ -n "$p" ]; then
      v=$("$p" --version 2>/dev/null | head -1 || echo '?')
      if is_static "$p"; then
        printf '\033[32m%-10s %-8s %-52s %s\033[0m\n' "$bin" static "$p" "$v"; static_ok=$((static_ok+1))
      else
        printf '\033[31m%-10s %-8s %-52s %s\033[0m\n' "$bin" 动态 "$p" "$v"; static_bad=$((static_bad+1))
      fi
    else
      printf '\033[31m%-10s %-8s %-52s %s\033[0m\n' "$bin" 缺失 - -
      static_bad=$((static_bad+1))
    fi
  done
  local other_bins="node npm hunk trellis basedpyright ruff"
  if [ "$WITH_OPENCODE" = "1" ]; then
    if [ -x "$SHIM_DIR/opencode" ]; then other_bins="$SHIM_DIR/opencode $other_bins"
    else other_bins="$NPM_PREFIX/bin/opencode $other_bins"; fi
  fi
  other_bins="nvim clangd git $other_bins"
  for bin in $other_bins; do
    p=$(command -v "$bin" 2>/dev/null || true)
    if [ -n "$p" ]; then
      v=$("$p" --version 2>/dev/null | head -1 || echo '?')
      printf '\033[32m%-10s %-8s %-52s %s\033[0m\n' "$bin" glibc "$p" "$v"
    else
      printf '\033[33m%-10s %-8s %-52s %s\033[0m\n' "$bin" 缺失 - -
      other_bad=$((other_bad+1))
    fi
  done
  local pyp="$UV_PYTHON_BIN_DIR/python3"
  if [ -x "$pyp" ]; then
    printf '\033[32m%-10s %-8s %-52s %s\033[0m\n' python3 devkit "$pyp" "$("$pyp" --version 2>&1 | head -1)"
  else
    printf '\033[33m%-10s %-8s %-52s %s\033[0m\n' python3 缺失 - -
    other_bad=$((other_bad+1))
  fi
  local plugins=0
  if [ -d "$HOME/.local/share/nvim/lazy" ]; then
    plugins=$(find "$HOME/.local/share/nvim/lazy" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  fi
  printf 'LazyVim 插件：%d 个（%s）\n' "$plugins" "$HOME/.local/share/nvim/lazy"
  [ "$plugins" -eq 0 ] && warn "LazyVim 插件尚未同步（网络恢复后重跑即可续传）"
  printf '\n制品根目录：%s\n' "$DEVKIT_ROOT"
  printf 'Rust 静态工具：%d 通过，%d 异常；其他工具缺失：%d\n' "$static_ok" "$static_bad" "$other_bad"
  if [ "$static_bad" -ne 0 ] || [ "$other_bad" -ne 0 ]; then
    die "验收未通过（见上表）"
  fi
}

# ---------------------------- 8.2 构建中间产物清理 -------------------------
# 成功验收后删除只用于构建的目录；运行时产物都在 musl/bin、nvim、node 等。
cleanup_build_artifacts_phase(){
  step "清理构建中间产物"
  local p f removed=0
  for p in "$NVIM_SRC/.deps" "$NVIM_SRC/build" \
           "$DEVKIT_ROOT/ts-cli" "$OPENSSL_MUSL" "$DEVKIT_ROOT/src/yazi" \
           "$DEVKIT_ROOT/src/git" "$CURL_STATIC" "$DEVKIT_ROOT/src/curl"; do
    [ -e "$p" ] || continue
    log "删除 $p"
    rm -rf "$p"
    removed=$((removed + 1))
  done
  # 版本化的 curl 源码包：src/curl-<ver>.tar.gz
  for f in "$DEVKIT_ROOT"/src/curl-*.tar.gz; do
    [ -e "$f" ] || continue
    log "删除 $f"
    rm -f "$f"
    removed=$((removed + 1))
  done
  if [ "$removed" -eq 0 ]; then
    log "没有需要清理的中间产物"
  else
    log "已清理 $removed 个构建目录"
  fi
}

# --------------------------------- main -------------------------------------
main(){
  preflight
  apt_phase
  if [ "${APT_ONLY:-0}" = "1" ]; then
    log "APT_ONLY=1：系统依赖已就绪，退出。请用普通用户执行完整脚本（SKIP_APT=1）"
    exit 0
  fi
  # 章节顺序：Rust → C/C++ → Neovim → TS/JS → Python
  rust_phase
  rust_tools_phase
  step "yazi / ya"
  install_yazi || die "yazi/ya 安装失败"
  install_neocmakelsp || warn "neocmakelsp 安装失败（CMake LSP 不可用）"
  install_emmylua || warn "emmylua_ls 安装失败（Lua LSP 不可用）"
  # 旧版安装的 lua-language-server 目录：新版改用 emmylua_ls 后不再使用。
  if [ -e "$DEVKIT_ROOT/lua-ls" ]; then
    rm -rf "$DEVKIT_ROOT/lua-ls"
    log "清理旧 lua-language-server：$DEVKIT_ROOT/lua-ls"
  fi
  ts_cli_phase
  # C/C++ 工具要在 Neovim 之前就位（LazyVim 的 clangd 扩展依赖它们），
  # 静态 git 也让后续 GitHub 克隆更稳。
  clang_phase || warn "clangd 未完成（重跑可续装）"
  git_phase || warn "静态 git 未完成，暂用系统 git（重跑可续装）"
  # 先写 .bashrc：后面 nvim/LazyVim 即使网络失败，musl 工具也已可用。
  bashrc_phase
  nvim_phase
  lazyvim_phase
  ts_parsers_phase
  node_phase
  npm_tools_phase
  python_env_phase
  python_tools_phase
  shims_phase
  state_set DEVKIT_ROOT "$DEVKIT_ROOT"
  state_set SETUP_AT "$(date -Is)"
  verify_phase
  cleanup_build_artifacts_phase
  log "全部完成。清理请运行：bash devkit-cleanup.sh"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
