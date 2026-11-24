# devkit 增加 C/C++ 与 LazyVim 工具链 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 devkit 在 20.04 母机上提供 git / clangd / shuck / stylua / neocmakelsp / lua-language-server，并在安装 LazyVim 时自动关闭 Mason、接上 devkit 工具与 C/C++/CMake/Python extras。

**Architecture:** 所有新工具落到 `~/.devkit`，由 `.bashrc` 托管块进入 PATH；LazyVim 仅对带 `.devkit-managed` 标记的配置写入一个托管插件文件 `lua/plugins/devkit.lua`（禁 Mason、导入 extras、配置 shuck），并幂等写入 `vim.g.lazyvim_python_lsp`。Rust 工具走 musl 静态；非 Rust 工具只接受已验证 glibc 基线的官方包。C/C++ 只装 clangd：LSP、格式化（内置 clang-format）和诊断（内置 clang-tidy）都由它提供。

**Tech Stack:** Bash、cargo（musl target）、GitHub releases、Neovim/LazyVim、Mason（被禁用）、conform.nvim、nvim-treesitter。

**Spec:** `docs/devkit.md`（含本次设计）与 `docs/HANDOFF.md`；决策过程见本次会话。

## Global Constraints

- 安装脚本只在 Ubuntu 20.04/22.04 容器内运行；完整安装禁止 root；root 只做 `APT_ONLY=1`。
- 设计原则一：优先使用 Rust 实现的工具；**不安装 Go 工具链**，所需 Go 工具用 Rust 替代（`fzf→skim`、`lazygit→gitui`、`shfmt→shuck`）。
- 设计原则二：**所有 Rust 工具一律静态链接 musl**，`--target x86_64-unknown-linux-musl`，以 `readelf -l` 无 `INTERP` 判定静态（static-PIE 同样通过）。
- C/C++ 只安装 `clangd`；不安装独立的 `clang-format` / `clang-tidy`。格式化走 clangd 内置 clang-format（LazyVim `lsp_format = "fallback"`），诊断走 clangd `--clang-tidy`。
- 新版本默认值（URL 已 HEAD 验证 200）：shuck-cli `0.2.11`（要求 rustc ≥1.94.1，现装 1.100.0）、stylua `2.6.0`、neocmakelsp `0.12.0`、lua-language-server `3.19.2`（glibc 二进制，最高符号 GLIBC_2.17）、clangd `22.1.6`。
- 所有下载走 `gh_url`（含 `GH_MIRRORS` 回退）；幂等：已存在且版本匹配则跳过。
- 只修改托管文件：`.bashrc` 标记块、`~/.config/nvim` 内存在 `.devkit-managed` 时的 `lua/plugins/devkit.lua` 与 `lua/config/options.lua` 追加行。
- 脚本注释章节编号必须与 `setup-ubuntu.sh` 文件头 1–8 章一致。

## Review Focus

- 母机当前**缺少 `libpcre2-8.a`**（实测 `ye_cheng_0d2bf85e`），静态 git 会链接失败；`APT_ONLY=1` 必须补 `libpcre2-dev`。
- 只装 clangd 时，`verify_phase` 与文档不得再要求 `clang-format` / `clang-tidy` 存在；conform 也不得把 `c`/`cpp` 指向 `clang-format` 可执行文件，否则保存时会报 formatter 缺失。格式化必须依赖 LazyVim 默认的 `lsp_format = "fallback"` 走 clangd。
- shuck/stylua/neocmakelsp 必须 musl 静态；lua-language-server 是 glibc 二进制，只做运行验收，不进静态计数。
- 禁 Mason 后 LazyVim 启动不能报缺失依赖：`LazyVim.has()` 读 `spec.plugins`，被 `enabled=false` 的插件已从中移除（lazy.nvim `fix_disabled`→`disable`→`del`，已核实），因此 `have_mason` 为 false，不会调用 `mason-lspconfig.setup`。
- LazyVim 默认 `lua = { "stylua" }`、`sh = { "shfmt" }`；devkit 用 stylua + shuck 覆盖，`sh` 必须显式改成 shuck。
- extras 的 parser `cpp/cmake/ninja/rst` 在 Lazy sync 后补齐；失败不应让安装整体失败。
- `git_phase`/`clang_phase` 网络失败时降级告警、不中断；成功时必须把新工具并入脚本自身 PATH（包括 git 已存在提前返回的分支），后续 LazyVim 克隆才用新 git。
- 静态 git 必须含 `remote-https`，否则 opencode 不可用。

---

### Task 1: 文档设计原则与脚本文档头对齐

**Files:**
- Modify: `docs/devkit.md:1-8`
- Modify: `setup-ubuntu.sh:14-60`（文件头注释）

**Interfaces:**
- Produces: 文档顶部原则段落；脚本头注释与真实变量一致，供后续任务引用。

- [ ] **Step 1: 在 `docs/devkit.md` 标题下第一段加入设计原则**

在标题 `# 共享 home 开发工具母机（Ubuntu 20.04 / 22.04）` 之后、现有介绍段之前插入：

```markdown
**设计原则**

1. **优先使用 Rust 实现的工具，不安装 Go 工具链。** 需要 Go 工具时用 Rust 等价物
   替代：`fzf → skim（sk）`、`lazygit → gitui`、`shfmt → shuck`。
2. **所有 Rust 工具一律静态链接 musl。** 统一用 `x86_64-unknown-linux-musl` 编译
   （现代 Rust 默认 static-PIE，`readelf -l` 无 `INTERP`），不依赖宿主机 glibc；
   共享 home 挂到任何 glibc 容器都能直接运行。
```

- [ ] **Step 2: 修正 `setup-ubuntu.sh` 文件头开关注释**

把第 55–57 行附近改为真实变量：

```text
#   SHUCK_VERSION=...      shuck-cli 版本（默认 0.2.11）
#   STYLUA_VERSION=...     stylua 版本（默认 2.6.0）
#   NEOCMAKELSP_VERSION=... neocmakelsp 版本（默认 0.12.0）
#   LUA_LS_VERSION=...     lua-language-server 版本（默认 3.19.2）
#   GIT_VERSION=...        静态 git 版本（默认从 kernel.org 解析最新）
#   CLANGD_VERSION=...     clangd 版本（默认 22.1.6；置空则解析最新 release）
#   FORCE_CLANG=1          重新下载 clangd
#   FORCE_GIT=1            重新编译静态 git
```

同时把文件头第 17 行的章节说明改成 `#   3 C/C++ 工具（clangd、静态 git）`。

- [ ] **Step 3: 校验语法与文档**

Run: `bash -n setup-ubuntu.sh && grep -n "设计原则" docs/devkit.md`
Expected: `bash -n` 无输出（通过），grep 命中新段落。

- [ ] **Step 4: Commit**

```bash
git add docs/devkit.md setup-ubuntu.sh
git commit -m "docs(devkit): :memo: record rust-over-go principle and align env docs"
```

---

### Task 2: 收尾 clangd 与静态 git 阶段

**Files:**
- Modify: `setup-ubuntu.sh`（`apt_phase`、C/C++ 变量与函数、`clang_phase`、`git_phase`、`main`、`cleanup_build_artifacts_phase`、`verify_phase`、章节注释）
- Modify: `docs/devkit.md`（C/C++ 章节、制品布局、变量表）
- Modify: `docs/使用方法.md`（C/C++ 工具说明）

**Interfaces:**
- Consumes: 现有 `CLANGD_*`/`GIT_*`/`CURL_STATIC` 变量与 `is_static`/`runtime_ok`/`gh_url`。
- Produces: 只含 clangd 的 `~/.devkit/clang/bin`、可成功编译的静态 git、后续阶段可见的新工具 PATH。

- [ ] **Step 1: apt 补 `libpcre2-dev`**

`apt-get install` 列表加 `libpcre2-dev`（静态 git 的 `EXTLIBS=-lpcre2-8` 需要；母机实测缺失）。

- [ ] **Step 2: 删除 clang-format / clang-tidy 安装路径，`clang_phase` 只保留 clangd**

删除以下内容：

- 变量 `CLANG_STATIC_LLVM`（第 78 行）与 `CLANG_STATIC_BASE`（第 694 行）；
- `resolve_clang_static_tag()` 与 `install_clang_static_tools()` 两个函数（约第 732–771 行）；
- `clang_phase` 里的 clang-tidy wrapper 整块与静态工具自检。

`clang_phase` 替换为：

```bash
clang_phase(){
  step "C/C++ LSP（clangd）"
  install_clangd || { warn "clangd 安装失败（C/C++ LSP 不可用）"; return 1; }
  [ -x "$CLANG_TOOLS_BIN/clangd" ] || { warn "clangd 缺失"; return 1; }
  # 官方包只依赖系统 glibc（2.18+）；LSP、内置 clang-format、内置 clang-tidy 都由它提供。
  runtime_ok "$CLANG_TOOLS_BIN/clangd" \
    || warn "clangd 无法运行（检查母机 glibc 是否 >= 2.18）"
  export PATH="$CLANG_TOOLS_BIN:$PATH"
}
```

同步改掉仍提 clang-format/clang-tidy 的注释：文件头第 17 行、第 675–682 行章节说明、
`install_clangd` 里“clang-tidy 需要”改为“clangd 内置头”、`bashrc_phase` 的 PATH 注释。

- [ ] **Step 3: 阶段成功即注入 PATH，git 失败不中断**

`git_phase` 的 PATH/CA 注入必须放在**版本解析之后、已存在跳过判断之前**（否则
“git 已存在”早返回时，后续 LazyVim 克隆仍用系统 git）：

```bash
  [ -x "$GIT_BIN" ] && export PATH="$GIT_PREFIX/bin:$PATH"
  [ -f /etc/ssl/certs/ca-certificates.crt ] && export GIT_SSL_CAINFO="/etc/ssl/certs/ca-certificates.crt"
```

`main` 改为（脚本是 `set -Eeuo pipefail`，不加 `|| warn` 会直接中断）：

```bash
  clang_phase || warn "clangd 未完成（重跑可续装）"
  git_phase || warn "静态 git 未完成，暂用系统 git（重跑可续装）"
```

- [ ] **Step 4: 清理 curl 构建产物并重排注释编号**

`cleanup_build_artifacts_phase` 列表追加 `"$CURL_STATIC" "$DEVKIT_ROOT/src/curl" "$DEVKIT_ROOT/src/curl.tar.gz"`。内部注释重排：`3.1 Neovim`→`4.1`、`3.2 LazyVim`→`4.2`、`3.3 Treesitter`→`4.3`、`4. Node`→`5.`、`4.1 Node`→`5.1`、`4.2 npm`→`5.2`、`5. Python`→`6.`、`5.1/5.2/5.3`→`6.1/6.2/6.3`、`6. .bashrc`→`7.`、`7.1/7.2`→`8.1/8.2`。

- [ ] **Step 5: `verify_phase` 与文档同步**

`verify_phase` 的 `other_bins` 设为：

```bash
  other_bins="nvim clangd git $other_bins"
```

`docs/devkit.md`：

- 制品布局 `clang/bin/` 注释改为“clangd（LSP + 内置 clang-format / clang-tidy，glibc 2.18+）”；
- 章节表 3.1 删掉 clang-format/clang-tidy；
- “C/C++ 工具”整节改为只讲 clangd：格式化由 LazyVim `lsp_format = "fallback"` 调
  clangd 内置 clang-format，诊断由 clangd `--clang-tidy`（LazyVim extra 已带该参数）；
  明确“暂不安装独立 clang-format / clang-tidy，命令行/CI 需要时再单独装”；
- 变量表删 `CLANG_STATIC_LLVM`，`FORCE_CLANG` 描述改为“重新下载 clangd”。

`docs/使用方法.md` 第 5 节末尾加一小节“C/C++（clangd）”：说明只装 clangd、
`clangd --version` 验证、格式化/诊断来源，以及没有独立 CLI。

- [ ] **Step 6: 容器内验证（首次完整运行，建立 clang/git 制品）**

Run:

```bash
docker exec -u 0 ye_cheng_0d2bf85e bash -c \
  "APT_ONLY=1 bash /home/ye_cheng/work/project/devkit/setup-ubuntu.sh"
docker exec ye_cheng_0d2bf85e test -f /usr/lib/x86_64-linux-gnu/libpcre2-8.a && echo PCRE2-OK
docker exec -u 0 ye_cheng_0d2bf85e bash -c \
  "su - ye_cheng -c 'SKIP_APT=1 bash /home/ye_cheng/work/project/devkit/setup-ubuntu.sh'"
```

Expected: `PCRE2-OK`；完整安装退出码 0；验收表无 clang-format/clang-tidy 缺项。

- [ ] **Step 7: 验证 clangd 与静态 git**

Run:

```bash
docker exec -u 0 ye_cheng_0d2bf85e bash -c "su - ye_cheng -c '
  ~/.devkit/clang/bin/clangd --version | head -1
  ls ~/.devkit/clang/bin
  ~/.devkit/git/bin/git --version
  ls ~/.devkit/git/libexec/git-core/git-remote-https
  readelf -l ~/.devkit/git/bin/git | grep -c INTERP || true'"
```

Expected: clangd 版本输出；`clang/bin` 只有 `clangd`；git 版本；`git-remote-https` 存在；`INTERP` 计数 0。

- [ ] **Step 8: Commit**

```bash
git add setup-ubuntu.sh docs/devkit.md docs/使用方法.md
git commit -m "refactor(devkit): :recycle: install clangd only and harden git phase"
```

---

### Task 3: 新增 Rust 静态工具 shuck / stylua / neocmakelsp / lua-language-server

**Files:**
- Modify: `setup-ubuntu.sh`（变量区、`RUST_TOOLS`、`install_rust_tool`、新增函数、`main`、`bashrc_phase`、`verify_phase`）
- Modify: `docs/devkit.md`（制品布局、章节表、Rust 工具表）
- Modify: `docs/使用方法.md`（工具清单与验证）

**Interfaces:**
- Produces: `musl/bin/{shuck,stylua,neocmakelsp}`、`lua-ls/bin/lua-language-server`、PATH 条目、环境变量 `SHUCK_VERSION/STYLUA_VERSION/NEOCMAKELSP_VERSION/LUA_LS_VERSION/FORCE_RUST_TOOLS` 行为。
- Consumes: `MUSL_BIN`、`gh_url`、`is_static`、`runtime_ok`、`install_rust_tool`（现有）。

- [ ] **Step 1: 增加版本变量与路径**

在 `FORCE_GIT` 行后加：

```bash
SHUCK_VERSION="${SHUCK_VERSION:-0.2.11}"
STYLUA_VERSION="${STYLUA_VERSION:-2.6.0}"
NEOCMAKELSP_VERSION="${NEOCMAKELSP_VERSION:-0.12.0}"
LUA_LS_VERSION="${LUA_LS_VERSION:-3.19.2}"
```

路径区加：

```bash
LUA_LS_PREFIX="$DEVKIT_ROOT/lua-ls"
NEOCMAKELSP_BIN="$MUSL_BIN/neocmakelsp"
```

- [ ] **Step 2: 扩展 `RUST_TOOLS` 支持第五列版本**

数组注释改为 `格式：crate|binary|额外环境（none|openssl）|features|version`；
数组项改为 `crate|binary|kind|features|version`，新增两行：

```bash
  "shuck-cli|shuck|none||$SHUCK_VERSION"
  "stylua|stylua|none||$STYLUA_VERSION"
```

`install_rust_tool` 增加 `ver="${5:-}"`，构造 `vargs`：

```bash
    local vargs=()
    [ -n "$ver" ] && vargs=(--version "$ver")
```

两次 `cargo install` 调用都加 `"${vargs[@]}"`；`rust_tools_phase` 的 `IFS='|' read` 增加第五个变量并传参。

- [ ] **Step 3: 新增 `install_neocmakelsp`**

放在 `install_yazi` 之后：

```bash
install_neocmakelsp(){
  local ver="$NEOCMAKELSP_VERSION" url tmpd asset
  if [ -x "$NEOCMAKELSP_BIN" ] && [ "$FORCE_RUST_TOOLS" != "1" ] \
     && "$NEOCMAKELSP_BIN" --version 2>/dev/null | grep -q "$ver"; then
    log "neocmakelsp 已存在，跳过"; return 0
  fi
  step "neocmakelsp $ver（musl 静态）"
  url="https://github.com/neocmakelsp/neocmakelsp/releases/download/v$ver/neocmakelsp-x86_64-unknown-linux-musl.tar.gz"
  tmpd=$(mktemp -d) || return 1
  asset="$tmpd/n.tgz"
  gh_url "$url" "$asset" || { rm -rf "$tmpd"; warn "neocmakelsp 下载失败"; return 1; }
  tar -xzf "$asset" -C "$tmpd" || { rm -rf "$tmpd"; return 1; }
  install -m 0755 "$(find "$tmpd" -type f -name neocmakelsp | head -1)" "$NEOCMAKELSP_BIN"
  rm -rf "$tmpd"
  is_static "$NEOCMAKELSP_BIN" || die "neocmakelsp 不是静态链接"
  runtime_ok "$NEOCMAKELSP_BIN" || die "neocmakelsp 运行时崩溃"
}
```

- [ ] **Step 4: 新增 `install_lua_ls`**

```bash
install_lua_ls(){
  local ver="$LUA_LS_VERSION" url tmpd tar
  if [ -x "$LUA_LS_PREFIX/bin/lua-language-server" ] && [ "$FORCE_RUST_TOOLS" != "1" ] \
     && "$LUA_LS_PREFIX/bin/lua-language-server" --version 2>/dev/null | grep -q "^$ver$"; then
    log "lua-language-server 已存在，跳过"; return 0
  fi
  step "lua-language-server $ver（官方 linux-x64）"
  url="https://github.com/LuaLS/lua-language-server/releases/download/$ver/lua-language-server-$ver-linux-x64.tar.gz"
  tmpd=$(mktemp -d) || return 1
  tar="$tmpd/lua-ls.tar.gz"
  gh_url "$url" "$tar" || { rm -rf "$tmpd"; warn "lua-language-server 下载失败"; return 1; }
  mkdir -p "$tmpd/x"; tar -xzf "$tar" -C "$tmpd/x" || { rm -rf "$tmpd"; return 1; }
  [ -x "$tmpd/x/bin/lua-language-server" ] || { rm -rf "$tmpd"; warn "包结构异常"; return 1; }
  rm -rf "$LUA_LS_PREFIX"; mv "$tmpd/x" "$LUA_LS_PREFIX"
  rm -rf "$tmpd"
  log "lua-language-server → $LUA_LS_PREFIX"
}
```

- [ ] **Step 5: 挂到 main / PATH / 验收**

`main` 在 `install_yazi` 后、`ts_cli_phase` 前加：

```bash
  install_neocmakelsp || warn "neocmakelsp 安装失败（CMake LSP 不可用）"
  install_lua_ls || warn "lua-language-server 安装失败（Lua LSP 不可用）"
```

`verify_phase`：PATH 前缀加 `"$LUA_LS_PREFIX/bin"`；静态循环加 `shuck stylua neocmakelsp`；`other_bins` 加 `lua-language-server`。

`bashrc_phase` 第一条 PATH 追加 `$HOME/.devkit/lua-ls/bin`。

- [ ] **Step 6: 容器内验证（增量运行）**

Run:

```bash
docker exec -u 0 ye_cheng_0d2bf85e bash -c \
  "su - ye_cheng -c 'SKIP_APT=1 bash /home/ye_cheng/work/project/devkit/setup-ubuntu.sh'"
docker exec -u 0 ye_cheng_0d2bf85e bash -c "su - ye_cheng -c '
  for b in shuck stylua neocmakelsp; do readelf -l ~/.devkit/musl/bin/\$b | grep -q INTERP && echo \"\$b DYNAMIC\"; done
  ~/.devkit/musl/bin/shuck --version
  ~/.devkit/musl/bin/stylua --version
  ~/.devkit/musl/bin/neocmakelsp --version
  ~/.devkit/lua-ls/bin/lua-language-server --version'"
```

Expected: 无 `DYNAMIC`；四个版本依次输出；整体退出码 0。

- [ ] **Step 7: 更新文档并提交**

`docs/devkit.md`：制品布局加 `lua-ls/`；章节表加 2.5（shuck/stylua）与 2.6（neocmakelsp/lua-language-server）；Rust 工具表补两行；开关表补四个版本变量。`docs/使用方法.md` 第 5 节补同样内容与验证命令。

```bash
git add setup-ubuntu.sh docs/devkit.md docs/使用方法.md
git commit -m "feat(devkit): :sparkles: add shuck, stylua, neocmakelsp and lua-language-server"
```

---

### Task 4: LazyVim 托管配置（自动关 Mason + extras + parser）

**Files:**
- Modify: `setup-ubuntu.sh`（`lazyvim_phase`、新增 `write_lazyvim_devkit_config`、`ensure_lazyvim_parsers`）
- Modify: `docs/devkit.md`（关闭 Mason 一节改为自动）
- Modify: `docs/使用方法.md`（Neovim 一节）

**Interfaces:**
- Consumes: Task 2/3 的工具在 PATH；`use_glibc_cc_for_nvim`。
- Produces: `~/.config/nvim/lua/plugins/devkit.lua`、`options.lua` 的 `vim.g.lazyvim_python_lsp`、`cpp/cmake/ninja/rst` parser。

- [ ] **Step 1: 新增 `write_lazyvim_devkit_config`**

仅对托管配置调用；`mkdir -p "$NVIM_CONFIG/lua/plugins"`，用 heredoc 写入固定内容：

```lua
-- 由 devkit setup-ubuntu.sh 生成，重跑会覆盖；自定义请另建文件。
return {
  { "mason-org/mason.nvim", enabled = false },
  { "mason-org/mason-lspconfig.nvim", enabled = false },
  { "williamboman/mason.nvim", enabled = false },
  { "williamboman/mason-lspconfig.nvim", enabled = false },
  { "stevearc/conform.nvim", dependencies = {} },

  { import = "lazyvim.plugins.extras.lang.clangd" },
  { import = "lazyvim.plugins.extras.lang.cmake" },
  { import = "lazyvim.plugins.extras.lang.python" },

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
```

`lua/config/options.lua` 用幂等追加（`grep -q 'lazyvim_python_lsp' ||`）：

```lua
vim.g.lazyvim_python_lsp = "basedpyright"
```

- [ ] **Step 2: 在 `lazyvim_phase` 调用**

托管分支（含首次创建后）在 `do_sync=1` 确定后调用 `write_lazyvim_devkit_config`，并打印：
`LazyVim 托管配置：已禁用 Mason，启用 clangd/cmake/python extras`。

- [ ] **Step 3: Lazy sync 后补 extras parser**

新增：

```bash
ensure_lazyvim_parsers(){
  local script=/tmp/devkit-ts-extra.lua
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
  "$NVIM_PREFIX/bin/nvim" --headless -c "luafile $script" \
    && log "extras parser 就绪（cpp/cmake/ninja/rst）" \
    || warn "extras parser 未完成（首次打开对应文件时会自动补编）"
  rm -f "$script"
}
```

`lazyvim_phase` 在 sync 成功后、仅在托管配置且 nvim 可用时调用。

- [ ] **Step 4: 容器内验证托管配置与 Mason 状态**

Run:

```bash
docker exec -u 0 ye_cheng_0d2bf85e bash -c "su - ye_cheng -c '
  nvim --headless -c \"lua print(require(\\\"lazy.core.config\\\").spec.plugins[\\\"mason.nvim\\\"] == nil)\" +qa
  nvim --headless -c \"lua print(vim.g.lazyvim_python_lsp)\" +qa
  ls ~/.local/share/nvim/site/parser/{cpp,cmake,ninja,rst}.so
  grep -c shuck ~/.config/nvim/lua/plugins/devkit.lua'"
```

Expected: `true`（mason 已从 spec 移除）；`basedpyright`；四个 `.so` 存在；`shuck` 计数 ≥1。

- [ ] **Step 5: 文档更新并提交**

`docs/devkit.md` 的“关闭 Mason”一节改为“脚本自动写入 `lua/plugins/devkit.lua`”，保留手工等价片段；能力来源表把 C/C++ 格式化改为“clangd 内置 clang-format（LSP fallback）”、诊断改为“clangd 内置 clang-tidy”，并加 shuck/stylua/neocmakelsp/lua-language-server；把“`stylua` / `shfmt` 是 LazyVim 默认的 mason 工具……需要时单独安装”改为“devkit 已提供 stylua 与 shuck（替代 shfmt），无需 Mason”。`docs/使用方法.md` 第 8 节说明托管文件、extras 与 parser。

```bash
git add setup-ubuntu.sh docs/devkit.md docs/使用方法.md
git commit -m "feat(nvim): :sparkles: manage LazyVim config and disable mason"
```

---

### Task 5: devkit-up 透传、交接文档与全量验证

**Files:**
- Modify: `devkit-up.sh:11-45`
- Modify: `docs/HANDOFF.md`
- Modify: `README.md`（一句话工具范围）
- Test: 容器内完整安装 + 幂等重跑

**Interfaces:**
- Consumes: Task 1–4 的全部变量与行为。
- Produces: 宿主机一键安装可覆盖新变量；交接文档可直接用于下次会话。

- [ ] **Step 1: `devkit-up.sh` 透传新变量**

`ENV_KEYS` 追加：`SHUCK_VERSION STYLUA_VERSION NEOCMAKELSP_VERSION LUA_LS_VERSION GIT_VERSION CLANGD_VERSION CURL_VERSION FORCE_CLANG FORCE_GIT`；文件头环境变量注释同步。

- [ ] **Step 2: 更新 `docs/HANDOFF.md` 与 `README.md`**

HANDOFF 顶部加 2026-11-24 记录：第 3 章、静态 git、clangd（只装 LSP，格式化/诊断走内置）、shuck/stylua/neocmakelsp/lua-language-server、LazyVim 自动关 Mason、extras parser；写实际验证结果。README 脚本说明补一句 C/C++ 与 Neovim 工具范围。

- [ ] **Step 3: 容器内全量安装**

Run:

```bash
docker exec -u 0 ye_cheng_0d2bf85e bash -c \
  "APT_ONLY=1 bash /home/ye_cheng/work/project/devkit/setup-ubuntu.sh" && \
docker exec -u 0 ye_cheng_0d2bf85e bash -c \
  "su - ye_cheng -c 'SKIP_APT=1 bash /home/ye_cheng/work/project/devkit/setup-ubuntu.sh'"
```

Expected: 两次退出码 0；验收表 `static_bad=0 other_bad=0`。

- [ ] **Step 4: 幂等重跑**

再次执行 Step 3 的普通用户命令。

Expected: 退出码 0；无重新编译 nvim/git/Rust 工具；耗时显著短于首次。

- [ ] **Step 5: 终验清单**

Run（宿主机）：

```bash
docker exec -u 0 ye_cheng_0d2bf85e bash -c "su - ye_cheng -c '
  source ~/.bashrc >/dev/null 2>&1
  shuck --version; stylua --version; neocmakelsp --version
  lua-language-server --version; clangd --version | head -1
  git --version; test -x ~/.devkit/git/libexec/git-core/git-remote-https && echo HTTPS-OK
  nvim --headless +qa && echo NVIM-OK'"
```

Expected: 全部有版本输出、`HTTPS-OK`、`NVIM-OK`，退出码 0。

- [ ] **Step 6: Commit**

```bash
git add devkit-up.sh docs/HANDOFF.md README.md
git commit -m "docs(devkit): :memo: forward new env vars and refresh handoff"
```
