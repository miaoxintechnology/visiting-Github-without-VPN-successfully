#!/usr/bin/env bash
# ============================================================
# GitHub 加速器 v6 · 一键回滚（Linux / macOS）
#
# 彻底撤销安装，恢复原状：
#   1. 停止代理（含 systemd 服务 / launchd）
#   2. 注销开机自启
#   3. 从系统信任库删除本工具证书
#   4. 从 hosts 删除 v6/v5 配置段与残留映射
#   5. 删除证书/配置/日志/便携版 Node
#   6. 刷新 DNS 并逐项验证
#
# 用法：
#   sudo ./uninstall.sh             # 正式回滚
#   sudo ./uninstall.sh --dry-run   # 只预览
#   sudo ./uninstall.sh --clean-legacy  # 同时清理 v5 目录里的遗留文件
# ============================================================
set -uo pipefail

V6_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export V6_DIR
# shellcheck source=/dev/null
. "$V6_DIR/common.sh"

DRY_RUN=0
CLEAN_LEGACY=0
NO_PAUSE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=1; shift ;;
        --clean-legacy) CLEAN_LEGACY=1; shift ;;
        --no-pause)     NO_PAUSE=1; shift ;;
        -h|--help)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) shift ;;
    esac
done

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        dim "    [dry-run] $*"
    else
        "$@" >/dev/null 2>&1
    fi
}

echo
echo -e "${CYAN}==============================================================${NC}"
echo -e "${CYAN}  GitHub 加速器 v6 · 回滚${NC}"
echo -e "${CYAN}==============================================================${NC}"
if [ "$DRY_RUN" -eq 1 ]; then
    warn 'DryRun 模式：只打印计划，不做任何修改'
fi
echo

if [ "$DRY_RUN" -eq 0 ]; then
    require_root
fi

all_clean=1

# ---------- 1. 停止代理 ----------
info '第 1/6 步：停止代理...'
pids="$(find_proxy_pids)"
if [ -n "$pids" ]; then
    for pid in $pids; do
        run kill -9 "$pid" && good "  已停止代理进程 (PID $pid)"
    done
else
    warn '  没有发现运行中的代理进程'
fi
if [ "$DRY_RUN" -eq 0 ] && [ "$V6_INIT" = 'systemd' ] && command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
fi

# ---------- 2. 注销开机自启 ----------
info '第 2/6 步：注销开机自启...'
if service_registered; then
    if [ "$DRY_RUN" -eq 1 ]; then
        dim "    [dry-run] unregister_service"
    else
        unregister_service && good '  已删除开机自启'
    fi
else
    warn '  没有注册开机自启'
fi

# ---------- 3. 删除系统 CA ----------
info '第 3/6 步：删除系统 CA 证书...'
if [ "$DRY_RUN" -eq 1 ]; then
    dim "    [dry-run] remove_ca（$CA_DEBIAN / $CA_RHEL）"
elif remove_ca; then
    good '  已从系统信任库移除证书'
else
    warn '  没有找到已安装的证书'
fi

# ---------- 4. 清理 hosts ----------
info '第 4/6 步：清理 hosts...'
if [ -f "$HOSTS_FILE" ]; then
    before="$(wc -l < "$HOSTS_FILE")"
    if [ "$DRY_RUN" -eq 1 ]; then
        dim "    [dry-run] 删除 $HOSTS_FILE 中的 v6/v5 配置段"
    else
        cp -f "$HOSTS_FILE" "${HOSTS_FILE}.bak-uninstall-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        hosts_strip_block
        # 删除残留的 GitHub 映射行（保留其他行）
        github_domains='github\.com|www\.github\.com|api\.github\.com|codeload\.github\.com|gist\.github\.com|collector\.github\.com|raw\.githubusercontent\.com|assets-cdn\.github\.com|avatars[0-9]?\.githubusercontent\.com|objects\.githubusercontent\.com'
        tmp="$(mktemp)"
        grep -vE "^[[:space:]]*[0-9a-fA-F:.]+[[:space:]]+(${github_domains})[[:space:]]*$" "$HOSTS_FILE" > "$tmp" || true
        cat "$tmp" > "$HOSTS_FILE"; rm -f "$tmp"
        after="$(wc -l < "$HOSTS_FILE")"
        removed=$((before - after))
        if [ "$removed" -gt 0 ]; then good "  已移除 $removed 行"; else warn '  hosts 中没有 GitHub 相关配置'; fi
        flush_dns
    fi
else
    warn "  找不到 $HOSTS_FILE"
fi

# ---------- 5. 删除运行期文件 ----------
info '第 5/6 步：删除证书/配置/日志...'
deleted=0
for f in proxy-config.json proxy-cert.pfx proxy-cert.cer cert.pem key.pem \
         proxy-pass.dat install-state.json proxy-state.json proxy.log \
         proxy.daemon.log proxy.out.log proxy.err.log; do
    if [ -f "$V6_DIR/$f" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            dim "    [dry-run] rm $f"
        else
            rm -f "$V6_DIR/$f" && { good "  已删除：$f"; deleted=$((deleted+1)); }
        fi
    fi
done
# 便携版 Node / curl
for d in .tools; do
    if [ -d "$V6_DIR/$d" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            dim "    [dry-run] rm -rf $d/"
        else
            rm -rf "$V6_DIR/$d" && { good "  已删除：$d/"; deleted=$((deleted+1)); }
        fi
    fi
done
[ "$deleted" -eq 0 ] && warn '  没有需要删除的文件'

# v5 遗留
if [ "$CLEAN_LEGACY" -eq 1 ]; then
    info '  清理 v5 遗留文件...'
    for d in "$V6_DIR/../v5" "$V6_DIR/../github-hosts-fix" "$HOME/github-hosts-fix"; do
        [ -d "$d" ] || continue
        for f in proxy-config.json proxy-cert.pfx proxy-cert.cer proxy-pass.dat cert.pem key.pem; do
            if [ -f "$d/$f" ]; then
                [ "$DRY_RUN" -eq 1 ] && dim "    [dry-run] rm $d/$f" || { rm -f "$d/$f" && good "  已删除 $d/$f"; }
            fi
        done
    done
fi

# ---------- 6. 验证 ----------
info '第 6/6 步：验证...'
if [ "$DRY_RUN" -eq 0 ]; then
    if port_listening "$LISTEN_PORT"; then
        warn "  仍有进程监听 $LISTEN_PORT（可能不是代理，属正常）"
    else
        good "  端口 $LISTEN_PORT 已释放"
    fi

    if [ -f "$CA_DEBIAN" ] || [ -f "$CA_RHEL" ]; then
        warn '  系统 CA 仍有残留'; all_clean=0
    else
        good '  系统 CA 已清理'
    fi

    if service_registered; then
        warn '  开机自启仍有残留'; all_clean=0
    else
        good '  开机自启已清理'
    fi

    if [ -f "$HOSTS_FILE" ] && grep -qiE '(^|[[:space:]])(www\.|api\.|codeload\.|gist\.|collector\.)?github\.com([[:space:]]|$)|githubusercontent\.com' "$HOSTS_FILE" 2>/dev/null; then
        warn '  hosts 仍有 GitHub 相关行：'
        grep -inE 'github' "$HOSTS_FILE" | sed 's/^/    /' || true
        all_clean=0
    else
        good '  hosts 已无 GitHub 相关配置'
    fi

    if [ -f "$CERT_PEM" ] || [ -f "$KEY_PEM" ]; then
        warn '  证书文件仍有残留'; all_clean=0
    else
        good '  证书文件已清理'
    fi
fi

echo
echo -e "${GREEN}==============================================================${NC}"
if [ "$DRY_RUN" -eq 1 ]; then
    good 'DryRun 完成（未修改任何系统设置）'
elif [ "$all_clean" -eq 1 ]; then
    good '回滚完成：所有改动已撤销，系统已恢复原始状态'
else
    warn '回滚基本完成，但有几项未完全清理，请查看上方黄色提示'
fi
echo -e "${GREEN}==============================================================${NC}"
echo
dim ' 注意：回滚后 GitHub 将恢复为「无法直连」的原始状态（预期行为）'
dim ' 想再次修复：sudo ./fix-github.sh'
echo

[ "$NO_PAUSE" -eq 0 ] && [ -t 0 ] && read -r -p '按回车关闭...' _
exit 0
