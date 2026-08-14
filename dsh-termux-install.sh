#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# dsh-termux-install.sh — DeepSeek Harness (dsh) 一键安装 / 修复脚本 (Termux/Android)
#
# 适用场景:
#   1) 新手机/全新环境 : 完整安装 dsh(含所有 Android 适配补丁)
#   2) dsh 升级之后    : 重跑本脚本, 重新应用补丁(幂等, 已打过的自动跳过)
#   3) Node 大版本更新后原生模块重编译失败 : 重跑本脚本(自动修补 node-gyp 头文件)
#
# 用法:
#   bash dsh-termux-install.sh               # 安装(已装则只打补丁)
#   bash dsh-termux-install.sh --reinstall   # 强制重装 dsh 包(升级用)
#   REGISTRY="" bash dsh-termux-install.sh   # 不用镜像(默认 npmmirror, 国内快)
#
# 本脚本固化的全部踩坑修复(对应本次部署实录):
#   [1] Termux 仓库没有 pnpm 包            -> npm install -g pnpm
#   [2] npm 官方源慢/不通                  -> 默认切 npmmirror, 可 REGISTRY 覆盖
#   [3] koffi 等原生模块编译缺工具         -> pkg 安装 cmake/ninja/libffi/clang/make/python
#   [4] node-gyp 报 "Undefined variable android_ndk_path"
#       (npm >= 11.10 内置 node-gyp >= 12.3 新增 Android 检测, Termux 被识别为 android 平台)
#                                         -> 降级 npm 到 11.9.0 (根治); gypi 补丁兜底
#   [5] dsh 会话持久化/附件用 link() 原子发布,
#       MIUI/HyperOS 的 SELinux 禁止 app 数据目录硬链接(EACCES)
#                                         -> 补丁: EACCES 时自动回退 rename()
#   [6] HMR 插件要求 --expose-internals, 而 NODE_OPTIONS 禁止该标志
#                                         -> 补丁: dsh 启动器缺标志时自动带参重执行
#   [7] @vscode/ripgrep 官方二进制是 glibc, Android(bionic) 无法运行
#                                         -> 用 Termux 版 ripgrep 替换
#   [8] sharp 原生模块部分设备加载失败    -> 自动补装 @img/sharp-wasm32 回退
# 说明: [5][6][7] 是直接改在安装包里的补丁, dsh 升级/重装后会被覆盖,
#       重新运行本脚本即可恢复。补丁锚点若在新版本中变化, 脚本会明确提示跳过。
# =============================================================================
set -uo pipefail

FORCE_REINSTALL=0
if [ "${1:-}" = "--reinstall" ]; then FORCE_REINSTALL=1; fi

# dsh 安装根目录(测试时可用 DSH_ROOT 覆盖)
DSH_ROOT="${DSH_ROOT:-$PREFIX/lib/node_modules/@deepseek-ai/dsh}"

# =============================================================================
# 以下为补丁函数定义
# =============================================================================

# [4] 修补 node-gyp 头文件: android_ndk_path 未定义 (降级 npm 可根治, 此为兜底)
patch_gypi() {
  local NODE_VER gp
  NODE_VER=$(node -p "process.versions.node" 2>/dev/null || echo "")
  [ -z "$NODE_VER" ] && return
  gp="$HOME/.cache/node-gyp/$NODE_VER/include/node/common.gypi"
  if [ ! -f "$gp" ]; then
    echo "  gypi: 未找到头文件缓存 $gp (由 npm install 生成), 跳过"
    return
  fi
  export DSH_GYPI="$gp"
  node <<'JS'
const fs = require("node:fs");
const p = process.env.DSH_GYPI;
let s = fs.readFileSync(p, "utf8");
if (s.includes("'android_ndk_path%'")) { console.log("  gypi: 已打过补丁, 跳过"); process.exit(0); }
if (!s.includes("'variables': {")) { console.log("  gypi: 未找到 variables 锚点, 跳过(请人工检查 " + p + ")"); process.exit(1); }
s = s.replace("'variables': {", "'variables': {\n    'android_ndk_path%': '',", 1);
fs.writeFileSync(p, s);
console.log("  gypi: 补丁已应用 -> " + p);
JS
}

# [5] 会话持久化 + 附件存储: link() -> EACCES 时回退 rename()
patch_link_rename() {
  export DSH_P1 DSH_P2
  DSH_P1=$(grep -rl --include=index.js "await link(tmp, finalPath);" "$DSH_ROOT" 2>/dev/null | head -1)
  DSH_P2=$(grep -rl --include=index.js "await link(temporary, target);" "$DSH_ROOT" 2>/dev/null | head -1)
  node <<'JS'
const fs = require("node:fs");
const p1 = process.env.DSH_P1 || "";
const p2 = process.env.DSH_P2 || "";
const T = "\t";
const L = "\n";

function apply(path, marker, oldsNews, label) {
  if (!path || !fs.existsSync(path)) { console.log("  " + label + ": 文件未找到, 跳过"); return; }
  let s = fs.readFileSync(path, "utf8");
  if (s.includes(marker)) { console.log("  " + label + ": 已打过补丁, 跳过"); return; }
  for (const [old, neu] of oldsNews) {
    if (!s.includes(old)) { console.log("  " + label + ": 锚点未找到(dsh 版本可能已更新), 跳过 -> " + path); return; }
  }
  for (const [old, neu] of oldsNews) s = s.replace(old, neu, 1);
  fs.writeFileSync(path, s);
  console.log("  " + label + ": 补丁已应用 -> " + path);
}

// dsh-session-persistence-jsonl: 把 link 发布改为 EACCES 时回退 rename
const P1_OLD = [
  "\t\tconst tmp = await this.writeSyncedTempFile(finalPath, content);",
  "\t\tlet linked = false;",
  "\t\ttry {",
  "\t\t\tawait link(tmp, finalPath);",
  "\t\t\tlinked = true;",
  "\t\t} finally {",
].join(L);
const P1_NEW = [
  "\t\tconst tmp = await this.writeSyncedTempFile(finalPath, content);",
  "\t\tlet linked = false;",
  "\t\ttry {",
  "\t\t\ttry {",
  "\t\t\t\tawait link(tmp, finalPath);",
  "\t\t\t} catch (error) {",
  "\t\t\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"EACCES\")) throw error;",
  "\t\t\t\tawait rename(tmp, finalPath);",
  "\t\t\t}",
  "\t\t\tlinked = true;",
  "\t\t} finally {",
].join(L);

apply(p1, "await rename(tmp, finalPath)", [
  ['import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";',
   'import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, stat, truncate } from "node:fs/promises";'],
  [P1_OLD, P1_NEW],
], "persistence-jsonl");

// dsh-attachment-local: link 改为 catch 内 EACCES 回退 rename, unlink 容忍 ENOENT
const P2_OLD = [
  "\t\ttry {",
  "\t\t\tawait link(temporary, target);",
  "\t\t} catch (error) {",
  "\t\t\t/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */",
  "\t\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"EEXIST\")) throw error;",
  "\t\t\tif (digest(new Uint8Array(await readFile(target))) !== sha256) throw new AttachmentError(\"Stored attachment failed integrity verification.\", \"ATTACHMENT_CORRUPT\");",
  "\t\t}",
].join(L);
const P2_NEW = [
  "\t\ttry {",
  "\t\t\tawait link(temporary, target).catch(async (error) => {",
  "\t\t\t\tif (error instanceof Error && \"code\" in error && error.code === \"EACCES\") {",
  "\t\t\t\t\tawait rename(temporary, target);",
  "\t\t\t\t\treturn;",
  "\t\t\t\t}",
  "\t\t\t\tthrow error;",
  "\t\t\t});",
  "\t\t} catch (error) {",
  "\t\t\t/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */",
  "\t\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"EEXIST\")) throw error;",
  "\t\t\tif (digest(new Uint8Array(await readFile(target))) !== sha256) throw new AttachmentError(\"Stored attachment failed integrity verification.\", \"ATTACHMENT_CORRUPT\");",
  "\t\t}",
].join(L);

apply(p2, "await rename(temporary, target)", [
  ['import { chmod, link, mkdir, open, readFile, unlink } from "node:fs/promises";',
   'import { chmod, link, mkdir, open, readFile, rename, unlink } from "node:fs/promises";'],
  [P2_OLD, P2_NEW],
  ["\t\tawait unlink(temporary);", "\t\tawait unlink(temporary).catch(() => {});"],
], "attachment-local");
JS
}

# [6] dsh 启动器: 缺 --expose-internals 时自动带参重执行
patch_bin_expose() {
  export DSH_BP="$DSH_ROOT/lib/bin.js"
  node <<'JS'
const fs = require("node:fs");
const p = process.env.DSH_BP;
if (!fs.existsSync(p)) { console.log("  bin.js: 文件未找到, 跳过"); process.exit(0); }
let s = fs.readFileSync(p, "utf8");
if (s.includes("--expose-internals")) { console.log("  bin.js: 已打过补丁, 跳过"); process.exit(0); }
const imp = 'import { readFileSync } from "node:fs";';
const impN = 'import { readFileSync } from "node:fs";' + "\n" + 'import { spawnSync } from "node:child_process";';
const L = "\n";
const anchor = ['import { Command, CommanderError } from "commander";', '//#region lib/types/args.js'].join(L);
const guard = [
  'import { Command, CommanderError } from "commander";',
  '// Termux/Android: cordis-plugin-hmr requires --expose-internals; re-exec with it when absent.',
  'if (!process.execArgv.includes("--expose-internals")) {',
  "\tconst { status } = spawnSync(process.execPath, [\"--expose-internals\", ...process.argv.slice(1)], { stdio: \"inherit\" });",
  "\tprocess.exit(status ?? 1);",
  '}',
  '//#region lib/types/args.js',
].join(L);
if (!s.includes(anchor)) { console.log("  bin.js: 锚点未找到(dsh 版本可能已更新), 跳过 -> " + p); process.exit(1); }
if (s.includes(imp)) s = s.replace(imp, impN, 1);
s = s.replace(anchor, guard, 1);
fs.writeFileSync(p, s);
console.log("  bin.js: 补丁已应用 -> " + p);
JS
}

# [8] sharp wasm32 回退: 部分设备/镜像漏装可选依赖, sharp 无法加载时补装
ensure_sharp_wasm() {
  local sharpDir
  sharpDir=$(find "$DSH_ROOT" -path "*/node_modules/sharp/package.json" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
  if [ -z "$sharpDir" ]; then
    echo "  sharp: 未找到安装包, 跳过"
    return
  fi
  if node -e "try{require(process.argv[1])}catch(e){process.exit(1)}" "$sharpDir" 2>/dev/null; then
    echo "  sharp: 加载正常"
  else
    echo "  sharp: 加载失败 -> 安装 @img/sharp-wasm32 回退..."
    npm install -g @img/sharp-wasm32 2>&1 | tail -2
    if node -e "try{require(process.argv[1])}catch(e){process.exit(1)}" "$sharpDir" 2>/dev/null; then
      echo "  sharp: wasm32 回退生效"
    else
      echo "  sharp: 仍加载失败, 请手动检查 (npm install -g @img/sharp-wasm32)"
    fi
  fi
}

# [7] 替换 ripgrep 为 Termux 版
fix_ripgrep() {
  command -v rg >/dev/null 2>&1 || { echo "  ripgrep: 系统 rg 不存在, 跳过"; return; }
  local vr nmdir target
  vr=$(find "$DSH_ROOT" -type d -path "*@vscode/ripgrep" 2>/dev/null | head -1)
  if [ -z "$vr" ]; then
    echo "  ripgrep: 未找到 @vscode/ripgrep 包, 跳过"
    return
  fi
  nmdir=$(dirname "$vr")
  target="$nmdir/ripgrep-linux-arm64/bin/rg"
  mkdir -p "$(dirname "$target")"
  cp "$(command -v rg)" "$target"
  chmod 755 "$target"
  echo "  ripgrep: 已替换为 Termux 版 -> $target"
}

echo "==== [1/6] 基础工具 (Termux) ===="
yes | pkg update
yes | pkg upgrade
pkg install -y nodejs git python make clang binutils cmake ninja libffi ripgrep openssh which \
  || { echo "!! pkg install 失败, 请检查网络/存储"; exit 1; }
echo "  基础工具 OK"

echo "==== [2/6] Node.js 与 npm 版本检查 ===="
NODE_VER=$(node -v 2>/dev/null || echo none)
echo "  Node: $NODE_VER"
NODE_MAJOR=$(echo "$NODE_VER" | sed -E 's/v([0-9]+).*/\1/')
if [ "${NODE_MAJOR:-0}" -lt 22 ]; then
  echo "!! 需要 Node >= 22 (dsh 依赖内置 node:sqlite)。请先: pkg install nodejs"
  exit 1
fi

NPM_VER=$(npm -v 2>/dev/null || echo none)
NPM_MAJOR=$(echo "$NPM_VER" | cut -d. -f1)
NPM_MINOR=$(echo "$NPM_VER" | cut -d. -f2)
echo "  npm: $NPM_VER"
if [ "$NPM_MAJOR" -eq 11 ] && [ "$NPM_MINOR" -ge 10 ]; then
  echo "  npm $NPM_VER 内置 node-gyp >= 12.3 含 android 检测 (android_ndk_path) -> 降级到 11.9.0"
  npm install -g npm@11.9.0 || { echo "!! npm 降级失败"; exit 1; }
  echo "  npm: $(npm -v)"
fi

echo "==== [3/6] pnpm 与 npm 镜像 ===="
corepack enable 2>/dev/null || true
if ! command -v pnpm >/dev/null 2>&1; then
  echo "  安装 pnpm (Termux 仓库无此包)..."
  npm install -g pnpm || { echo "!! pnpm 安装失败"; exit 1; }
fi
echo "  pnpm $(pnpm --version 2>/dev/null)"
REGISTRY="${REGISTRY:-https://registry.npmmirror.com}"
if [ -n "$REGISTRY" ]; then
  npm config set registry "$REGISTRY"
  pnpm config set registry "$REGISTRY"
  # node-gyp 下载 Node 头文件也走镜像(国内网络 nodejs.org 常不通, 这是新手机常见的失败点)
  # 注意: disturl 不是 npm 配置项, 必须用环境变量 npm_config_disturl (node-gyp 读取它)
  NODE_DISTURL="${NODE_DISTURL:-https://npmmirror.com/mirrors/node}"
  export npm_config_disturl="$NODE_DISTURL"
  echo "  npm/pnpm registry = $REGISTRY"
  echo "  node-gyp disturl(env) = $NODE_DISTURL"
fi

echo "==== [4/6] 安装 / 更新 dsh ===="
ERRLOG="$HOME/dsh-install-error.log"
if ! command -v dsh >/dev/null 2>&1 || [ "$FORCE_REINSTALL" = "1" ]; then
  echo "  npm install -g @deepseek-ai/dsh (首次或强制重装, 可能需要几分钟)..."
  if ! npm install -g @deepseek-ai/dsh 2>&1 | tee "$ERRLOG"; then
    echo "  首次安装失败 -> 修补 node-gyp 头文件后重试一次..."
    patch_gypi
    if ! npm install -g @deepseek-ai/dsh 2>&1 | tee -a "$ERRLOG"; then
      echo "!! dsh 安装失败(重试后)。完整日志已保存: $ERRLOG"
      echo "!! ===== 关键错误行 ====="
      grep -iE "npm error|EACCES|EADDRINUSE|ENOTFOUND|ETIMEDOUT|ERR_|android_ndk|gyp ERR|failed|Unable to locate" "$ERRLOG" | tail -25
      echo "!! ===== 补丁状态诊断 ====="
      NODE_VER=$(node -p "process.versions.node" 2>/dev/null || echo "?")
      GP="$HOME/.cache/node-gyp/$NODE_VER/include/node/common.gypi"
      if [ -f "$GP" ]; then
        grep -q "android_ndk_path%" "$GP" && echo "  gypi 已打补丁: $GP" || echo "  gypi 未打补丁(异常): $GP"
      else
        echo "  node-gyp 头文件缓存不存在: $GP"
        echo "  提示: 多半是下载头文件失败, 确认 npm_config_disturl 环境变量指向可用镜像"
      fi
      echo "!! 请把上面的\"关键错误行\"内容发给开发者排查"
      exit 1
    fi
  fi
else
  echo "  dsh 已安装: $(dsh --version 2>/dev/null || echo '?')"
fi

echo "==== [5/6] Android 适配补丁 (幂等) ===="
patch_gypi
patch_link_rename
patch_bin_expose
ensure_sharp_wasm
fix_ripgrep

echo "==== [6/6] 完成 ===="
dsh --version 2>/dev/null || true
cat <<'END'
------------------------------------------------------------
 启动:  dsh web --port 3080          # 前台, 退出 Termux 即停
        手机浏览器打开 http://127.0.0.1:3080
 停止:  Ctrl-C 或 pkill -f 'dsh web'
 后台:  dsh web --port 3080 > ~/web.log 2>&1 & disown
 升级:  npm update -g @deepseek-ai/dsh 之后重跑本脚本即可重新打补丁
------------------------------------------------------------
END
