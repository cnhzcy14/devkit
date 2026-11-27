# Neovim 配置移出 devkit + tree-sitter 改 glibc

> 注：执行后 `dotfiles/nvim/` 临时目录已移出本仓，并入用户的个人 dotfiles 仓库；
> 本仓不再包含该目录。

**目标：** 只改 `setup-ubuntu.sh` 中原有的 heredoc #3–#7：
把 tree-sitter CLI 改成 glibc、去掉 wrapper；删除 devkit 对 LazyVim / Neovim 配置 /
parser 的全部管理，把现有配置迁到临时 `dotfiles/` 树。

**范围外（明确不做）：** 不把 cargo 配置（#1/#2）或 `.bashrc`（#9）迁到
`assets/` + `env.sh`；不改 Python shim（#8）。

**技术栈：** Bash、Lua、现有 devkit 目录布局。

## 全局约束

- `setup-ubuntu.sh` 保持幂等，可重复执行。
- `.bashrc` 标记块和 `devkit-cleanup.sh` 的清理逻辑继续有效。
- tree-sitter 仍放在 `~/.devkit/musl/bin`，但二进制是 glibc。
- Neovim 配置和 parser 清单不再由 devkit 写入。
- 不新增运行时依赖。

## 任务

### 1. tree-sitter CLI 改 glibc（heredoc #3）

- [x] 删除 `tree-sitter.real` 与 wrapper heredoc。
- [x] `cargo install tree-sitter-cli` 不再传 `--target`，不再使用 musl
      `RUSTFLAGS`；子 shell 里清掉 `CFLAGS`/`CXXFLAGS`，让 parser 用系统 `cc`。
- [x] 保留 `LIBCLANG_PATH`；运行时检查并拒绝 `ld-musl` 链接。
- [x] 安装位置仍为 `$MUSL_BIN/tree-sitter`。

### 2. 删除 Neovim 配置管理（heredoc #4–#7）

- [x] 删除 `FORCE_LAZYVIM`、`UPDATE_TS_PARSERS`、`NVIM_CONFIG`、`BACKUP_DIR`、
      `backup_path`、`use_glibc_cc_for_nvim`、`write_lazyvim_devkit_config`、
      `ensure_lazyvim_parsers`、`lazyvim_phase`、`ts_parsers_phase`。
- [x] nvim 自检改用 `nvim --headless -u NONE +qa`，避免加载用户配置。
- [x] 从 `verify_phase` 删除 LazyVim 插件数量检查。
- [x] `main` 不再调用已删除的 phase。

### 3. 清理脚本与启动脚本

- [x] `devkit-cleanup.sh` 不再删除/还原 `~/.config/nvim`；保留 nvim 运行数据
      （data/state/cache）和 `.bashrc` 块清理；发现旧 `.devkit-managed` 时只提示。
- [x] `devkit-up.sh` 从注释和 `ENV_KEYS` 移除 `UPDATE_TS_PARSERS`、`FORCE_LAZYVIM`。

### 4. 临时 dotfiles 树（已移出本仓）

- [x] `lua/plugins/devkit.lua`
- [x] `lua/plugins/treesitter.lua`
- [x] `lua/config/options.lua`
- [x] 临时目录内容已并入用户个人 dotfiles 仓库，devkit 不再包含该目录

### 5. 文档

- [x] `README.md`：移除退役开关，说明 Neovim 配置已移出 devkit。
- [x] `docs/使用方法.md`：tree-sitter 为 glibc 无 wrapper；Neovim 只装二进制；
      删除托管 LazyVim/parser/开关说明，改为说明配置已移出 devkit。
- [x] `docs/devkit.md`：同步架构、章节、开关与清理说明。
- [x] `docs/HANDOFF.md`：新增 2026-11-27 变更段并修正现状。

## 验证

- [x] `bash -n setup-ubuntu.sh devkit-cleanup.sh devkit-up.sh`
- [x] `grep -rn "tree-sitter.real\|FORCE_LAZYVIM\|UPDATE_TS_PARSERS\|lazyvim_phase\|ts_parsers_phase\|NVIM_CONFIG" . --exclude-dir=.git`
      仅应出现在历史记录/本计划中。
