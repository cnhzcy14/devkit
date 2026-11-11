# devkit

共享 home 的 Ubuntu 20.04 开发工具安装/清理脚本。

- 使用方法：[docs/使用方法.md](docs/使用方法.md)
- 设计与清理细节：[docs/devkit.md](docs/devkit.md)
- 当前状态与下一步（Neovim/LazyVim）：[docs/HANDOFF.md](docs/HANDOFF.md)

脚本：

- `setup-ubuntu.sh`：安装入口，支持 `APT_ONLY` / `SKIP_APT` / `RUST_ONLY` / `NPM_ONLY` / `NVIM_ONLY` / `UPDATE_TS_PARSERS`
- `devkit-up.sh`：宿主机侧启动容器并执行安装
- `devkit-cleanup.sh`：删除 `~/.devkit` 和 `.bashrc` 托管块
