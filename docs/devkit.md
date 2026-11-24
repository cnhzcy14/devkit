# 共享 home 开发工具母机（Ubuntu 20.04 / 22.04）

**设计原则**

1. **优先使用 Rust 实现的工具，不安装 Go 工具链。** 需要 Go 工具时用 Rust 等价物
   替代：`fzf → skim（sk）`、`lazygit → gitui`、`shfmt → shuck`。
2. **所有 Rust 工具一律静态链接 musl。** 统一用 `x86_64-unknown-linux-musl` 编译
   （现代 Rust 默认 static-PIE，`readelf -l` 无 `INTERP`），不依赖宿主机 glibc；
   共享 home 挂到任何 glibc 容器都能直接运行。

用官方 `ubuntu:20.04` 或 `ubuntu:22.04` 容器作为“母机”，把通用开发工具装进共享
home，之后任何挂载同一 home 的开发容器都能直接使用，并且能保证不污染开发容器环境。`setup-ubuntu.sh` 必须在
Ubuntu 容器内运行；宿主机只负责启动容器，不直接运行安装脚本。

## 文件

| 文件 | 作用 |
|---|---|
| `setup-ubuntu.sh` | 在 Ubuntu 20.04/22.04 容器内安装全部工具，幂等可重跑 |
| `devkit-cleanup.sh` | 完整删除安装制品，清理并还原 `.bashrc` 托管块 |
| `devkit-up.sh` | 宿主机侧启动母机容器（沿用你的 docker run 参数） |

## 制品布局

所有工具集中在一个根目录，清理时整目录删除即可：

```text
~/.devkit/
├── musl/bin/       musl 静态 Rust 工具（含 uv/uvx）+ tree-sitter CLI/wrapper
├── clang/bin/      clangd（LSP + 内置 clang-format / clang-tidy，glibc 2.18+）
├── git/bin/        静态编译的 git（自带 HTTPS），优先于系统 git
├── lua-ls/bin/     lua-language-server（官方 glibc 包，Lua LSP）
├── python-bin/     uv 安装的 Python 3.12 可执行文件（不加入全局 PATH）
├── venvs/          Trellis/opencode 各自的 Python venv
├── shims/          只为工具进程注入私有 PATH 的 trellis/tl/opencode shim
├── uv-tools/       uv tool 安装的 Python CLI（可选）
├── nvim/           源码编译的 Neovim（glibc 基线取决于构建容器）
├── node/           Node.js 22 LTS
├── npm-global/     hunk / Trellis 等 npm 全局包
├── rustup/ cargo/  musl 构建工具链
├── ts-cli/         tree-sitter CLI 构建产物
├── uv-python/      uv 托管的 Python 3.12（glibc）
├── openssl-musl/   ducker 需要的静态 OpenSSL
├── src/ backups/ state/
```

`~/.bashrc` 只追加一段带
`# >>> devkit (setup-ubuntu.sh) >>>` / `# <<< ... <<<` 标记的块，重复执行会先删旧块
再写新块，不影响其他内容。`python-bin` 不进入 PATH，避免覆盖容器的 `python3`；
Trellis/opencode 通过 `shims/` 在各自进程中临时使用自己的 venv。

## 方式一：一键启动并安装

```bash
cd ~/work/project/devkit        # 本仓库所在目录
./devkit-up.sh --setup
```

它会：

1. 用 `ubuntu:20.04` 或 `ubuntu:22.04`（可用 `IMAGE=` 换成本地/内网镜像）后台启动容器，
   `--net=host`、home 映射、hostname、UID/GID、用户名都与你现有启动命令一致；
2. 通过 `docker exec -u 0 <容器> /bin/bash`（root）创建同名用户（镜像已有则校验
   UID/GID 后跳过），并只执行 `APT_ONLY=1 setup-ubuntu.sh` 装系统依赖；
3. 通过 `docker exec -u 0 <容器> /bin/bash -c "su - $USER -c '...'"` 以普通用户执行
   完整安装，所有 Rust 工具、nvim、node/npm、hunk、Trellis、uv/Python 都落到
   共享 home；
4. 最后用 `docker exec -it -u 0 <容器> su - $USER` 进入普通用户 shell。

### 使用内网/自制的基础镜像

```bash
IMAGE=myreg.example.com/ubuntu20.04:dev ./devkit-up.sh --setup
```

要求：

- 仍是 glibc 的 Ubuntu 20.04（或更新版本）；Alpine/musl 镜像不行；
- x86_64；
- 有 `/bin/bash`、`/bin/sleep`、apt 和基本 coreutils；
- 镜像内已有同名用户时，UID/GID 必须与宿主机一致，否则脚本会报错退出；
- 如果 apt 源已经是公司内网源，设置 `APT_MIRROR=off`，避免脚本改源或回退公网 USTC；
  镜像已预装全部系统依赖时加 `SKIP_APT=1`。

> `devkit-up.sh` 会把下列变量写进容器 `/tmp/devkit-up.env`，root 和普通用户
> 两个阶段都会 source：`MIRROR`、`APT_MIRROR`、`SKIP_APT`、
> `RUSTUP_DIST_SERVER`、`RUSTUP_UPDATE_ROOT`、`RUSTUP_INIT_URL`、
> `CARGO_REGISTRY`、`NPM_REGISTRY`、`NODE_DIST`、`GH_MIRRORS`、
> `OPENSSL_TARBALL`、`PY_MIRROR`，以及版本类变量。

> 这个边界是强制的：完整安装不允许以 root 运行；root 只负责
> `APT_ONLY=1` 的系统依赖，避免 `~/.devkit` 里的文件属主变成 root。

完整安装：

```bash
./devkit-up.sh --setup
```

只启动容器不安装：

```bash
./devkit-up.sh
```

只装 apt 依赖：

```bash
./devkit-up.sh --apt
```

## 安装边界（重要）

- **root**：只做系统依赖，即 `APT_ONLY=1`。apt 装 `curl/git/build-essential/musl-tools/...`，
  不写任何开发工具到 home。
- **同名普通用户**：完整安装。Rust 工具、neovim、node/npm、hunk、Trellis、uv/Python
  全部落到 `/home/$USER/.devkit`，文件属主是普通用户。
- 完整安装现在**禁止 root 运行**；如果以前用 root 跑过，制品会落在
  `/root/.devkit`，宿主机 home 里当然看不到。可在容器 root 下清理：

  ```bash
  docker exec -it <容器> /bin/bash
  HOME=/root DEVKIT_ROOT=/root/.devkit bash /home/$USER/work/project/devkit/devkit-cleanup.sh
  ```

  然后退出，按普通用户重跑完整安装。

## 方式二：手动在已有容器内执行

先按你原来的命令启动容器（会直接进入普通用户 shell）。然后开两个终端：

```bash
# 终端 A：root，装系统依赖
docker exec -it <容器名或ID> /bin/bash
APT_ONLY=1 bash /home/$USER/work/project/devkit/setup-ubuntu.sh

# 终端 B：普通用户，装 home 内的工具
docker exec -it <容器名或ID> /bin/bash -c "su - $USER"
SKIP_APT=1 bash /home/$USER/work/project/devkit/setup-ubuntu.sh
```

> `ubuntu:20.04` 默认没有 sudo。因此设计成 root 装系统依赖、普通用户装 home
> 制品，避免把 `~/.devkit` 里文件的属主写成 root。安装脚本本身只允许在容器内
> 运行；宿主机只负责 `docker run` / `devkit-up.sh`。

安装脚本按章节从上到下执行：
预检/apt → Rust → Neovim → Node/TS-JS → Python → `.bashrc` → 验收/清理。
重跑是幂等的，已装好的工具会自动跳过。

## 安装内容

### 章节与工具对照

| 章节 | 子节 | 安装内容 |
|---|---|---|
| 1. 预检与系统依赖 | 1.1 | root 用 apt 装构建依赖（curl/git/build-essential/cmake/ninja/gettext/musl-tools/libclang-dev/libncurses-dev/libssl-dev/libpcre2-dev/libexpat1-dev 等），含国内源探测与回退 |
| 2. Rust 工具链与 CLI | 2.1 | rustup + stable + `x86_64-unknown-linux-musl`，写 cargo 镜像与 crt-static 配置 |
| | 2.2 | `keifu` `gitui` `sk` `ducker` `eza` `bat` `rg` `fd` `btm` `zoxide` `uv`/`uvx` |
| | 2.3 | `yazi` / `ya`（GitHub musl 预编译包优先，失败源码编译） |
| | 2.4 | `tree-sitter` CLI（musl 静态 + wrapper，供 Neovim 编译 parser） |
| | 2.5 | `shuck`（替代 shfmt）、`stylua`（cargo 源码编译，musl 静态） |
| | 2.6 | `neocmakelsp`（官方 musl 包）、`lua-language-server`（官方 linux-x64，glibc 2.17+） |
| 3. C/C++ 工具 | 3.1 | `clangd`（官方包，libstdc++ 静态 / glibc 2.18+）→ `~/.devkit/clang/bin`；LSP、内置 clang-format / clang-tidy |
| | 3.2 | 静态 `git` 2.56.x（源码编译，自带 HTTPS/libcurl）→ `~/.devkit/git/bin` |
| 4. Neovim / LazyVim / Treesitter | 4.1 | Neovim 最新 tag 源码编译 → `~/.devkit/nvim` |
| | 4.2 | LazyVim starter → `~/.config/nvim`，headless `Lazy! sync` 装插件（nvim-treesitter 随后会按其清单从 GitHub 拉语法并编译基础 parser）；托管配置写入 `lua/plugins/devkit.lua`（关 Mason、clangd/cmake/python extras、shuck）与 `options.lua`（basedpyright） |
| | 4.3 | `UPDATE_TS_PARSERS=1` 时按 LazyVim 列表更新 Treesitter parser；托管配置另补装 `cpp/cmake/ninja/rst`，均强制 glibc 编译 |
| 5. Node.js 与 TS/JS 工具 | 5.1 | Node.js 22 LTS → `~/.devkit/node` |
| | 5.2 | `hunk`(hunkdiff)、`trellis`、`opencode` → `~/.devkit/npm-global` |
| 6. Python 运行时与工具环境 | 6.1 | uv 托管 Python 3.12 + trellis/opencode 独立 venv |
| | 6.2 | `basedpyright`、`ruff`（`uv tool`, 落 `~/.devkit/uv-tool-bin`） |
| | 6.3 | trellis/opencode 的 venv 注入 shim |
| 7. `.bashrc` 托管块 | 7.1 | PATH 与环境变量（shims、musl/bin、clang/bin、git/bin、node、npm-global、uv-tool-bin、cargo、nvim），`y()` 包装函数 |
| 8. 验收与清理 | 8.1 | 验收表：版本 + 静态链接校验 |
| | 8.2 | 删除构建中间产物（neovim `.deps`/`build`、ts-cli、openssl-musl、git/curl 源码） |

### Rust 工具（全部 musl 静态）

| 命令 | crate |
|---|---|
| `keifu` | `keifu` |
| `yazi` / `ya` | 官方 musl 预编译包；失败则源码编译（crates.io 包缺 preset 资源） |
| `gitui` | `gitui`（替代 lazygit） |
| `sk`（skim） | `skim`（替代 fzf） |
| `ducker` | `ducker` |
| `eza` | `eza` |
| `bat` | `bat` |
| `rg`（ripgrep） | `ripgrep` |
| `fd`（fd-find） | `fd-find` |
| `btm`（bottom） | `bottom`（`battery,zfs,gpu`：支持 Linux 上的 AMD/Intel GPU；关闭 `nvidia`，因为 NVML 仅支持 glibc） |
| `zoxide` | `zoxide` |
| `shuck` | `shuck-cli`（替代 shfmt，Shell 格式化/语法检查） |
| `stylua` | `stylua`（Lua 格式化） |
| `uv` / `uvx` | 官方 musl 静态预编译包；同时用于管理 Python |

编译参数：`--target x86_64-unknown-linux-musl` + `target-feature=+crt-static`。
Rust 现代 musl 默认产出 **static-PIE**：`file` 可能显示 `dynamically linked`，
但 `readelf -l` 没有 `INTERP` 段、`ldd` 显示 `statically linked`，脚本按
`PT_INTERP` 判定是否为静态，不满足会直接报错。

编辑器相关的非 Rust 组件：

- `neocmakelsp`：官方 `x86_64-unknown-linux-musl` 预编译包，落 `~/.devkit/musl/bin`；
- `lua-language-server`：官方 `linux-x64` 包（glibc 2.17+），落 `~/.devkit/lua-ls`。

### C/C++ 工具（clangd、git）

C/C++ 只安装 `clangd`，不装独立的 `clang-format` / `clang-tidy`。clangd 本身就是
LSP，并内置格式化与 clang-tidy 检查能力：

- **LSP**：补全、跳转、语义诊断、inlay hints 等；
- **格式化**：clangd 内置 clang-format。LazyVim 的 clangd extra 已传
  `--fallback-style=llvm`，conform 默认 `lsp_format = "fallback"`，保存时走 LSP 格式化；
- **clang-tidy 诊断**：LazyVim 的 clangd extra 已传 `--clang-tidy`，由 clangd 跑内置检查。

因此不需要独立 CLI；只有命令行或 CI 需要直接敲 `clang-format` / `clang-tidy` 时，
再单独安装。

| 工具 | 来源 | 链接方式 | 20.04（glibc 2.31）可用 |
|---|---|---|---|
| `clangd` | `clangd/clangd` 官方 release | libstdc++ 等已静态，只依赖系统 glibc（官方保证 2.18+） | ✅ 实测 |
| `git` | 官方源码编译 | **静态 + 内置 HTTPS（静态 libcurl/OpenSSL）** | ✅ 实测 |

验证依据（20.04 容器内实跑）：

```bash
~/.devkit/clang/bin/clangd --version        # 22.x
ls ~/.devkit/clang/bin                      # 只有 clangd
~/.devkit/git/bin/git --version
ls ~/.devkit/git/libexec/git-core/git-remote-https   # 存在（HTTPS 可用）
```

**为什么不用上游 static-git**：`darkvertex/static-git` 的二进制**没有 `git-remote-https`**，
`git ls-remote https://...` 直接报 `remote helper 'https' is not a git command`。
opencode 拉取插件/仓库都走 https，因此本脚本改为自己编译带 HTTPS 的静态 git。

**静态 libcurl 的版本上限**：git 的 HTTPS 依赖脚本自编的精简静态 libcurl（只启用
OpenSSL + zlib，关闭 LDAP 等无关协议，**保留 proxy 支持**以适配内网
`http_proxy`/`https_proxy`）。curl 8.18 起**硬性要求 OpenSSL >= 3.0**，
而 Ubuntu 20.04/22.04 自带的是 OpenSSL 1.1.1，因此脚本会按宿主 OpenSSL 版本自动
封顶到 `8.17.0`（最后一个兼容 1.1.1 的版本）；OpenSSL 3.x 的宿主则用最新版。
需要覆盖时设 `CURL_VERSION`。

**为什么不用 apt 的 clangd**：apt.llvm.org 的包依赖 `libLLVM.so`（解压 ~150MB）
和 libedit/libffi/libxml2 等一串动态库，整套约 300MB，且把运行时风险转嫁给宿主机。
官方 clangd 包只依赖系统 glibc，没有这个问题。

**clangd 找标准库头**：clangd 包只带 clang 内置头（`lib/clang/<ver>/include`），
C++ 标准库头来自母机的 g++（`build-essential`，脚本已装）。

关掉 Mason 后 LazyVim 的 C/C++ 能力完全由 clangd 提供：

- clangd：`neovim/nvim-lspconfig` 的 `clangd` 服务，`cmd` 里直接调用 `clangd`；
- 格式化：clangd 内置 clang-format（LSP fallback）；
- 诊断：clangd `--clang-tidy`。

Mason 由脚本自动关闭，见下一节。

#### 自动关闭 Mason（托管配置）

用本脚本安装的 LazyVim（`~/.config/nvim/.devkit-managed`）会在每次安装/重跑时
自动写入 `~/.config/nvim/lua/plugins/devkit.lua`，并幂等设置
`lua/config/options.lua` 里的 `vim.g.lazyvim_python_lsp`。内容包括：

- 禁用两种 org 名的 `mason.nvim` / `mason-lspconfig.nvim`；
- 去掉 `conform.nvim` 对 `mason.nvim` 的依赖；
- 导入 `lang.clangd`、`lang.cmake`、`lang.python` 三个 extras；
- Shell 格式化从默认的 `shfmt` 改为 `shuck`；Lua 继续用 LazyVim 默认的 `stylua`
  （devkit 已提供）；
- `vim.g.lazyvim_python_lsp = "basedpyright"`。

Lazy sync 成功后脚本还会补装 extras 需要的 Treesitter parser：
`cpp / cmake / ninja / rst`（落在 `~/.local/share/nvim/site/parser`）。

非托管配置可手工加入等价片段：

```lua
-- ~/.config/nvim/lua/plugins/devkit.lua
return {
  -- 禁用 mason 及 mason-lspconfig；LSP 服务改由 PATH 中的 devkit 二进制提供
  { "mason-org/mason.nvim", enabled = false },
  { "mason-org/mason-lspconfig.nvim", enabled = false },
  { "williamboman/mason.nvim", enabled = false },
  { "williamboman/mason-lspconfig.nvim", enabled = false },

  -- conform.nvim 声明依赖 mason.nvim，禁用后这里去掉依赖
  { "stevearc/conform.nvim", dependencies = {} },

  { import = "lazyvim.plugins.extras.lang.clangd" },
  { import = "lazyvim.plugins.extras.lang.cmake" },
  { import = "lazyvim.plugins.extras.lang.python" },

  {
    "stevearc/conform.nvim",
    opts = {
      -- C/C++ 不配 formatter，保存时走 clangd 内置 clang-format（LSP fallback）
      formatters_by_ft = { sh = { "shuck" } },
      formatters = {
        shuck = {
          command = "shuck",
          args = { "format", "--stdin-filename", "$FILENAME", "-" },
        },
      },
    },
  },
}
```

禁掉 Mason 后各语言的能力来源：

| 能力 | 工具 | 来源 |
|---|---|---|
| C/C++ LSP | `clangd` | `~/.devkit/clang/bin` |
| C/C++ 格式化 | clangd 内置 clang-format（LSP fallback） | 同上 |
| C/C++ 诊断 | clangd 内置 clang-tidy（`--clang-tidy`） | 同上 |
| CMake LSP | `neocmakelsp` | `~/.devkit/musl/bin` |
| Python LSP | `basedpyright` | `~/.devkit/uv-tool-bin` |
| Python lint/format | `ruff` | 同上 |
| Lua LSP | `lua-language-server` | `~/.devkit/lua-ls/bin` |
| Lua 格式化 | `stylua` | `~/.devkit/musl/bin` |
| Shell 格式化 | `shuck`（替代 `shfmt`） | 同上 |
| Treesitter parser | `tree-sitter` CLI | 同上 |

需要留意：

- **codelldb（DAP 调试器）** 由 `mason-nvim-dap` 提供。禁用 Mason 后 C/C++ 调试适配器
  不再自动安装；需要调试就用 `gdb`（母机 apt 里的 `gdb`）或另行放置 `codelldb`。
- Neovim 启动时不会再出现 Mason 的下载请求；`LazyVim.has("mason.nvim")` 为 false。

### Neovim / TS-JS / Python

- Neovim：`git ls-remote` 取最新 `vX.Y.Z` tag，源码编译到 `~/.devkit/nvim`；
- tree-sitter CLI：源码编译为 musl 静态二进制，带 wrapper，供 nvim parser 使用；
- LazyVim：克隆 starter 到 `~/.config/nvim`，自动加 OSC52 剪贴板设置；
- Node.js 22 LTS：npmmirror 官方 tarball；
- uv + Python 3.12：uv 二进制在 Rust 阶段安装；Python 3.12 只装一份，Trellis 与
  opencode 各自使用独立 venv（`~/.devkit/venvs/`），互不共享 site-packages；
- basedpyright / ruff：`uv tool install` 到 `~/.devkit/uv-tool-bin`，与工具 venv 隔离；
  由 `.bashrc` 的 PATH 提供给宿主机和其他共享 home 的容器；
- hunk：npm 包 `hunkdiff`，默认固定 `0.24.0`（`0.24.1` 的 linux 平台包尚未同步到
  npmmirror；可用 `HUNK_VERSION=...` 覆盖）；
- Trellis：npm 包 `@mindfoldhq/trellis@latest`；
- opencode：npm 包 `@opencode/cli`，默认安装，命令为 `opencode`（另有
  `opencode2` 别名）；设 `WITH_OPENCODE=0` 可跳过。

## 清理

```bash
# 宿主机或容器内均可，以同一个普通用户执行
bash ~/work/project/devkit/devkit-cleanup.sh
```

删除内容：

- `~/.devkit` 整个目录；
- `.bashrc` 的 devkit 标记块；
- 仅当 setup 创建过时才删除 `~/.local/share/nvim`、`~/.local/state/nvim`、
  `~/.cache/nvim`；
- 若 setup 备份过旧的 `~/.config/nvim`，自动还原；判断依据是配置目录里的
  `.devkit-managed` 标记，标记被移除时视为用户自有配置并保留。

先预览：

```bash
DRY_RUN=1 bash /home/$USER/work/project/devkit/devkit-cleanup.sh
```

> apt 源替换发生在容器内的 `/etc/apt/sources.list`（并留 `.devkit.bak`），属于
> 容器系统层，不在 home 清理范围；容器重建即消失。

## 常用开关

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `MIRROR` | `cn` | `official` 切回官方默认源 |
| `SKIP_APT` | `0` | 普通用户重跑时设为 `1` |
| `APT_ONLY` | `0` | root 只装系统依赖 |
| `APT_MIRROR` | `cn` | deb 源：`cn`=清华、`ustc`、`off`、主机名或完整 URL |
| `RUSTUP_DIST_SERVER` | `https://rsproxy.cn` | rustup 工具链源 |
| `RUSTUP_UPDATE_ROOT` | `$RUSTUP_DIST_SERVER/rustup` | rustup 自更新源 |
| `RUSTUP_INIT_URL` | 随 `RUSTUP_DIST_SERVER` | rustup-init.sh 地址 |
| `CARGO_REGISTRY` | `sparse+https://rsproxy.cn/index/` | cargo 源；`official` 用 crates.io |
| `NPM_REGISTRY` | cn=npmmirror / official=npmjs | npm registry |
| `NODE_DIST` | cn=npmmirror / official=nodejs.org | Node tarball 根 URL |
| `GH_MIRRORS` | ghfast + gh-proxy | GitHub 镜像前缀（空格分隔）；`none` 只用直连 |
| `OPENSSL_TARBALL` | 清华/官方 | musl 静态 OpenSSL 源码地址 |
| `PY_MIRROR` | NJU 镜像 | uv 下载 python-build-standalone 的镜像根 |
| `PYPI_INDEX` | 清华（cn）/ 空（official） | uv 安装 venv 依赖与 `uv tool` 时的 PyPI 源 |

> `MIRROR=cn` 时脚本会先探测各国内镜像，不可达的项自动回退官方源
> （rustup→static.rust-lang.org、npm/Node→npmjs/nodejs.org、PyPI→pypi.org、
> apt 与 OpenSSL→保留镜像自带源/官网），并在预检阶段打印回退提示。
| `PYTHON_VERSION` | `3.12` | uv 托管的 Python 版本 |
| `UV_VERSION` | 最新 release | uv musl 静态包版本；可固定避免 API 解析 |
| `FORCE_NVIM` | `0` | 强制重编 nvim |
| `FORCE_TS_CLI` | `0` | 强制重编 tree-sitter CLI（musl 静态） |
| `UPDATE_TS_PARSERS` | `0` | `1` 安装/更新 LazyVim ensure_installed 的 parser |
| `TS_CLI_VERSION` | `0.27.2` | tree-sitter CLI 版本，必须 >=0.26.1 |
| `SHUCK_VERSION` | `0.2.11` | shuck-cli 版本（musl 静态） |
| `STYLUA_VERSION` | `2.6.0` | stylua 版本（musl 静态） |
| `NEOCMAKELSP_VERSION` | `0.12.0` | neocmakelsp 版本（官方 musl 包） |
| `LUA_LS_VERSION` | `3.19.2` | lua-language-server 版本（官方 linux-x64） |
| `FORCE_RUST_TOOLS` | `0` | 强制重编 Rust 工具，并重装 neocmakelsp/lua-language-server |
| `FORCE_LAZYVIM` | `0` | 备份旧配置并重建 LazyVim |
| `WITH_OPENCODE` | `1` | 通过 npm 安装 opencode；设 `0` 跳过 |
| `OPENCODE_VERSION` | `latest` | opencode 版本（npm 包 `@opencode/cli`） |
| `HUNK_VERSION` | `0.24.0` | hunk 版本 |
| `YAZI_VERSION` | 自动解析 | yazi 版本（默认取 rsproxy 最新） |
| `CLANGD_VERSION` | `22.1.6` | clangd 版本（置空则解析 clangd/clangd 最新 release） |
| `FORCE_CLANG` | `0` | 重新下载 clangd |
| `GIT_VERSION` | 自动解析 | 静态 git 版本（默认取 kernel.org 最新） |
| `CURL_VERSION` | 自动解析 | 静态 libcurl 版本（OpenSSL 1.1.1 宿主封顶 8.17.0） |
| `FORCE_GIT` | `0` | 重新编译静态 git |
| `DEVKIT_ROOT` | `~/.devkit` | 制品根目录 |

公司镜像示例（按实际地址替换）：

```bash
APT_MIRROR=mirrors.corp.example.com \
RUSTUP_DIST_SERVER=https://mirrors.corp.example.com/rustup \
RUSTUP_UPDATE_ROOT=https://mirrors.corp.example.com/rustup \
RUSTUP_INIT_URL=https://mirrors.corp.example.com/rustup-init.sh \
CARGO_REGISTRY=sparse+https://mirrors.corp.example.com/crates.io-index/ \
NPM_REGISTRY=https://npm.corp.example.com \
NODE_DIST=https://mirrors.corp.example.com/node \
GH_MIRRORS="https://git.corp.example.com/github-proxy/" \
SKIP_APT=1 bash setup-ubuntu.sh
```

`APT_MIRROR` 若填完整 URL，需指向 ubuntu 仓库根（例如
`http://mirrors.corp.example.com/ubuntu`）；只填主机名时脚本自动补 `/ubuntu`。

## 耗时提示

首次完整安装会编译 12 个 Rust 工具、musl 静态 OpenSSL、Neovim 和 tree-sitter CLI，
另会下载 Python；视机器性能大约 25–45 分钟。`UPDATE_TS_PARSERS=1` 时还会编译
Treesitter parser。Rust 工具、nvim 和 tree-sitter CLI 都有“已存在则跳过”逻辑，
失败后重跑只补未完成项。

## 宿主机上 `yazi` 不能运行的排查

`yazi` 是 musl 静态二进制，放在 `~/.devkit/musl/bin/yazi`，宿主机不需要任何
动态库依赖。按顺序检查：

```bash
ls -l ~/.devkit/musl/bin/yazi ~/.devkit/musl/bin/ya
~/.devkit/musl/bin/yazi --version
grep -n 'devkit (setup-ubuntu.sh)' ~/.bashrc
source ~/.bashrc
command -v yazi
```

- 如果 `~/.devkit` 不存在：安装没有落到这个 home。常见原因是 setup 在容器里
  以 root 跑（写到了 `/root/.devkit`），或者容器的 home 挂载不是
  `/home/$USER`。
- 如果二进制存在但 `command -v yazi` 找不到：`.bashrc` 托管块没写入或当前
  shell 没重新加载。`setup-ubuntu.sh` 现在会在 nvim 之前先写 `.bashrc`，即使
  后面 nvim/LazyVim 因网络失败，yazi 等 musl 工具也已经可用。
- 如果绝对路径执行报 `No such file or directory` 但文件确实存在：说明拿到的是
  动态链接的 musl 版本（缺 loader），用 `readelf -l <bin> | grep INTERP` 检查；
  正常构建结果不应有 `INTERP`。

## 注意事项

- **宿主机是 Ubuntu 18.04 时**：Rust 工具是 musl 静态，宿主机也能跑；但 Neovim /
  Node 是 20.04 glibc 基线制品，`.bashrc` 里只在检测到容器时才把它们加入 PATH，
  避免污染宿主机 shell。
- **GitHub 连通性**：nvim 源码、LazyVim starter、nvim 依赖、LazyVim 插件都走
  GitHub。脚本内置 `ghfast.top` / `gh-proxy.com` 前缀；若两者都不通，先设置
  `HTTPS_PROXY` 或手工把源码放到对应目录后重跑。yazi 额外支持从 Gitee 镜像
  源码编译回退。
- **Lazy sync 失败不算安装失败**：starter 配置已落地，网络恢复后重跑脚本即可续传。
- **Trellis 只安装 CLI**：`trellis init` 在每个项目仓库里单独执行，不会自动改你的
  项目。
