#!/usr/bin/env bash
# ============================================================================
# setup-ubuntu.sh — 共享 home 开发工具母机（Ubuntu 20.04 容器内运行）
# ----------------------------------------------------------------------------
# 设计目标
#   * 在官方 ubuntu:20.04 容器里，把通用工具装进共享 home，其他容器直接复用；
#   * Rust 工具全部编译为 x86_64-unknown-linux-musl 静态二进制，任何 glibc 容器可跑；
#   * Neovim 在 20.04 上源码编译（glibc 2.31 基线，向上兼容 22.04/24.04）；
#   * hunk / Trellis 走 Node + npm，Python 由 uv 托管 3.12（20.04 系统只有 3.8）；
#   * 所有制品集中在 ~/.devkit，便于 devkit-cleanup.sh 完整删除；
#   * .bashrc 只写一段带标记的块，重复执行自动替换，不碰用户其他内容；
#   * 默认全部使用国内镜像，可用 MIRROR=official 切回官方。
#
# 运行方式（ubuntu:20.04 默认无 sudo，推荐分两步）：
#   1) root 装系统依赖：
#      APT_ONLY=1 bash /home/$USER/dev_dockerfiles/setup-ubuntu.sh
#   2) 同名普通用户装 home 制品：
#      su - $USER -c 'SKIP_APT=1 bash /home/$USER/dev_dockerfiles/setup-ubuntu.sh'
#   或直接使用宿主机侧 devkit-up.sh --setup 一键完成。
#
# 常用开关：
#   RUST_ONLY=1            只装 Rust 工具（keifu/yazi/gitui/ducker/eza/bat/
#                          rg/fd/btm/zoxide），跳过 nvim/node/uv/npm/LazyVim
#   NPM_ONLY=1            只补 Node/uv/Python/hunk/Trellis（Rust 工具已存在则跳过），
#                         跳过 nvim/LazyVim
#   NVIM_ONLY=1           只做 Neovim 源码编译 + .bashrc 托管块 + LazyVim/Lazy sync，
#                         跳过 Rust 工具、Node/uv/npm 阶段（它们应已装好）
#   MIRROR=official        整套默认源切回官方（默认 cn）
#   APT_MIRROR=...         deb 源：默认 cn(清华)；可填 ustc、off、主机名或完整 URL
#   RUSTUP_DIST_SERVER=... rustup 工具链源（默认 https://rsproxy.cn）
#   RUSTUP_UPDATE_ROOT=... rustup 自更新源（默认 $RUSTUP_DIST_SERVER/rustup）
#   RUSTUP_INIT_URL=...    rustup-init.sh 地址（默认随 RUSTUP_DIST_SERVER）
#   CARGO_REGISTRY=...     cargo 源：默认 sparse+https://rsproxy.cn/index/；
#                         填 official 用 crates.io，或公司 sparse/git 索引 URL
#   SKIP_APT=1             跳过 apt（镜像已预装依赖）
#   FORCE_NVIM=1           重新编译 nvim
#   FORCE_TS_CLI=1         重编 tree-sitter CLI（musl 静态）
#   UPDATE_TS_PARSERS=1    安装/更新 LazyVim ensure_installed 的 Treesitter parser
#   TS_CLI_VERSION=...     tree-sitter CLI 版本（默认 0.27.2，必须 >=0.26.1）
#   FORCE_RUST_TOOLS=1     重编所有 Rust 工具
#   FORCE_LAZYVIM=1        备份旧配置并重建 LazyVim
#   WITH_OPENCODE=1        额外安装 opencode
#   HUNK_VERSION=0.24.0    hunk 版本（0.24.1 的 linux 包尚未同步到 npmmirror）
#   YAZI_VERSION=...       yazi 版本（默认从 rsproxy 解析最新）
#   DEVKIT_ROOT=...        自定义制品根目录（默认 ~/.devkit）
# ============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

MIRROR="${MIRROR:-cn}"
RUST_ONLY="${RUST_ONLY:-0}"
NPM_ONLY="${NPM_ONLY:-0}"
NVIM_ONLY="${NVIM_ONLY:-0}"
SKIP_APT="${SKIP_APT:-0}"
FORCE_NVIM="${FORCE_NVIM:-0}"
FORCE_RUST_TOOLS="${FORCE_RUST_TOOLS:-0}"
FORCE_LAZYVIM="${FORCE_LAZYVIM:-0}"
WITH_OPENCODE="${WITH_OPENCODE:-0}"
FORCE_TS_CLI="${FORCE_TS_CLI:-0}"
UPDATE_TS_PARSERS="${UPDATE_TS_PARSERS:-0}"
TS_CLI_VERSION="${TS_CLI_VERSION:-0.27.2}"
HUNK_VERSION="${HUNK_VERSION:-0.24.0}"
DEVKIT_ROOT="${DEVKIT_ROOT:-$HOME/.devkit}"
APT_MIRROR="${APT_MIRROR:-}"
RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-}"
RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT:-}"
RUSTUP_INIT_URL="${RUSTUP_INIT_URL:-}"
CARGO_REGISTRY="${CARGO_REGISTRY:-}"
PY_MIRROR="${PY_MIRROR:-}"
MUSL_PREFIX="$DEVKIT_ROOT/musl"
MUSL_BIN="$MUSL_PREFIX/bin"

export PATH="$MUSL_BIN:$DEVKIT_ROOT/bin:$DEVKIT_ROOT/nvim/bin:$DEVKIT_ROOT/node/bin:$DEVKIT_ROOT/cargo/bin:$PATH"
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
export UV_CACHE_DIR="$DEVKIT_ROOT/cache/uv"

STATE_DIR="$DEVKIT_ROOT/state"
BACKUP_DIR="$DEVKIT_ROOT/backups"
NVIM_SRC="$DEVKIT_ROOT/src/neovim"
NVIM_PREFIX="$DEVKIT_ROOT/nvim"
NODE_PREFIX="$DEVKIT_ROOT/node"
NPM_PREFIX="$DEVKIT_ROOT/npm-global"
OPENSSL_MUSL="$DEVKIT_ROOT/openssl-musl"
MUSL_TARGET="x86_64-unknown-linux-musl"
NVIM_CONFIG="$HOME/.config/nvim"

if [ "$MIRROR" = "cn" ]; then
  GH_MIRRORS=("https://ghfast.top/" "https://gh-proxy.com/")
  : "${APT_MIRROR:=cn}"
  : "${RUSTUP_DIST_SERVER:=https://rsproxy.cn}"
  : "${CARGO_REGISTRY:=sparse+https://rsproxy.cn/index/}"
  NPM_REGISTRY="https://registry.npmmirror.com"
  NODE_DIST="https://npmmirror.com/mirrors/node"
  : "${PY_MIRROR:=https://mirrors.nju.edu.cn/github-release/astral-sh/python-build-standalone}"
  OPENSSL_TARBALL="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/main/o/openssl/openssl_1.1.1f.orig.tar.gz"
else
  GH_MIRRORS=("")
  : "${APT_MIRROR:=off}"
  : "${RUSTUP_DIST_SERVER:=https://static.rust-lang.org}"
  : "${CARGO_REGISTRY:=official}"
  NPM_REGISTRY="https://registry.npmjs.org"
  NODE_DIST="https://nodejs.org/dist"
  PY_MIRROR=""
  OPENSSL_TARBALL="https://www.openssl.org/source/openssl-1.1.1f.tar.gz"
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

# ---------------------------- 1. 预检 + apt ---------------------------------
preflight(){
  step "预检"
  if [ "$NVIM_ONLY" = "1" ] && { [ "$RUST_ONLY" = "1" ] || [ "$NPM_ONLY" = "1" ]; }; then
    die "NVIM_ONLY=1 不能与 RUST_ONLY/NPM_ONLY 同时使用"
  fi
  if [ "$NVIM_ONLY" = "1" ]; then
    local missing=()
    for c in git make cmake ninja cc; do
      command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ "${#missing[@]}" -eq 0 ] \
      || die "NVIM_ONLY 需要构建工具：${missing[*]}。请先以 root 运行 APT_ONLY=1 装依赖"
  fi
  if [ "${APT_ONLY:-0}" != "1" ]; then
    mkdir -p "$DEVKIT_ROOT" "$STATE_DIR" "$BACKUP_DIR"
  fi
  [ -r /etc/os-release ] || die "无法识别系统"
  . /etc/os-release
  log "系统：${ID:-?} ${VERSION_ID:-?}  架构：$(uname -m)"
  [ "$(uname -m)" = "x86_64" ] || die "本脚本目前只支持 x86_64"
  if [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" != "20.04" ]; then
    warn "推荐在 ubuntu:20.04 中运行；当前版本编译的 nvim 兼容基线会变高"
  fi
  [ -f /.dockerenv ] || warn "看起来不在容器内（继续执行，但请确认 home 是共享的）"
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
    http://*|https://*) printf '%s' "${APT_MIRROR%/}" ;;
    *)      printf 'http://%s/ubuntu' "${APT_MIRROR%/}" ;;
  esac
}

apt_set_mirror(){
  local base="$1" f
  # 20.04 基础镜像默认没有 ca-certificates；首次装依赖先用 HTTP 落地证书
  if ! as_root test -f /etc/ssl/certs/ca-certificates.crt; then
    base="${base/#https:\/\//http://}"
  fi
  as_root bash -c "set -e; f=/etc/apt/sources.list; cp -n \"\$f\" \"\$f.devkit.bak\" 2>/dev/null || true;
    sed -ri 's#http(s)?://(archive|security)\\.ubuntu\\.com/ubuntu#${base}#g' \"\$f\"
    for x in /etc/apt/sources.list.d/*.list; do [ -f \"\$x\" ] || continue;
      sed -ri 's#http(s)?://(archive|security)\\.ubuntu\\.com/ubuntu#${base}#g' \"\$x\"; done"
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
    libncurses-dev libssl-dev zlib1g-dev libexpat1-dev linux-libc-dev \
    musl-tools musl-dev python3 python3-pip binutils libclang-dev
  [ -x /usr/bin/musl-gcc ] || die "musl-gcc 未安装成功"
  log "apt 依赖就绪"
}

# ---------------------------- 2. Rust musl 工具链 ---------------------------
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
  curl -fSL --retry 3 -o "$tar" "$OPENSSL_TARBALL"
  tar -xzf "$tar" -C /tmp/devkit-openssl --strip-components=1
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

# ---------------------------- 3. Rust 工具（musl 静态） ---------------------
# 格式：crate|binary|额外环境（none|openssl）
RUST_TOOLS=(
  "keifu|keifu|none"
  "gitui|gitui|none"
  "ducker|ducker|openssl"
  "eza|eza|none"
  "bat|bat|none"
  "ripgrep|rg|none"
  "fd-find|fd|none"
  "bottom|btm|none|battery,zfs"
  "zoxide|zoxide|none"
)

install_rust_tool(){
  local crate="$1" bin="$2" kind="$3" feat="${4:-}"
  local dest="$MUSL_BIN/$2" envs=() force=() feats=()
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
    if env "${envs[@]}" "$CARGO_HOME/bin/cargo" install "${force[@]}" "${feats[@]}" \
         --locked --root "$MUSL_PREFIX" --target "$MUSL_TARGET" "$crate" 2>&1 | tee "$logf"; then
      :
    elif grep -qE 'no Cargo\.lock|Cargo\.lock.*not found|needs to be updated but --locked' "$logf"; then
      warn "$crate 未提供 Cargo.lock，改为不带 --locked 重试"
      env "${envs[@]}" "$CARGO_HOME/bin/cargo" install "${force[@]}" "${feats[@]}" \
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
  local failed=() spec crate bin kind feat
  for spec in "${RUST_TOOLS[@]}"; do
    IFS='|' read -r crate bin kind feat <<< "$spec"
    if ! install_rust_tool "$crate" "$bin" "$kind" "$feat"; then
      warn "安装失败：$crate → $bin"
      failed+=("$crate")
    fi
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    die "以下 Rust 工具安装失败：${failed[*]}"
  fi
  for bin in rg fd btm; do
    printf '%-56s %s\n' "$MUSL_BIN/$bin" "$(file "$MUSL_BIN/$bin" | cut -d: -f2-)"
  done
  log "Rust 工具全部就绪"
}

# ---------------------------- 3b. yazi / ya（musl 预编译或源码） ------------
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

# ---------------------------- 3c. tree-sitter CLI（musl 静态） -------------
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

# ---------------------------- 4. Neovim（最新 tag，源码编译） ---------------
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

# ---------------------------- 5. Node.js（官方 tarball 镜像） ----------------
node_phase(){
  step "Node.js 22 LTS"
  mkdir -p "$NODE_PREFIX" "$NPM_PREFIX"
  if [ -x "$NODE_PREFIX/bin/node" ]; then
    log "node 已存在：$("$NODE_PREFIX/bin/node" --version)"
  else
    local arch=x64 list ver file url tmp
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

# ---------------------------- 6. uv + Python 3.12 ---------------------------
uv_install_musl(){
  local tag asset url tmpd uv_bin uvx_bin
  tag=$(curl -fsSL --max-time 20 https://api.github.com/repos/astral-sh/uv/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p' | head -1 || true)
  [ -n "$tag" ] || tag="0.13.7"
  asset="uv-x86_64-unknown-linux-musl.tar.gz"
  url="https://github.com/astral-sh/uv/releases/download/$tag/$asset"
  tmpd=$(mktemp -d) || return 1
  if ! gh_url "$url" "$tmpd/$asset"; then rm -rf "$tmpd"; return 1; fi
  tar -xzf "$tmpd/$asset" -C "$tmpd" || { rm -rf "$tmpd"; return 1; }
  uv_bin=$(find "$tmpd" -type f -name uv | head -1)
  uvx_bin=$(find "$tmpd" -type f -name uvx | head -1)
  [ -n "$uv_bin" ] || { rm -rf "$tmpd"; return 1; }
  rm -f "$DEVKIT_ROOT/bin/uv" "$DEVKIT_ROOT/bin/uvx"
  install -m 0755 "$uv_bin" "$DEVKIT_ROOT/bin/uv"
  [ -n "$uvx_bin" ] && install -m 0755 "$uvx_bin" "$DEVKIT_ROOT/bin/uvx"
  rm -rf "$tmpd"
  log "uv musl 静态包安装完成：$(basename "$url")"
}

uv_phase(){
  step "uv + Python 3.12（Trellis 需要 >=3.9）"
  mkdir -p "$DEVKIT_ROOT/bin" "$UV_PYTHON_INSTALL_DIR"
  # 记录 uv 在 ~/.devkit 之外创建的文件，供清理脚本精确删除
  if [ -e "$HOME/.local/bin/python3.12" ]; then state_set_once UV_LOCAL_PY_CREATED 0
  else state_set_once UV_LOCAL_PY_CREATED 1; fi
  if [ -e "$HOME/.config/uv/uv-receipt.json" ]; then state_set_once UV_RECEIPT_CREATED 0
  else state_set_once UV_RECEIPT_CREATED 1; fi
  if [ -e "$HOME/.local/share/uv" ]; then state_set_once UV_SHARE_CREATED 0
  else state_set_once UV_SHARE_CREATED 1; fi
  if [ -x "$DEVKIT_ROOT/bin/uv" ] \
     && "$DEVKIT_ROOT/bin/uv" --version 2>/dev/null | grep -q 'linux-musl'; then
    log "uv 已是 musl 静态：$("$DEVKIT_ROOT/bin/uv" --version)"
  elif uv_install_musl; then
    :
  elif curl -LsSf --retry 2 https://astral.sh/uv/install.sh \
       | env UV_INSTALL_DIR="$DEVKIT_ROOT/bin" UV_NO_MODIFY_PATH=1 sh; then
    warn "musl 静态包下载失败，已回退官方安装脚本（可能是 glibc 版）"
  else
    warn "musl 包和官方脚本均失败，改用 pip 镜像安装"
    python3 -m pip install --prefix "$DEVKIT_ROOT/uv-pip" --no-cache-dir \
      -i https://pypi.tuna.tsinghua.edu.cn/simple uv
    rm -f "$DEVKIT_ROOT/bin/uv"
    ln -sf "$DEVKIT_ROOT/uv-pip/bin/uv" "$DEVKIT_ROOT/bin/uv"
  fi
  [ -x "$DEVKIT_ROOT/bin/uv" ] || die "uv 安装失败"
  if [ -n "$PY_MIRROR" ]; then export UV_PYTHON_INSTALL_MIRROR="$PY_MIRROR"; fi
  if ! "$DEVKIT_ROOT/bin/uv" python install 3.12; then
    warn "uv 镜像下载失败，改试官方源"
    unset UV_PYTHON_INSTALL_MIRROR
    "$DEVKIT_ROOT/bin/uv" python install 3.12 || die "Python 3.12 安装失败"
  fi
  local py
  py=$("$DEVKIT_ROOT/bin/uv" python find 3.12)
  [ -x "$py" ] || die "找不到 uv 托管的 Python 3.12"
  ln -sf "$py" "$DEVKIT_ROOT/bin/python3"
  ln -sf "$py" "$DEVKIT_ROOT/bin/python"
  log "python3 → $py（$("$py" --version)）"
}

# ---------------------------- 7. hunk / Trellis（npm） ----------------------
npm_tools_phase(){
  step "hunk / Trellis"
  mkdir -p "$NPM_PREFIX"
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

  if [ "$WITH_OPENCODE" = "1" ] && ! command -v opencode >/dev/null 2>&1; then
    "$npm" install "${opts[@]}" opencode-ai || warn "opencode 安装失败"
  fi
  "$DEVKIT_ROOT/bin/python3" --version
}

# ---------------------------- 8. LazyVim -------------------------------------
track_nvim_dir(){
  local dir="$1" key="$2"
  if [ -e "$dir" ]; then state_set_once "$key" 0; else state_set_once "$key" 1; fi
}

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
  track_nvim_dir "$HOME/.local/share/nvim" NVIM_DATA_CREATED
  track_nvim_dir "$HOME/.local/state/nvim" NVIM_STATE_CREATED
  track_nvim_dir "$HOME/.cache/nvim" NVIM_CACHE_CREATED
  if [ ! -x "$NVIM_PREFIX/bin/nvim" ]; then
    warn "nvim 缺失，跳过 Lazy sync"; return 0
  fi
  log "headless Lazy! sync（插件下载走 GitHub；失败可重跑续传）"
  "$NVIM_PREFIX/bin/nvim" --headless "+Lazy! sync" +qa \
    && log "Lazy sync 完成" \
    || warn "Lazy sync 未完成，网络好转后重跑本脚本"
}

# ---------------------------- 8b. Treesitter parser（glibc） --------------
ts_parsers_phase(){
  step "Treesitter parser（glibc）"
  if [ "$UPDATE_TS_PARSERS" != "1" ]; then
    log "UPDATE_TS_PARSERS=0，跳过"
    return 0
  fi
  [ -x "$MUSL_BIN/tree-sitter.real" ] || die "tree-sitter CLI 缺失，无法更新 parser"
  [ -x "$NVIM_PREFIX/bin/nvim" ] || die "nvim 缺失，无法更新 parser"
  [ -d "$NVIM_CONFIG" ] || die "LazyVim 配置缺失，无法更新 parser"
  # parser 必须用容器内的 glibc cc 编译，去掉 musl 相关 CFLAGS
  unset CFLAGS CXXFLAGS CFLAGS_x86_64_unknown_linux_musl CXXFLAGS_x86_64_unknown_linux_musl CC_x86_64_unknown_linux_musl
  export PATH="$MUSL_BIN:$NVIM_PREFIX/bin:$PATH"
  local script=/tmp/devkit-ts-update.lua
  cat > "$script" <<'LUA'
local TS = require("nvim-treesitter")
TS.update(nil, { summary = true }):await(function()
  vim.cmd("qa")
end)
LUA
  log "headless TSUpdate（在 20.04 容器内编译 glibc parser）"
  if "$NVIM_PREFIX/bin/nvim" --headless -c "luafile $script"; then
    log "Treesitter parser 更新完成"
  else
    warn "TSUpdate 未完成，可稍后重跑"
  fi
  rm -f "$script"
  local count
  count=$(find "$HOME/.local/share/nvim/site/parser" -maxdepth 1 -name '*.so' 2>/dev/null | wc -l)
  log "parser 数量：$count（$HOME/.local/share/nvim/site/parser）"
}

# ---------------------------- 9. .bashrc 托管块 -----------------------------
bashrc_phase(){
  step ".bashrc 托管块"
  local rc="$HOME/.bashrc" created=0
  if [ ! -f "$rc" ]; then touch "$rc"; created=1; fi
  state_set_once BASH_RC_CREATED "$created"
  sed -i '/^# >>> devkit (setup-ubuntu.sh) >>>/,/^# <<< devkit (setup-ubuntu.sh) <<</d' "$rc"
  cat >> "$rc" <<'EOF'
# >>> devkit (setup-ubuntu.sh) >>>
# musl 工具、node/npm、cargo、uv/Python 在宿主机和容器都可用。
if [ -d "$HOME/.devkit" ]; then
  case ":$PATH:" in *":$HOME/.devkit/musl/bin:"*) ;; *)
    export PATH="$HOME/.devkit/bin:$HOME/.devkit/node/bin:$HOME/.devkit/npm-global/bin:$HOME/.devkit/musl/bin:$HOME/.devkit/cargo/bin:$PATH" ;;
  esac
  export NPM_CONFIG_PREFIX="$HOME/.devkit/npm-global"
  export NPM_CONFIG_CACHE="$HOME/.devkit/cache/npm"
  export RUSTUP_HOME="$HOME/.devkit/rustup"
  export CARGO_HOME="$HOME/.devkit/cargo"
  export UV_PYTHON_INSTALL_DIR="$HOME/.devkit/uv-python"
  export UV_CACHE_DIR="$HOME/.devkit/cache/uv"
fi
# Neovim 是 Ubuntu 20.04（glibc 2.31）基线产物：宿主机 20.04+ 与共享同一
# home 的 Ubuntu 20.04+ 容器都可直接使用；glibc 更老的容器不行。
case ":$PATH:" in *":$HOME/.devkit/nvim/bin:"*) ;; *)
  [ -d "$HOME/.devkit/nvim/bin" ] && export PATH="$HOME/.devkit/nvim/bin:$PATH" ;;
esac
# yazi: 退出时回到最后一次浏览目录
yazi() {
  local tmp cwd
  tmp=$(mktemp -t yazi-cwd.XXXXXX) || return
  command yazi "$@" --cwd-file="$tmp"
  cwd=$(cat -- "$tmp" 2>/dev/null)
  [ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
  rm -f -- "$tmp"
}
# <<< devkit (setup-ubuntu.sh) <<<
EOF
  log ".bashrc 已写入托管块（重开 shell 或 source ~/.bashrc）"
}

# ---------------------------- 10. 验收 --------------------------------------
verify_phase(){
  step "验收"
  export PATH="$MUSL_BIN:$DEVKIT_ROOT/bin:$NVIM_PREFIX/bin:$NODE_PREFIX/bin:$NPM_PREFIX/bin:$CARGO_HOME/bin:$PATH"
  if [ "$NVIM_ONLY" = "1" ]; then
    local p v bad=0 plugins=0
    printf '\n%-10s %-8s %-52s %s\n' 项目 类型 路径 版本
    p=$(command -v nvim 2>/dev/null || true)
    if [ -n "$p" ]; then
      v=$("$p" --version 2>/dev/null | head -1 || echo '?')
      printf '\033[32m%-10s %-8s %-52s %s\033[0m\n' nvim glibc "$p" "$v"
    else
      printf '\033[31m%-10s %-8s %-52s %s\033[0m\n' nvim 缺失 - -
      bad=1
    fi
    if [ -f "$NVIM_CONFIG/.devkit-managed" ]; then
      printf '\033[32m%-10s %-8s %-52s %s\033[0m\n' LazyVim 配置 "$NVIM_CONFIG" managed
    else
      printf '\033[31m%-10s %-8s %-52s %s\033[0m\n' LazyVim 缺失 "$NVIM_CONFIG" -
      bad=1
    fi
    if [ -d "$HOME/.local/share/nvim/lazy" ]; then
      plugins=$(find "$HOME/.local/share/nvim/lazy" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    fi
    printf 'LazyVim 插件目录：%d 个（%s）\n' "$plugins" "$HOME/.local/share/nvim/lazy"
    [ "$plugins" -eq 0 ] && warn "LazyVim 插件尚未同步（网络恢复后重跑本脚本即可续传）"
    printf '\n制品根目录：%s\n' "$DEVKIT_ROOT"
    [ "$bad" -eq 0 ] || die "nvim/LazyVim 验收未通过（见上表）"
    return 0
  fi
  local bin p v static_ok=0 static_bad=0 other_bad=0
  printf '\n%-10s %-8s %-52s %s\n' 工具 类型 路径 版本
  for bin in keifu yazi ya gitui ducker eza bat rg fd btm zoxide; do
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
  if [ "$RUST_ONLY" != "1" ]; then
    local other_bins="node npm hunk trellis uv python3"
    [ "$NPM_ONLY" != "1" ] && other_bins="nvim $other_bins"
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
  fi
  printf '\n制品根目录：%s\n' "$DEVKIT_ROOT"
  printf 'Rust 静态工具：%d 通过，%d 异常；其他工具缺失：%d\n' "$static_ok" "$static_bad" "$other_bad"
  if [ "$static_bad" -ne 0 ] || [ "$other_bad" -ne 0 ]; then
    die "验收未通过（见上表）"
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
  if [ "$NVIM_ONLY" = "1" ]; then
    # 只补 nvim/LazyVim：Rust/Node/uv/npm 应已安装并验证过
    ts_cli_phase
    nvim_phase
    bashrc_phase
    lazyvim_phase
    ts_parsers_phase
  else
    rust_phase
    rust_tools_phase
    step "yazi / ya"
    install_yazi || die "yazi/ya 安装失败"
    # 先写 .bashrc：即使后面的 nvim / LazyVim 因 GitHub 网络失败，
    # musl 工具（含 yazi）在宿主机和新开的容器里也已经可用。
    bashrc_phase
    if [ "$RUST_ONLY" != "1" ]; then
      [ "$NPM_ONLY" != "1" ] && ts_cli_phase
      [ "$NPM_ONLY" != "1" ] && nvim_phase
      node_phase
      uv_phase
      npm_tools_phase
      [ "$NPM_ONLY" != "1" ] && lazyvim_phase
      [ "$NPM_ONLY" != "1" ] && ts_parsers_phase
    fi
  fi
  state_set DEVKIT_ROOT "$DEVKIT_ROOT"
  state_set SETUP_AT "$(date -Is)"
  state_set RUST_ONLY "$RUST_ONLY"
  state_set NPM_ONLY "$NPM_ONLY"
  state_set NVIM_ONLY "$NVIM_ONLY"
  verify_phase
  if [ "$NVIM_ONLY" = "1" ]; then
    log "Neovim/LazyVim 安装完成（NVIM_ONLY=1）"
  elif [ "$RUST_ONLY" = "1" ]; then
    log "Rust 工具安装完成（RUST_ONLY=1，已跳过 nvim/node/npm/LazyVim）"
  elif [ "$NPM_ONLY" = "1" ]; then
    log "npm 工具安装完成（NPM_ONLY=1，已跳过 nvim/LazyVim）"
  else
    log "全部完成。清理请运行：bash devkit-cleanup.sh"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

