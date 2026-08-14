# dsh-android-setup

DeepSeek Harness 一键安装脚本 for Termux/Android

## 概述

一键在 Termux (Android) 上安装 [DeepSeek Harness (dsh)](https://github.com/deepseek-ai/deepseek-harness)，并自动应用 Android 平台适配补丁。

本脚本以 **npm 全局包** 形式安装 `@deepseek-ai/dsh`，而非从源码编译。脚本幂等设计，已打过的补丁自动跳过；dsh 升级后重跑即可恢复被覆盖的补丁。

## 快速开始

```bash
# 安装（已装则只打补丁）
bash dsh-termux-install.sh

# 强制重装 dsh 包（升级用）
bash dsh-termux-install.sh --reinstall

# 不使用镜像（默认 npmmirror，国内加速）
REGISTRY="" bash dsh-termux-install.sh
```

## 系统要求

- Termux (建议 F-Droid 版)
- Node.js ≥ 22（dsh 依赖内置 `node:sqlite`）

## 自动修复的问题

| # | 问题 | 修复方式 |
|---|------|----------|
| 1 | Termux 仓库没有 pnpm 包 | `npm install -g pnpm` |
| 2 | npm 官方源慢/不通 | 默认切 npmmirror，可 `REGISTRY` 覆盖 |
| 3 | koffi 等原生模块编译缺工具 | pkg 安装 cmake/ninja/libffi/clang 等 |
| 4 | npm ≥ 11.10 内置 node-gyp ≥ 12.3 新增 Android 检测，报 `android_ndk_path` 未定义 | 降级 npm 到 11.9.0（根治）；gypi 补丁作为兜底 |
| 5 | MIUI/HyperOS SELinux 禁止硬链接 (EACCES) | `link()` EACCES 时自动回退 `rename()` |
| 6 | HMR 插件要求 `--expose-internals` | 启动器缺标志时自动带参重执行 |
| 7 | @vscode/ripgrep 是 glibc 二进制，bionic 无法运行 | 用 Termux 版 ripgrep 替换 |
| 8 | sharp 原生模块部分设备加载失败 | 自动补装 `@img/sharp-wasm32` 回退 |

## 使用 dsh

```bash
# 前台启动
dsh web --port 3080
# 手机浏览器打开 http://127.0.0.1:3080

# 后台运行
dsh web --port 3080 > ~/web.log 2>&1 & disown

# 停止
pkill -f 'dsh web'

# 升级后重打补丁
npm update -g @deepseek-ai/dsh
bash dsh-termux-install.sh
```

## 致谢

本脚本由 [DeepSeek Harness (dsh)](https://github.com/deepseek-ai/deepseek-harness) 生成并调试。

## License

MIT
