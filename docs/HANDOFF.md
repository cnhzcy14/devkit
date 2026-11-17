# 交接说明：当前状态与下一步（Neovim / LazyVim）

> 最后更新：2026-11-17（已核对仓库、容器和 `~/.devkit` 的实际状态）

## 仓库

- devkit 仓：`/home/ye_cheng/work/project/devkit`
- 当前提交：`e8e68d3 feat(devkit): :sparkles: add NVIM_ONLY mode and tree-sitter CLI`
- 该提交已推送（`main` 与 `origin/main` 一致），工作区无未提交改动
- 该提交内容：`NVIM_ONLY`/`UPDATE_TS_PARSERS` 支持、`devkit-up.sh --nvim`、
  uv musl 静态、tree-sitter CLI 静态 + wrapper、相关文档更新
- 文件：
  - `setup-ubuntu.sh`
  - `devkit-up.sh`
  - `devkit-cleanup.sh`
  - `README.md`
  - `docs/devkit.md`
  - `docs/使用方法.md`
  - `docs/HANDOFF.md`（本文件，随本次整理纳入版本跟踪）

旧仓 `/home/ye_cheng/work/project/dev_dockerfiles` 里仍留有同名未跟踪副本，
但停留在 2026-11-08 的旧版本（没有 `--nvim` 和 tree-sitter 改动），已过时；
确认新仓为唯一来源后可删除旧副本。

## 已完成的实际安装

安装位置：宿主机共享 home 的 `~/.devkit`，属主 `ye_cheng:ye_cheng`。

### Rust 工具（全部 musl 静态）

`~/.devkit/musl/bin`：

```text
keifu 0.7.0
yazi / ya 26.5.6
gitui 0.28.1
ducker 0.6.5
eza 0.23.5
bat 0.26.1
rg 15.2.0
fd 10.5.2
btm 0.15.0
zoxide 0.10.0
```

宿主机和容器交互 shell 均已实测可用（`yazi --version`、`rg --version` 等）。
静态判定使用 `readelf -l` 无 `INTERP`，是 static-PIE。

### Node / npm 工具

```text
node v22.20.0
npm 10.9.3
hunk 0.24.0          <- npm 包 hunkdiff
trellis 0.6.17       <- npm 包 @mindfoldhq/trellis
uv 0.13.7
Python 3.12.16       <- uv 托管
```

宿主机与容器交互 shell 均已实测 `hunk --help`、`trellis --help` 正常。
`trellis init` 尚未在真实项目执行（会修改项目仓库）。

### Neovim / LazyVim（已实测）

```text
nvim        NVIM v0.12.6（最新 tag 源码编译，Release，glibc 2.31 基线）
源码        ~/.devkit/src/neovim（tag v0.12.6，HEAD 779c369）
安装        ~/.devkit/nvim（41M，含 runtime）
配置        ~/.config/nvim（LazyVim starter + .devkit-managed）
插件        ~/.local/share/nvim/lazy 共 32 个，lazy-lock.json 已生成
```

实测结果：

- 容器内 `nvim --headless +qa` 返回 0；`nvim --version` 显示 `Build type: Release`
- 宿主机 22.04 直接执行 `~/.devkit/nvim/bin/nvim --version` 正常
- 容器交互 shell（`bash -ic`）PATH 中可找到 `nvim`
- `nvim --headless "+Lazy! sync" +qa` 首次成功，二次执行 `SYNC_RC=0`
- `init.lua` 首行已写入 `vim.g.clipboard = "osc52"`
- 依赖预播种 19 个就位；1 个未成由 cmake 自行下载，不影响构建
- 产物是 glibc 动态链接（非 musl），符合设计

### uv / tree-sitter / parser（2026-11-11 补齐）

```text
uv          0.13.7 (x86_64-unknown-linux-musl)，static-PIE，无 INTERP
uvx         0.13.7 musl 静态
tree-sitter 0.27.2 musl 静态（~/.devkit/musl/bin/tree-sitter.real）
wrapper     ~/.devkit/musl/bin/tree-sitter（绕过静态 musl 的 build dlopen 校验）
parser      35 个，~/.local/share/nvim/site/parser
```

- 实际执行：`SKIP_APT=1 UPDATE_TS_PARSERS=1 bash setup-ubuntu.sh`，退出码 0
- `TSUpdate` 更新 17 个 revision 偏旧的 parser；现在 35 个 revision 全部与当前
  `nvim-treesitter` main 一致
- 新编译 parser 最高 glibc 符号版本 `GLIBC_2.14`，20.04 与宿主 22.04 均可加载
- `nvim :checkhealth` 已显示 `tree-sitter (CLI) is installed`
- 已移除 Mason 的旧 `tree-sitter-cli`（0.24.7，低于 main 分支要求的 0.26.1）
- parser 本体是 glibc `.so`（Neovim 用 dlopen 加载），CLI 才是 musl 静态

### 尚未安装 / 可选

- LazyVim `:checkhealth` 在容器 headless 环境下的其他缺省项（非阻塞）：
  `lazygit`、`fzf`、`luarocks`、`ghostscript`、`ImageMagick`、
  `trash`/`gio`、`kitty`/`wezterm` 等。`rg`/`fd` 实际已装，只有在不加载
  `.bashrc` 的非交互命令里才会显示缺失。
- 旧 XDG 数据（`~/.local/share/nvim/site`、`mason`）来自之前 `~/neovim` 安装；
  用户已改为共享 home 策略，保留现有数据和 parser。

## 当前运行容器

```text
容器名：ye_cheng_d3a5c06b
镜像：ubuntu:20.04
状态：Up 9 days（截至 2026-11-17）
```

内部已创建 `ye_cheng`（UID/GID 1001），root apt 依赖已装好（含
`build-essential / cmake / ninja-build / gettext / musl-tools / libclang-dev` 等）。

进入方式：

```bash
# root
docker exec -it ye_cheng_d3a5c06b /bin/bash

# 普通用户
docker exec -it ye_cheng_d3a5c06b /bin/bash -c "su - ye_cheng"
```

## 脚本当前能力

`setup-ubuntu.sh` 的环境变量：

| 变量 | 作用 |
|---|---|
| `APT_ONLY=1` | root 只装系统依赖 |
| `SKIP_APT=1` | 普通用户跳过 apt |
| `RUST_ONLY=1` | 只装 Rust 工具 |
| `NPM_ONLY=1` | 只补 Node/uv/Python/hunk/Trellis，跳过 nvim/LazyVim |
| `NVIM_ONLY=1` | 只做 nvim 源码编译 + tree-sitter CLI + `.bashrc` + LazyVim/Lazy sync，跳过 Rust/Node/uv/npm |
| `FORCE_NVIM=1` | 强制重编 nvim |
| `FORCE_LAZYVIM=1` | 备份旧配置并重建 LazyVim |
| `FORCE_TS_CLI=1` | 强制重编 tree-sitter CLI（musl 静态） |
| `UPDATE_TS_PARSERS=1` | 安装/更新 LazyVim `ensure_installed` 的 Treesitter parser |
| `TS_CLI_VERSION` | tree-sitter CLI 版本，默认 `0.27.2`，必须 >=0.26.1 |
| `FORCE_RUST_TOOLS=1` | 强制重编所有 Rust 工具 |
| `WITH_OPENCODE=1` | 额外安装 opencode |
| `APT_MIRROR` | deb 源：`cn`/`ustc`/`off`/主机名/完整 URL |
| `RUSTUP_DIST_SERVER` | rustup 工具链源 |
| `RUSTUP_UPDATE_ROOT` | rustup 自更新源 |
| `RUSTUP_INIT_URL` | rustup-init.sh 地址 |
| `CARGO_REGISTRY` | cargo 源，`official` 用 crates.io |
| `PY_MIRROR` | uv Python 下载镜像，默认 NJU |
| `DEVKIT_ROOT` | 默认 `~/.devkit` |

默认镜像：

```text
apt:   http://mirrors.tuna.tsinghua.edu.cn/ubuntu
rustup: https://rsproxy.cn
cargo: sparse+https://rsproxy.cn/index/
python: https://mirrors.nju.edu.cn/github-release/astral-sh/python-build-standalone
```

`devkit-up.sh`：

```bash
./devkit-up.sh --rust   # root apt + 普通用户 Rust-only
./devkit-up.sh --nvim   # root apt + 普通用户 Neovim/LazyVim only
./devkit-up.sh --setup  # root apt + 普通用户完整安装
./devkit-up.sh --apt    # root apt only
```

## 本次安装记录（已验证）

2026-11-10 通过 `NVIM_ONLY=1` 在容器内以普通用户执行：

```bash
docker exec ye_cheng_d3a5c06b /bin/bash -c \
  "su - ye_cheng -c 'NVIM_ONLY=1 SKIP_APT=1 bash /home/ye_cheng/work/project/devkit/setup-ubuntu.sh'"
```

执行链路：

```text
预检 → nvim_phase → bashrc_phase → lazyvim_phase → verify_phase(NVIM_ONLY)
```

时间线（UTC）：13:56 开始 → 13:56 目标 tag v0.12.6 → 14:09 依赖预播种完成 →
14:10 编译完成 → 14:11 Lazy sync 完成 → 验收通过，退出码 0。

### Neovim 阶段逻辑（现状）

- `latest_nvim_tag()`：`git ls-remote --tags` 取最新 `vX.Y.Z` tag，失败回退 `stable`。
- 最新实测 tag：`v0.12.6`；容器 CMake 3.16.3 满足其最低要求 3.16。
- 源码目录：`~/.devkit/src/neovim`
- 安装目录：`~/.devkit/nvim`
- 使用 `gh_clone`：直连 → `ghfast.top` → `gh-proxy.com`
- `preseed_nvim_deps()`：解析 `cmake.deps/deps.txt`，预下载依赖到
  `.deps/build/downloads`，带 SHA256 校验；本次 19 个命中、1 个失败由 cmake 自行下载。
- `make CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX=~/.devkit/nvim -j48`
- 编译失败会清 `.deps` 重试一次。
- 验收：非 musl、`nvim --headless +qa`。

### LazyVim 阶段逻辑（现状）

- `~/.config/nvim` 已存在时默认保留；`FORCE_LAZYVIM=1` 会备份旧配置。
- 克隆 `https://github.com/LazyVim/starter.git`
- 删除 `.git`，写入 `.devkit-managed` 标记
- `init.lua` 首行插入 `vim.g.clipboard = "osc52"`（容器无 X11/Wayland）
- `nvim --headless "+Lazy! sync" +qa`
- sync 失败不算安装失败，网络恢复后重跑即可续传。

### 已完成项与后续操作

1. **Treesitter CLI + parser（已完成，无需再装）**：
   `setup-ubuntu.sh` 的 `ts_cli_phase` 会编译并安装 musl 静态 CLI 与 wrapper；
   `UPDATE_TS_PARSERS=1` 时 `ts_parsers_phase` 在 20.04 容器内更新 parser。
   - CLI：`~/.devkit/musl/bin/tree-sitter.real`（0.27.2，static-PIE，无 INTERP）
   - wrapper：`~/.devkit/musl/bin/tree-sitter`，静态 musl 不能 dlopen 时，
     只要 `tree-sitter build -o parser.so` 已生成有效 ELF，就返回 0
   - 构建依赖：apt `libclang-dev`；bindgen 需 musl 头文件路径；
     不能用 `musl-gcc` 作 linker；需 `-L/usr/lib/x86_64-linux-musl` 找到空 `libdl.a`
   - 官方预编译 `tree-sitter-linux-x64` 依赖 glibc 2.39，20.04 不可用，因此源码编译
   - parser 必须在 20.04 容器内编译，才能得到低 glibc 基线供宿主/容器共用
   - 现状：CLI 0.27.2、parser 35 个，已全部与当前 `nvim-treesitter` main 对齐
2. **nvim PATH（已完成，改为通用）**：2026-11-11 起 `.bashrc` 托管块无条件把
   `~/.devkit/nvim/bin` 加入 PATH。宿主机 Ubuntu 20.04+ 与其他共享同一 home 的
   Ubuntu 20.04+ 容器都可直接 `nvim`（实测宿主机 22.04 / 容器 20.04）。
   glibc < 2.31 的容器（18.04、Alpine/musl）不能运行这个构建。
   非交互 shell 不读 `.bashrc`，脚本里仍用绝对路径。
3. **插件更新**：`nvim --headless "+Lazy! update" +qa`。
4. **parser 更新**：`NVIM_ONLY=1 SKIP_APT=1 UPDATE_TS_PARSERS=1 bash setup-ubuntu.sh`。
5. **重跑安装**：`NVIM_ONLY=1` 幂等；已完成的 nvim 会直接跳过，`FORCE_NVIM=1`
   可强制重编。

## 清理与状态

- 安装状态：`~/.devkit/state/setup.env`
- 当前记录（`SETUP_AT=2026-11-11T13:44:15+00:00`）：`RUST_ONLY=0`、`NPM_ONLY=0`、
  `NVIM_ONLY=1`、`NVIM_CONFIG_CREATED=1`；另有 `BASH_RC_CREATED=0`、
  `UV_LOCAL_PY_CREATED=1`、`UV_RECEIPT_CREATED=1`、`UV_SHARE_CREATED=1`。
  注意：文件内容来自 `NVIM_ONLY=1` 那次安装，不是最后一次完整安装；
  之后 `UPDATE_TS_PARSERS=1` 的补装没有刷新 `SETUP_AT`，核对时以文件内容为准。
- `NVIM_DATA_CREATED/NVIM_STATE_CREATED/NVIM_CACHE_CREATED=0`：这些目录在
  本次安装前已存在，因此清理脚本会保留它们，只删除由 setup 创建的
  `~/.config/nvim`（有 `.devkit-managed` 标记时）。
- 清理：
  ```bash
  docker exec -it ye_cheng_d3a5c06b /bin/bash -c \
    "su - ye_cheng -c 'bash /home/ye_cheng/work/project/devkit/devkit-cleanup.sh'"
  ```
- 清理会删除 `~/.devkit`、`.bashrc` 托管块，并按记录处理 nvim 配置和 uv 文件。

## 新对话开场建议

可以直接把下面这段发给新会话：

> 项目在 `/home/ye_cheng/work/project/devkit`，当前提交 `e8e68d3`。先读
> `docs/HANDOFF.md`、`setup-ubuntu.sh`、`docs/使用方法.md`。Rust 工具、hunk/Trellis、
> Neovim v0.12.6、LazyVim starter（32 个插件）、musl 静态 tree-sitter CLI 0.27.2
> 与 35 个 parser 均已安装并验证，Lazy sync 二次执行成功；容器
> `ye_cheng_d3a5c06b` 仍在运行。tree-sitter CLI 与 parser 无需再装。
> 可选下一步：处理 LazyVim `:checkhealth` 剩余的可选工具（lazygit/fzf 等）、
> 更新插件，或清理旧仓 `dev_dockerfiles` 里的过时副本。
