# 共享 home 开发工具母机（Ubuntu 20.04）

用官方 `ubuntu:20.04` 容器作为“母机”，把通用开发工具装进共享 home，之后任何
挂载同一 home 的开发容器都能直接使用。

## 文件

| 文件 | 作用 |
|---|---|
| `setup-ubuntu.sh` | 在 ubuntu 20.04 容器内安装全部工具，幂等可重跑 |
| `devkit-cleanup.sh` | 完整删除安装制品，清理并还原 `.bashrc` 托管块 |
| `devkit-up.sh` | 宿主机侧启动母机容器（沿用你的 docker run 参数） |

## 制品布局

所有工具集中在一个根目录，清理时整目录删除即可：

```text
~/.devkit/
├── musl/bin/       musl 静态 Rust 工具 + tree-sitter CLI/wrapper
├── bin/            uv/uvx（musl 静态）与 python3 软链
├── nvim/           源码编译的 Neovim（glibc 2.31 基线）
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
再写新块，不影响其他内容。

## 方式一：一键启动并安装

```bash
cd ~/work/project/devkit        # 本仓库所在目录
./devkit-up.sh --setup
```

它会：

1. 用 `ubuntu:20.04` 后台启动容器，`--net=host`、home 映射、hostname、UID/GID、
   用户名都与你现有启动命令一致；
2. 通过 `docker exec <容器> /bin/bash`（root）创建同名用户，并只执行
   `APT_ONLY=1 setup-ubuntu.sh` 装系统依赖（curl/git/编译工具/musl 等）；
3. 通过 `docker exec <容器> /bin/bash -c "su - $USER -c '...'"` 以普通用户执行
   完整安装，所有 Rust 工具、nvim、node/npm、hunk、Trellis、uv/Python 都落到
   共享 home；
4. 最后用 `docker exec -it <容器> su - $USER` 进入普通用户 shell。

> 这个边界是强制的：完整安装不允许以 root 运行；root 只负责
> `APT_ONLY=1` 的系统依赖，避免 `~/.devkit` 里的文件属主变成 root。

只装 Rust 工具（当前阶段）：

```bash
./devkit-up.sh --rust
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
> 制品，避免把 `~/.devkit` 里文件的属主写成 root。

当前阶段只装 Rust 工具时，普通用户侧加 `RUST_ONLY=1`：

```bash
docker exec -it <容器> /bin/bash -c \
  "su - $USER -c 'RUST_ONLY=1 SKIP_APT=1 bash /home/$USER/work/project/devkit/setup-ubuntu.sh'"
```

## 安装内容

### Rust 工具（全部 musl 静态）

| 命令 | crate |
|---|---|
| `keifu` | `keifu` |
| `yazi` / `ya` | 官方 musl 预编译包；失败则源码编译（crates.io 包缺 preset 资源） |
| `gitui` | `gitui` |
| `ducker` | `ducker` |
| `eza` | `eza` |
| `bat` | `bat` |
| `rg`（ripgrep） | `ripgrep` |
| `fd`（fd-find） | `fd-find` |
| `btm`（bottom） | `bottom`（关闭 NVIDIA 监控以保持 musl 静态链接） |
| `zoxide` | `zoxide` |

编译参数：`--target x86_64-unknown-linux-musl` + `target-feature=+crt-static`。
Rust 现代 musl 默认产出 **static-PIE**：`file` 可能显示 `dynamically linked`，
但 `readelf -l` 没有 `INTERP` 段、`ldd` 显示 `statically linked`，脚本按
`PT_INTERP` 判定是否为静态，不满足会直接报错。

### 其他

- Neovim：`git ls-remote` 取最新 `vX.Y.Z` tag，源码编译到 `~/.devkit/nvim`；
- LazyVim：克隆 starter 到 `~/.config/nvim`，自动加 OSC52 剪贴板设置；
- Node.js 22 LTS：npmmirror 官方 tarball；
- uv + Python 3.12：为 Trellis 提供 `>=3.9` 解释器；
- hunk：npm 包 `hunkdiff`，默认固定 `0.24.0`（`0.24.1` 的 linux 平台包尚未同步到
  npmmirror；可用 `HUNK_VERSION=...` 覆盖）；
- Trellis：npm 包 `@mindfoldhq/trellis@latest`。

## 清理

```bash
# 在容器内以普通用户执行
bash /home/$USER/work/project/devkit/devkit-cleanup.sh
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
| `RUST_ONLY` | `0` | `1` 只装 Rust 工具和 yazi，跳过 nvim/node/npm/LazyVim |
| `NPM_ONLY` | `0` | `1` 只补 Node/uv/Python/hunk/Trellis（Rust 工具已存在则跳过），跳过 nvim/LazyVim |
| `NVIM_ONLY` | `0` | `1` 只做 nvim 源码编译 + `.bashrc` + LazyVim/Lazy sync，跳过 Rust/Node/uv/npm |
| `MIRROR` | `cn` | `official` 切回官方默认源 |
| `SKIP_APT` | `0` | 普通用户重跑时设为 `1` |
| `APT_ONLY` | `0` | root 只装系统依赖 |
| `APT_MIRROR` | `cn` | deb 源：`cn`=清华、`ustc`、`off`、主机名或完整 URL |
| `RUSTUP_DIST_SERVER` | `https://rsproxy.cn` | rustup 工具链源 |
| `RUSTUP_UPDATE_ROOT` | `$RUSTUP_DIST_SERVER/rustup` | rustup 自更新源 |
| `RUSTUP_INIT_URL` | 随 `RUSTUP_DIST_SERVER` | rustup-init.sh 地址 |
| `CARGO_REGISTRY` | `sparse+https://rsproxy.cn/index/` | cargo 源；`official` 用 crates.io |
| `PY_MIRROR` | NJU 镜像 | uv 下载 python-build-standalone 的镜像根 |
| `FORCE_NVIM` | `0` | 强制重编 nvim |
| `FORCE_TS_CLI` | `0` | 强制重编 tree-sitter CLI（musl 静态） |
| `UPDATE_TS_PARSERS` | `0` | `1` 安装/更新 LazyVim ensure_installed 的 parser |
| `TS_CLI_VERSION` | `0.27.2` | tree-sitter CLI 版本，必须 >=0.26.1 |
| `FORCE_RUST_TOOLS` | `0` | 强制重编所有 Rust 工具 |
| `FORCE_LAZYVIM` | `0` | 备份旧配置并重建 LazyVim |
| `WITH_OPENCODE` | `0` | 额外安装 opencode |
| `HUNK_VERSION` | `0.24.0` | hunk 版本 |
| `YAZI_VERSION` | 自动解析 | yazi 版本（默认取 rsproxy 最新） |
| `DEVKIT_ROOT` | `~/.devkit` | 制品根目录 |

公司镜像示例（按实际地址替换）：

```bash
APT_MIRROR=mirrors.corp.example.com \
RUSTUP_DIST_SERVER=https://mirrors.corp.example.com/rustup \
RUSTUP_UPDATE_ROOT=https://mirrors.corp.example.com/rustup \
CARGO_REGISTRY=sparse+https://mirrors.corp.example.com/crates.io-index/ \
SKIP_APT=1 RUST_ONLY=1 bash setup-ubuntu.sh
```

`APT_MIRROR` 若填完整 URL，需指向 ubuntu 仓库根（例如
`http://mirrors.corp.example.com/ubuntu`）；只填主机名时脚本自动补 `/ubuntu`。

## 耗时提示

首次完整安装会编译 11 个 Rust 工具、musl 静态 OpenSSL、Neovim 和 tree-sitter CLI，
另会下载 uv/Python；视机器性能大约 25–45 分钟。`UPDATE_TS_PARSERS=1` 时还会编译
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
