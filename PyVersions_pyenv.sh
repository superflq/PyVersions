#!/bin/bash
# ==============================================================================
# 脚本名称: PyVersions_pyenv.sh
# 版本:     v1.8.3 (与 PyVersions.ps1 同步演进)
# 适用系统: CentOS 7+, Debian 10+, Ubuntu 18.04+ (支持 x86_64 / aarch64)
# 功能描述: 免编译一键安装指定版本 Python —— 使用 python-build-standalone
#           官方预编译包(含 SHA256 完整性校验与标准库/pip 健康自检), 由 pyenv 统一管理,
#           不修改系统全局默认 Python。
#           - 无固化映射表: 无论是大版本号 (如 3.12) 还是精确版本 (如 3.12.16),
#             均通过 releases/latest & SHA256SUMS 动态匹配上游最新正式构建 (零 API 限流)
#           - 本地缓存优先与离线兜底: 压缩包缓存于 $PYENV_ROOT/cache，部署成功后自动
#             清理同版本的旧日期缓存包；精确版本优先命中本地缓存(坏包自动回退在线重下)，
#             大版本在线优先(命中缓存免下载)、断网自动降级本地缓存
#           - 交互式重装确认: 若目标版本已安装，自动交互询问是否覆盖重装 (默认不覆盖)
#           - 多线路镜像轮询下载 & 缺陷构建自动回退次新版本
#           - 无参数交互菜单: 部署 / 查看已安装 / 卸载 (设计对齐 PyVersions.ps1)
#           - 局域网代理加速: 优先于系统代理, TCP 探测连通即启用 (可配 LAN_PROXY_URLS)
# 使用方法: bash PyVersions_pyenv.sh                # 交互终端: 进入交互主菜单; 非交互环境: 默认安装 3.12
#           bash PyVersions_pyenv.sh 3.13          # 自动获取 3.13 系列上游最新 (启动参数模式)
#           bash PyVersions_pyenv.sh 3.12.16       # 优先本地缓存安装 3.12.16, 无则在线下载
#           bash PyVersions_pyenv.sh --help        # 显示帮助
# 退出码:   0 = 部署成功(或保留现有安装), 1 = 部署失败或参数无效
# 可选环境变量:
#           PYENV_ROOT 自定义 pyenv 安装目录 (默认: $HOME/.pyenv)
# ==============================================================================

set -euo pipefail

DEFAULT_VERSION="3.12"
# 下载加速线路 (按顺序尝试; 留空字符串表示 GitHub 直连)
DOWNLOAD_MIRRORS=("" "https://ghfast.top/" "https://gh-proxy.com/")
# 局域网代理加速 (优先于系统代理; 逐个 TCP 探测, 0.2 秒内连通即启用)
LAN_PROXY_URLS=("http://localhost:56666" "http://192.168.1.10:56666" "http://192.168.1.88:56666" "http://10.175.167.167:56666")
# 探测超时(秒): 与 PyVersions.ps1 的 200ms 对齐; 注意单位是秒, 勿误填 200 (那是 200 秒)
PROXY_PROBE_TIMEOUT="0.2"

# ---------- 0. 参数解析 ----------
usage() {
    cat << 'USAGE'
用法: bash PyVersions_pyenv.sh [版本号]
  不带参数 (交互终端): 进入交互主菜单 (部署 / 查看已安装 / 卸载)
  不带参数 (非交互环境): 直接部署 3.12 系列最新 (保持旧行为, 适合 cron/CI)
  大版本号 (如 3.11 / 3.12): 在线优先获取该系列最新构建 (命中本地缓存免下载, 断网降级本地)
  精确版本 (如 3.12.16 / 3.13.18): 优先使用本地缓存, 本地无则在线检索对应版本
  -h, --help: 显示本帮助
  注: 若目标版本已安装，脚本将自动交互询问是否强制覆盖重装 (默认不覆盖)。
示例:
  bash PyVersions_pyenv.sh                 # 交互主菜单 (终端) / 默认安装 3.12 (非交互)
  bash PyVersions_pyenv.sh 3.13            # 自动安装 3.13 系列最新
  bash PyVersions_pyenv.sh 3.12.16         # 优先本地缓存安装 3.12.16
USAGE
    exit 0
}
case "${1:-}" in
    -h|--help) usage ;;
esac

INPUT_VERSION=""
if [ $# -ge 1 ]; then
    INPUT_VERSION="$1"
    if ! [[ "$INPUT_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "错误: 版本号格式无效 '$INPUT_VERSION'，请输入类似 3.12 或 3.12.16 的格式 (或用 --help 查看用法)。"
        exit 1
    fi
fi

# ---------- 1. 架构识别与基础环境 ----------
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  URL_ARCH="x86_64-unknown-linux-gnu" ;;
    aarch64) URL_ARCH="aarch64-unknown-linux-gnu" ;;
    *)
        echo "错误: 不支持的架构: $ARCH"
        exit 1
        ;;
esac

PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
CACHE_DIR="$PYENV_ROOT/cache"

# ---------- 2. 基础依赖检查 ----------
MISSING_DEPS=""
for dep in curl git tar sha256sum mktemp awk sort head tr timeout getent; do
    command -v "$dep" >/dev/null 2>&1 || MISSING_DEPS="$MISSING_DEPS $dep"
done
if [ -n "$MISSING_DEPS" ]; then
    echo "错误: 缺失基础工具$MISSING_DEPS (请先使用 yum/apt 安装)"
    exit 1
fi

TMP_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pyversions_pyenv.XXXXXX")
cleanup() { rm -rf "$TMP_WORK_DIR"; }
trap cleanup EXIT

# ---------- SHA256SUMS 清单缓存目录 ----------
# 按用户隔离存放于 /tmp (FHS 短命文件位; 重启/系统清理后缓存失效, 重下仅几十 KB 代价可忽略)
# 失败时回退本次运行的 mktemp 目录 (仍可用, 仅失去跨运行缓存)
SUMS_DIR="${TMPDIR:-/tmp}/pyversions_sums-$UID"
if ! mkdir -p "$SUMS_DIR" 2>/dev/null; then
    SUMS_DIR="$TMP_WORK_DIR"
fi
# 迁移清扫: v1.8.1 及之前清单缓存在 pyenv cache 目录, 统一移至 SUMS_DIR
rm -f "$CACHE_DIR"/SHA256SUMS-* 2>/dev/null || true

# ---------- 下载代理解析 (优先于系统代理, 与 PyVersions.ps1 行为对齐) ----------
# 结果按次传给 curl (-x) / git (-c http.proxy), 不改写 http_proxy/https_proxy 环境变量,
# 也不改动任何系统代理配置 (局域网代理只是"拿来用", 不是"替换")
# 惰性解析: 不在启动时探测, 由 ensure_proxy 在真正触网前调用 (每次部署重新解析一次)
ACTIVE_PROXY=""
CURL_PROXY_ARGS=""
GIT_PROXY_ARGS=""
setup_proxy() {
    # 重置上次解析结果 (可在同一会话内多次调用, 始终反映当前网络状况)
    ACTIVE_PROXY=""
    CURL_PROXY_ARGS=""
    GIT_PROXY_ARGS=""
    # 1. 用户预设的代理环境变量: 直接沿用 (优先级最高, 不做任何改动)
    if [ -n "${http_proxy:-}" ] || [ -n "${https_proxy:-}" ] || [ -n "${HTTP_PROXY:-}" ] || [ -n "${HTTPS_PROXY:-}" ]; then
        ACTIVE_PROXY="${http_proxy:-${https_proxy:-${HTTP_PROXY:-${HTTPS_PROXY:-}}}}"
        echo "使用预设代理环境变量: $ACTIVE_PROXY (不改动任何配置)。"
        return 0
    fi
    # 2. 局域网代理探测: 连通即用于本次下载
    local url host port probe_ip ips probe_ok=0
    for url in "${LAN_PROXY_URLS[@]}"; do
        host=$(printf '%s' "$url" | sed -E 's#^https?://##; s#:[0-9]+$##')
        port=$(printf '%s' "$url" | grep -oE ':[0-9]+$' | tr -d ':')
        # 配置项白名单校验 (仅允许 host:port 形态, 防意外注入)
        if ! [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
            continue
        fi
        echo "探测局域网代理: $url (超时 ${PROXY_PROBE_TIMEOUT}s) ..."
        # 解析主机名后优先探测 IPv4 地址 (localhost 可能先解析到 IPv6, /dev/tcp 直连会挂起)
        ips=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | awk '!seen[$0]++' || true)
        [ -n "$ips" ] || ips="$host"
        for probe_ip in $ips; do
            if timeout "$PROXY_PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/$probe_ip/$port" 2>/dev/null; then
                probe_ok=1
                break
            fi
        done
        if [ "$probe_ok" -eq 1 ]; then
            ACTIVE_PROXY="$url"
            CURL_PROXY_ARGS="-x $url"
            GIT_PROXY_ARGS="-c http.proxy=$url"
            echo "已启用局域网代理加速: $url (仅用于本次下载, 不改动系统代理配置)。"
            return 0
        fi
    done
    echo "局域网代理均不可达, 转用系统代理/直连。"
    return 0
}
PROXY_READY=0
ensure_proxy() {
    [ "$PROXY_READY" -eq 1 ] && return 0
    setup_proxy
    PROXY_READY=1
}

# 多线路轮询下载: download_with_mirrors <原始GitHub_URL> <输出路径>
download_with_mirrors() {
    local raw_url="$1"
    local out_path="$2"
    local mirror try_url

    for mirror in "${DOWNLOAD_MIRRORS[@]}"; do
        try_url="${mirror}${raw_url}"
        if [ -n "$mirror" ]; then
            echo "尝试镜像线路: $mirror"
        else
            echo "尝试 GitHub 直连..."
        fi
        if curl $CURL_PROXY_ARGS --fail --location --retry 2 --retry-delay 2 \
                --connect-timeout 15 --progress-bar "$try_url" -o "$out_path"; then
            # 校验文件大小 (>1MB 排除网关错误页)
            if [ -s "$out_path" ] && [ "$(wc -c < "$out_path")" -gt 1048576 ]; then
                return 0
            fi
        fi
        rm -f "$out_path"
        echo "该线路下载失败，切换下一线路..."
    done
    return 1
}

# 多线路克隆 Git 仓库
git_clone_with_mirrors() {
    local repo_url="$1"
    local dest_dir="$2"
    local mirror try_url

    for mirror in "${DOWNLOAD_MIRRORS[@]}"; do
        try_url="${mirror}${repo_url}"
        if [ -n "$mirror" ]; then
            echo "尝试通过镜像克隆 pyenv: $mirror"
        else
            echo "尝试 GitHub 直连克隆 pyenv..."
        fi
        if GIT_TERMINAL_PROMPT=0 git $GIT_PROXY_ARGS -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 \
                clone --depth 1 "$try_url" "$dest_dir"; then
            return 0
        fi
        rm -rf "$dest_dir"
    done
    return 1
}

# ---------- 3. 本地缓存扫描与上游动态检索 ----------
# 扫描 $CACHE_DIR 中匹配目标版本与架构的本地压缩包, 按版本+构建日期降序输出: "版本|构建日期|文件路径"
scan_local_cache() {
    local target="$1"
    [ -d "$CACHE_DIR" ] || return 0
    local f base ver tag
    for f in "$CACHE_DIR"/cpython-*-"${URL_ARCH}"-install_only.tar.gz; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        if [[ "$base" =~ ^cpython-([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]{8})- ]]; then
            ver="${BASH_REMATCH[1]}"
            tag="${BASH_REMATCH[2]}"
            if [[ "$target" =~ ^[0-9]+\.[0-9]+$ ]]; then
                [[ "$ver" == "${target}."* ]] || continue
            else
                [[ "$ver" == "$target" ]] || continue
            fi
            echo "${ver}|${tag}|${f}"
        fi
    done | sort -t'|' -k1,1Vr -k2,2nr
}

# 轻量级查询上游构建列表 (绕过 GitHub API 限流):
# 1) 优先通过 releases/latest HTTP 302 重定向提取最新 Tag + releases.atom 获取次新 Tag (用于跨构建日期回退)
# 2) 下载对应 SHA256SUMS (仅几十 KB) 提取精确匹配项 (最多返回前 3 个最优构建)
query_upstream_candidates() {
    local target="$1"
    local tags=()
    local latest_tag=""
    local mirror
    # 注意: 本函数经 < <( ... ) 进程替换调用, stdout 会进入候选管道,
    # 因此 ensure_proxy (含交互提示) 必须在调用方的主 shell 上下文执行

    echo "正在查询上游 GitHub Releases [$target] ..." >&2

    # 1. 直连 HEAD 请求 releases/latest 获取最新 Tag
    latest_tag=$(curl $CURL_PROXY_ARGS -sI --connect-timeout 10 \
        "https://github.com/astral-sh/python-build-standalone/releases/latest" \
        | grep -i '^location:' | grep -oE '[0-9]{8}' | tail -n 1 || true)
    [ -n "$latest_tag" ] && tags+=("$latest_tag")

    # 2. 通过 releases.atom 获取最近 3 个 Release Tag (直连失败时兜底，同时为健康自检失败提供次新构建回退)
    local atom_tags=""
    for mirror in "${DOWNLOAD_MIRRORS[@]}"; do
        atom_tags=$(curl $CURL_PROXY_ARGS -fsSL --connect-timeout 10 \
            "${mirror}https://github.com/astral-sh/python-build-standalone/releases.atom" 2>/dev/null \
            | grep -oE 'releases/tag/[0-9]{8}' | grep -oE '[0-9]{8}' | awk '!seen[$0]++' | head -n 3 || true)
        [ -n "$atom_tags" ] && break
    done

    local t
    for t in $atom_tags; do
        local exists=0
        local existing
        for existing in "${tags[@]:-}"; do
            [ "$existing" = "$t" ] && exists=1 && break
        done
        [ "$exists" -eq 0 ] && tags+=("$t")
        [ ${#tags[@]} -ge 3 ] && break
    done

    # 3. 兜底: releases.atom 偶发滞后于 API, 通过 GitHub API 拉取最近 3 个标签
    #    (补齐旧大版本盲区, 对齐 PyVersions.ps1 的 API 回退通道; 标签仍走 SHA256SUMS 精确匹配)
    if [ ${#tags[@]} -eq 0 ]; then
        local api_tags t2
        api_tags=$(curl $CURL_PROXY_ARGS -fsSL --connect-timeout 10 \
            "https://api.github.com/repos/astral-sh/python-build-standalone/releases?per_page=3" 2>/dev/null \
            | grep -oE '"tag_name":[ ]*"[0-9]{8}"' | grep -oE '[0-9]{8}' | awk '!seen[$0]++' | head -n 3 || true)
        if [ -n "$api_tags" ]; then
            echo "提示: 302/atom 均未取到标签, 已通过 GitHub API 兜底。" >&2
            for t2 in $api_tags; do
                tags+=("$t2")
                [ ${#tags[@]} -ge 3 ] && break
            done
        fi
    fi

    if [ ${#tags[@]} -eq 0 ]; then
        echo "提示: 无法获取上游 Release 标签 (网络不通或镜像暂不可用)。" >&2
        return 0
    fi

    # 3. 逐个检索候选 Tag 的 SHA256SUMS 清单
    local results=""
    for t in "${tags[@]}"; do
        local sums_cache="$SUMS_DIR/SHA256SUMS-${t}"
        local sums_file=""

        if [ -s "$sums_cache" ]; then
            sums_file="$sums_cache"
        else
            local sums_url="https://github.com/astral-sh/python-build-standalone/releases/download/${t}/SHA256SUMS"
            for mirror in "${DOWNLOAD_MIRRORS[@]}"; do
                if curl $CURL_PROXY_ARGS -fsSL --retry 2 --connect-timeout 12 "${mirror}${sums_url}" -o "${sums_cache}.part" 2>/dev/null; then
                    mv "${sums_cache}.part" "$sums_cache"
                    sums_file="$sums_cache"
                    break
                fi
                rm -f "${sums_cache}.part"
            done
        fi

        [ -n "$sums_file" ] || continue

        local tag_matches
        tag_matches=$(awk -v arch="$URL_ARCH" -v tag="$t" -v ver="$target" '
            BEGIN {
                v_esc = ver; gsub(/\./, "\\.", v_esc)
                if (ver ~ /^[0-9]+\.[0-9]+$/) {
                    pat = "^cpython-" v_esc "\\.[0-9]+\\+" tag "-" arch "-install_only\\.tar\\.gz$"
                } else {
                    pat = "^cpython-" v_esc "\\+" tag "-" arch "-install_only\\.tar\\.gz$"
                }
            }
            $2 ~ pat {
                fname = $2
                pyver = fname; sub("^cpython-", "", pyver); sub("\\+.*", "", pyver)
                url = "https://github.com/astral-sh/python-build-standalone/releases/download/" tag "/" fname
                print pyver "|" tag "|" fname "|" url
            }
        ' "$sums_file")

        if [ -n "$tag_matches" ]; then
            results=$(printf "%s\n%s" "$results" "$tag_matches" | sed '/^$/d')
            # 如果已在最新 Release 找到匹配，且只需要 1 个主构建，可继续顺带取 1 个次新 tag 作回退即停
            local found_count
            found_count=$(echo "$results" | wc -l)
            [ "$found_count" -ge 2 ] && break
        fi
    done

    if [ -n "$results" ]; then
        echo "$results" | sort -t'|' -k1,1Vr -k2,2nr -u | head -n 3
    fi
}

# (候选队列组装 / pyenv 环境安装 / 部署执行 已统一移入下方 deploy_flow,
#  以支持"无参数进入交互菜单"与"带参数直接部署"两种入口)

# 清理同版本的旧日期缓存包 (仅保留刚刚部署成功的最新包)
cleanup_old_caches() {
    local ver="$1"
    local keep_file="$2"
    local old_f
    for old_f in "$CACHE_DIR"/cpython-"${ver}"+*-"${URL_ARCH}"-install_only.tar.gz; do
        [ -f "$old_f" ] || continue
        if [ "$old_f" != "$keep_file" ]; then
            echo "清理同版本旧日期缓存: $(basename "$old_f")"
            rm -f "$old_f"
        fi
    done
}

# 收尾汇总与常用命令速查面板
print_summary_and_cheatsheet() {
    local ver="$1"
    local status_msg="$2"

    echo "刷新 pyenv 路由表..."
    "$PYENV_ROOT/bin/pyenv" rehash

    echo "=================================================="
    echo "$status_msg"
    echo "=================================================="
    echo "当前 pyenv 已管理的版本列表："
    "$PYENV_ROOT/bin/pyenv" versions
    echo "--------------------------------------------------"
    echo "本地缓存目录: $CACHE_DIR"
    echo "提示: 本脚本未修改系统的默认 Python 版本。"
    echo ""
    echo "【常用 pyenv 命令速查】"
    echo "  1. 刷新当前终端环境变量 (首次安装必执行):"
    echo "     exec \$SHELL"
    echo ""
    echo "  2. 查看状态与已安装版本:"
    echo "     pyenv versions                  # 列出所有已安装版本 (* 为当前生效版本)"
    echo "     pyenv version                   # 查看当前生效的 Python 版本及生效来源"
    echo "     pyenv which python              # 查看当前 python 可执行文件的实际路径"
    echo ""
    echo "  3. 切换 Python 版本 (三种作用域):"
    echo "     pyenv local $ver              # [推荐] 仅对当前目录及子目录生效 (生成 .python-version)"
    echo "     pyenv local --unset             # 取消当前目录的版本绑定"
    echo "     pyenv global $ver             # 设为当前用户的全局默认版本"
    echo "     pyenv global system             # 恢复使用系统自带的默认 Python"
    echo "     pyenv shell $ver              # 仅对当前终端会话临时生效"
    echo ""
    echo "  4. 虚拟环境与依赖管理 (基于指定版本):"
    echo "     $PYENV_ROOT/versions/$ver/bin/python -m venv .venv   # 创建独立虚拟环境"
    echo "     source .venv/bin/activate                                   # 激活虚拟环境"
    echo ""
    echo "  5. 卸载与重装:"
    echo "     pyenv uninstall $ver          # 卸载指定版本的 Python (保留本地缓存)"
    echo "     bash $0 $ver                   # 重新运行并交互确认是否覆盖重装"
    echo "=================================================="
}

# ---------- 5. 候选部署执行器 (含 SHA256 校验、标准库/pip 健康自检与次新自动回退) ----------
# (DEPLOY_SUCCESS / FINAL_VERSION 等状态变量统一在 deploy_flow 内初始化)

deploy_from_queue() {
    local cand
    for cand in "$@"; do
        IFS='|' read -r src_type EXACT_VERSION RELEASE_TAG TARBALL_NAME LOCATION <<< "$cand"
        TARGET_DIR="$PYENV_ROOT/versions/${EXACT_VERSION}"
        CACHE_FILE="$CACHE_DIR/$TARBALL_NAME"

        echo "=================================================="
        echo "候选版本: Python $EXACT_VERSION (构建日期: $RELEASE_TAG, 来源: $src_type)"
        echo "=================================================="

        # 幂等检查 + 交互确认是否覆盖重装 (默认 N 不覆盖, 同次运行已确认则不重复询问)
        if [ "$USER_CONFIRMED_REINSTALL" -ne 1 ] && [ -x "$TARGET_DIR/bin/python3" ] \
           && "$TARGET_DIR/bin/python3" --version 2>/dev/null | grep -qE "^Python ${EXACT_VERSION//./\\.}$"; then
            echo "检测到 Python $EXACT_VERSION 已安装于: $TARGET_DIR"
            local confirm_reinstall="N"
            if [ -t 0 ]; then
                read -r -p "是否强制覆盖重装？(此操作将清空该版本已装的第三方 pip 包) [y/N]: " confirm_reinstall || confirm_reinstall="N"
            elif [ -r /dev/tty ]; then
                read -r -p "是否强制覆盖重装？(此操作将清空该版本已装的第三方 pip 包) [y/N]: " confirm_reinstall </dev/tty || confirm_reinstall="N"
            else
                echo "当前为非交互式终端，默认不覆盖现有版本。"
            fi

            if [[ ! "$confirm_reinstall" =~ ^[Yy]$ ]]; then
                print_summary_and_cheatsheet "$EXACT_VERSION" "已保留现有 Python $EXACT_VERSION，跳过安装。"
                REINSTALL_SKIPPED=1
                return 0
            fi
            USER_CONFIRMED_REINSTALL=1
            echo "已确认强制覆盖重装 Python $EXACT_VERSION ..."
        fi

        # 获取压缩包 (命中本地缓存则免下载; 正常下载后保留于 $CACHE_DIR)
        if [ -f "$CACHE_FILE" ] && [ "$(wc -c < "$CACHE_FILE")" -gt 1048576 ]; then
            echo "发现本地有效缓存: $CACHE_FILE，跳过下载。"
        elif [ "$src_type" = "online" ]; then
            CACHE_TMP="$TMP_WORK_DIR/${TARBALL_NAME}.part"
            echo "下载预编译包: $TARBALL_NAME"
            if ! download_with_mirrors "$LOCATION" "$CACHE_TMP"; then
                echo "警告: $TARBALL_NAME 所有线路均下载失败，尝试回退次新构建..."
                continue
            fi
            mv "$CACHE_TMP" "$CACHE_FILE"
        else
            echo "警告: 本地缓存文件不可用: $LOCATION，尝试后续候选..."
            continue
        fi

        # SHA256 校验: 复用 SUMS_DIR 缓存清单, 缺失时按需下载
        SUMS_FILE="$SUMS_DIR/SHA256SUMS-${RELEASE_TAG}"
        if [ ! -f "$SUMS_FILE" ]; then
            ensure_proxy
            SUMS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${RELEASE_TAG}/SHA256SUMS"
            for mirror in "${DOWNLOAD_MIRRORS[@]}"; do
                if curl $CURL_PROXY_ARGS -fsSL --retry 2 --connect-timeout 10 "${mirror}${SUMS_URL}" -o "${SUMS_FILE}.part" 2>/dev/null; then
                    mv "${SUMS_FILE}.part" "$SUMS_FILE"
                    break
                fi
                rm -f "${SUMS_FILE}.part"
            done
        fi

        if [ -f "$SUMS_FILE" ]; then
            EXPECTED=$(awk -v t="$TARBALL_NAME" '$2 == t {print $1; exit}' "$SUMS_FILE")
            if [ -n "$EXPECTED" ]; then
                ACTUAL=$(sha256sum "$CACHE_FILE" | awk '{print $1}')
                if [ "$EXPECTED" != "$ACTUAL" ]; then
                    echo "警告: $TARBALL_NAME SHA256 校验失败！删除损坏缓存并尝试回退..."
                    rm -f "$CACHE_FILE"
                    continue
                fi
                echo "SHA256 校验通过"
            fi
        fi

        # 解压到暂存区并执行构建健康自检 (检查 glob/pathlib/pip 导入及 sitecustomize)
        STAGE_DIR="$TMP_WORK_DIR/stage-${EXACT_VERSION}-${RELEASE_TAG}"
        rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"
        echo "解压并执行标准库与 pip 健康自检..."
        if ! tar -xzf "$CACHE_FILE" -C "$STAGE_DIR" --strip-components=1; then
            echo "警告: 解压失败，删除损坏缓存并尝试回退..."
            rm -f "$CACHE_FILE"
            continue
        fi

        HEALTH_OUT=$("$STAGE_DIR/bin/python3" -c "import glob, pathlib, pip; print('HEALTH_OK')" 2>&1 || true)
        if [[ "$HEALTH_OUT" != *"HEALTH_OK"* ]] || [[ "$HEALTH_OUT" == *"Error in sitecustomize"* ]] || [[ "$HEALTH_OUT" == *"ImportError"* ]]; then
            echo "警告: 构建自检未通过 (标准库或 pip 异常)，该构建可能存在上游缺陷！删除缺陷缓存并尝试回退..."
            echo "自检输出: $HEALTH_OUT"
            rm -f "$CACHE_FILE"
            continue
        fi
        echo "构建健康自检通过！"

        # 原子替换挂载至 pyenv
        mkdir -p "$(dirname "$TARGET_DIR")"
        rm -rf "$TARGET_DIR" && mv "$STAGE_DIR" "$TARGET_DIR"
        DEPLOY_SUCCESS=1
        FINAL_VERSION="$EXACT_VERSION"
        FINAL_CACHE_FILE="$CACHE_FILE"
        return 0
    done
    return 1
}

# ---------- 6. 统一部署流程 (队列组装 + pyenv 环境 + 执行 + 兜底 + 收尾) ----------
# 用法: deploy_flow <版本号> [force_online]
#   force_online=1: 跳过精确版本的"本地缓存优先", 直接收在线队列 (菜单 o [版本] 使用)
# 返回: 0 = 部署成功或已保留现有安装; 1 = 部署失败
deploy_flow() {
    local input_version="$1"
    local force_online="${2:-0}"
    local CANDIDATE_QUEUE=()
    local NEED_ONLINE_FALLBACK=0
    local cand ver tag fname url fpath
    REINSTALL_SKIPPED=0
    DEPLOY_SUCCESS=0
    FINAL_VERSION=""
    FINAL_CACHE_FILE=""
    USER_CONFIRMED_REINSTALL=0
    PROXY_READY=0   # 每次部署重新解析代理 (局域网代理可能在两次部署间上线/下线)

    # 组装初始候选队列: 每项格式 "来源(local/online)|版本|ReleaseTag|文件名|路径或URL"
    if [ -n "${FORCED_LOCAL_QUEUE:-}" ]; then
        # 交互菜单指定编号: 强制使用某个本地缓存包
        while IFS= read -r cand; do
            [ -n "$cand" ] && CANDIDATE_QUEUE+=("$cand")
        done <<< "$FORCED_LOCAL_QUEUE"
        echo "使用指定的本地缓存包: ${FORCED_LOCAL_QUEUE##*|}"
    elif [[ "$input_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$force_online" != "1" ]; then
        # 精确版本: 本地缓存优先 (按构建日期降序排列, 命中则 0 秒秒装不触网)
        while IFS='|' read -r ver tag fpath; do
            [ -n "$ver" ] && CANDIDATE_QUEUE+=("local|${ver}|${tag}|$(basename "$fpath")|${fpath}")
        done < <(scan_local_cache "$input_version")

        if [ ${#CANDIDATE_QUEUE[@]} -gt 0 ]; then
            echo "命中本地缓存精确版本: $input_version (共 ${#CANDIDATE_QUEUE[@]} 个构建，优先使用最新)"
            NEED_ONLINE_FALLBACK=1
        else
            echo "本地缓存未命中精确版本 [$input_version]，转在线检索..."
            ensure_proxy
            while IFS='|' read -r ver tag fname url; do
                [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$tag" =~ ^[0-9]{8}$ && -n "$fname" ]] || continue
                CANDIDATE_QUEUE+=("online|${ver}|${tag}|${fname}|${url}")
            done < <(query_upstream_candidates "$input_version")
        fi
    else
        # 大版本号 (如 3.12): 在线优先获取最新构建 (本地命中同名缓存免下载), 断网自动降级本地缓存
        ensure_proxy
        while IFS='|' read -r ver tag fname url; do
            [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$tag" =~ ^[0-9]{8}$ && -n "$fname" ]] || continue
            CANDIDATE_QUEUE+=("online|${ver}|${tag}|${fname}|${url}")
        done < <(query_upstream_candidates "$input_version")

        # 强制在线 (o [版本]) 失败时不降级本地, 与 PyVersions.ps1 的严格 o 语义一致
        if [ ${#CANDIDATE_QUEUE[@]} -eq 0 ] && [ "$force_online" != "1" ]; then
            echo "警告: 上游检索失败或无匹配资源，自动降级使用本地缓存 [$input_version.x]..."
            while IFS='|' read -r ver tag fpath; do
                [ -n "$ver" ] && CANDIDATE_QUEUE+=("local|${ver}|${tag}|$(basename "$fpath")|${fpath}")
            done < <(scan_local_cache "$input_version")
        fi
    fi

    if [ ${#CANDIDATE_QUEUE[@]} -eq 0 ]; then
        echo "错误: 未能找到任何可用的 [$input_version] ($ARCH) 安装包（在线检索失败且无本地缓存）。"
        return 1
    fi

    # ---------- 安装与配置 pyenv ----------
    if [ ! -x "$PYENV_ROOT/bin/pyenv" ]; then
        if [ -d "$PYENV_ROOT" ] && [ -n "$(ls -A "$PYENV_ROOT" 2>/dev/null)" ]; then
            echo "错误: $PYENV_ROOT 已存在但缺少可执行的 bin/pyenv，请检查处理后重试。"
            return 1
        fi
        echo "安装 pyenv 基础环境..."
        ensure_proxy
        rm -rf "$PYENV_ROOT"
        if ! git_clone_with_mirrors "https://github.com/pyenv/pyenv.git" "$PYENV_ROOT"; then
            echo "错误: 无法克隆 pyenv 仓库，请检查网络连接。"
            return 1
        fi
    fi
    export PYENV_ROOT
    export PATH="$PYENV_ROOT/bin:$PATH"

    local RC_FILE
    for RC_FILE in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        if [ -f "$RC_FILE" ] && ! grep -q "pyenv init" "$RC_FILE"; then
            cat << EOF >> "$RC_FILE"

# pyenv env config
export PYENV_ROOT="$PYENV_ROOT"
command -v pyenv >/dev/null || export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init -)"
EOF
        fi
    done

    mkdir -p "$CACHE_DIR"

    # ---------- 执行部署 ----------
    deploy_from_queue "${CANDIDATE_QUEUE[@]}" || true

    # 用户已确认保留现有安装: 直接收尾, 不再触发在线兜底
    if [ "${REINSTALL_SKIPPED:-0}" -eq 1 ]; then
        return 0
    fi

    # 若精确版本命中本地缓存但全部损坏，按需延迟触发在线检索兜底
    if [ "$DEPLOY_SUCCESS" -ne 1 ] && [ "$NEED_ONLINE_FALLBACK" -eq 1 ]; then
        echo "本地缓存未能成功部署 [$input_version]，触发在线检索兜底..."
        local ONLINE_QUEUE=()
        ensure_proxy
        while IFS='|' read -r ver tag fname url; do
            [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$tag" =~ ^[0-9]{8}$ && -n "$fname" ]] || continue
            ONLINE_QUEUE+=("online|${ver}|${tag}|${fname}|${url}")
        done < <(query_upstream_candidates "$input_version")

        if [ ${#ONLINE_QUEUE[@]} -gt 0 ]; then
            deploy_from_queue "${ONLINE_QUEUE[@]}" || true
        fi
    fi

    if [ "$DEPLOY_SUCCESS" -ne 1 ]; then
        echo "错误: 所有候选构建均部署失败（下载失败或自检未通过），请检查网络后重试。"
        return 1
    fi

    # 清理同版本旧日期缓存，仅保留本次成功部署的最新包
    cleanup_old_caches "$FINAL_VERSION" "$FINAL_CACHE_FILE"

    print_summary_and_cheatsheet "$FINAL_VERSION" "Python $FINAL_VERSION 部署完成！"
    return 0
}

# ---------- 7. 交互主菜单 (无参数 + 交互终端时进入, 设计对齐 PyVersions.ps1) ----------
LISTED_PATHS=()
FORCED_LOCAL_QUEUE=""

# 扫描本地缓存包 (同精确版本多日期仅显示最新), 按版本降序存入全局数组 LISTED_PATHS
list_local_cache_menu() {
    LISTED_PATHS=()
    local f base ver lines="" sorted
    declare -A seen=()
    [ -d "$CACHE_DIR" ] || return 0
    for f in "$CACHE_DIR"/cpython-*-"${URL_ARCH}"-install_only.tar.gz; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        if [[ "$base" =~ ^cpython-([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]{8})- ]]; then
            ver="${BASH_REMATCH[1]}"
            [[ -n "${seen[$ver]:-}" ]] && continue
            seen["$ver"]=1
            lines="${lines}${ver}|${f}"$'\n'
        fi
    done
    [ -n "$lines" ] || return 0
    sorted=$(printf '%s' "$lines" | sed '/^$/d' | sort -t'|' -k1,1Vr)
    while IFS='|' read -r ver f; do
        [ -n "$ver" ] || continue
        LISTED_PATHS+=("$f")
    done <<< "$sorted"
}

show_installed_versions() {
    if [ ! -x "$PYENV_ROOT/bin/pyenv" ]; then
        echo "pyenv 尚未安装 (通过 [1] 完成首次部署后自动安装)。"
        return 0
    fi
    "$PYENV_ROOT/bin/pyenv" versions
}

uninstall_version() {
    if [ ! -x "$PYENV_ROOT/bin/pyenv" ]; then
        echo "pyenv 尚未安装, 无可卸载版本。"
        return 0
    fi
    "$PYENV_ROOT/bin/pyenv" versions
    local ver
    read -r -p "请输入要卸载的版本号 (如 3.12.16, 直接回车取消): " ver || return 0
    [ -n "$ver" ] || return 0
    if "$PYENV_ROOT/bin/pyenv" uninstall "$ver"; then
        echo "已卸载: $ver"
    else
        echo "卸载失败或版本不存在: $ver"
    fi
}

# 部署入口 (交互): 统一输入语义 编号=强制本地包 | o [版本]=强制在线 | 版本号=智能部署 | 回车=默认
deploy_interactive() {
    list_local_cache_menu
    echo ""
    echo "=================================================="
    echo "部署 Python (本地缓存优先, 支持在线)"
    echo "=================================================="
    if [ ${#LISTED_PATHS[@]} -gt 0 ]; then
        echo "发现 ${#LISTED_PATHS[@]} 个可用的本地缓存包:"
        local i=0 f base size_mb bdate
        for f in "${LISTED_PATHS[@]}"; do
            i=$((i + 1))
            base=$(basename "$f")
            size_mb=$(awk -v b="$(wc -c < "$f")" 'BEGIN{printf "%.1f", b/1048576}')
            bdate=$(printf '%s' "$base" | grep -oE '\+[0-9]{8}' | head -n1 || true); bdate=${bdate#+}
            bdate="${bdate:0:4}-${bdate:4:2}-${bdate:6:2}"
            printf "  [%d] %s  (%s, 约 %s MB)\n" "$i" "$base" "$bdate" "$size_mb"
        done
    else
        echo "本地缓存包: 无 (将按输入在线检索)"
    fi
    echo ""
    echo "输入说明:"
    echo "  - 编号 (如 1)           -> 使用对应本地缓存包部署 (强制本地)"
    echo "  - 完整版本 (如 3.12.16) -> 优先使用本地缓存, 本地没有则在线查找"
    echo "  - 大版本 (如 3.12)      -> 在线获取该系列最新构建 (命中缓存免下载), 失败降级本地"
    echo "  - o [版本] (如 o 3.13)  -> 强制在线 (忽略本地缓存)"
    echo "  - 直接回车              -> 等价输入 $DEFAULT_VERSION"
    echo ""
    local pick
    read -r -p "请输入编号 / 版本号 / o [版本] (直接回车 = $DEFAULT_VERSION): " pick || return 0
    if [ -z "$pick" ]; then
        pick="$DEFAULT_VERSION"
    fi

    # 编号 -> 强制使用对应本地缓存包
    if [[ "$pick" =~ ^[0-9]+$ ]]; then
        if [ "$pick" -lt 1 ] || [ "$pick" -gt ${#LISTED_PATHS[@]} ]; then
            echo "编号超出范围: [$pick]"
            return 0
        fi
        local f base
        f="${LISTED_PATHS[$((pick - 1))]}"
        base=$(basename "$f")
        if [[ "$base" =~ ^cpython-([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]{8})- ]]; then
            FORCED_LOCAL_QUEUE="local|${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|${base}|${f}"
            deploy_flow "${BASH_REMATCH[1]}"
            FORCED_LOCAL_QUEUE=""
        fi
        return 0
    fi

    # o [版本] -> 强制在线
    if [[ "$pick" =~ ^[oO][[:space:]]*([0-9]+\.[0-9]+(\.[0-9]+)?)?[[:space:]]*$ ]]; then
        local oVer="${BASH_REMATCH[1]:-$DEFAULT_VERSION}"
        deploy_flow "$oVer" 1
        return 0
    fi

    # 版本号 -> 智能部署 (精确=本地优先, 大版本=在线优先)
    if [[ "$pick" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        deploy_flow "$pick"
        return 0
    fi

    echo "无效输入: [$pick] (应为编号 / 版本号 / o [版本])"
}

interactive_menu() {
    while true; do
        echo ""
        echo "  ======================================================"
        echo "    PyVersions_pyenv  v1.8.3"
        echo "    Python 独立版 (install_only) 管理工具 · pyenv 托管"
        echo "  ======================================================"
        echo "  pyenv 根目录: $PYENV_ROOT"
        echo "  本地缓存目录: $CACHE_DIR"
        echo ""
        echo "  [1] 部署 Python                  (本地缓存 + 在线下载, 自动选择)"
        echo "  [2] 卸载指定版本                 (pyenv uninstall)"
        echo "  [3] 查看已安装的 Python 版本     (pyenv versions)"
        echo "  [0] 退出"
        echo ""
        local choice
        read -r -p "请输入选项编号: " choice || exit 0
        case "$choice" in
            0) echo "再见!" ; exit 0 ;;
            "") continue ;;
            1) deploy_interactive ;;
            2) uninstall_version ;;
            3) show_installed_versions ;;
            *) echo "无效选项: [$choice], 请输入 0-3。" ;;
        esac
    done
}

# ---------- 8. 入口分发 ----------
if [ -n "$INPUT_VERSION" ]; then
    # 启动参数模式: 直接部署指定版本 (退出码 0 成功 / 1 失败)
    if deploy_flow "$INPUT_VERSION"; then
        exit 0
    else
        exit 1
    fi
fi

if [ -t 0 ]; then
    # 无参数 + 交互终端: 进入交互主菜单
    interactive_menu
    exit 0
fi

# 无参数 + 非交互环境 (cron/CI 管道): 保持旧行为, 直接部署默认版本
if deploy_flow "$DEFAULT_VERSION"; then
    exit 0
else
    exit 1
fi