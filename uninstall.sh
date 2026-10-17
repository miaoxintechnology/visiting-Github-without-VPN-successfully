#!/usr/bin/env bash
# ============================================================
# GitHub 一键回滚 (Linux / macOS)
#
# 彻底撤销 fix-github.sh 的所有改动，恢复到原始状态：
#   1. 停止本地代理进程
#   2. 从系统 CA 证书库移除本地自签证书
#   3. 从 /etc/hosts 删除所有 GitHub 相关条目（保留其他配置）
#   4. 删除脚本生成的配置文件（证书/配置/日志）
#   5. 删除 .desktop 桌面启动器（桌面 + 应用菜单）
#   6. 刷新 DNS 缓存
#
# 用法：
#   chmod +x uninstall.sh
#   sudo ./uninstall.sh
# ============================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[*]${NC} $*"; }
good() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[-]${NC} $*"; }
fail() { echo -e "${RED}[x]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS="${HOSTS_FILE:-/etc/hosts}"
START_TS=$(date +%s)
ALL_CLEAN=1

# ---------- 0. 权限 ----------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "需要 root 权限（修改 $HOSTS 和系统 CA）"; info "请用：sudo $0"; exit 1
fi
good "root 权限确认"

# ---------- 1. 停止代理 ----------
info "第 1/6 步：停止本地代理..."
STOPPED=0
if command -v lsof >/dev/null 2>&1; then
    for pid in $(lsof -ti tcp:443 2>/dev/null || true); do
        cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")
        if [[ "$cmd" == "node" ]]; then
            kill -9 "$pid" 2>/dev/null && { good "  已停止代理进程 (PID $pid)"; STOPPED=$((STOPPED+1)); }
        fi
    done
fi
# 兜底：命令行带 proxy.js 的 node
for pid in $(pgrep -f 'proxy\.js' 2>/dev/null || true); do
    kill -9 "$pid" 2>/dev/null && { good "  已停止 node proxy.js (PID $pid)"; STOPPED=$((STOPPED+1)); }
done
[[ $STOPPED -eq 0 ]] && warn "  没有发现运行中的代理进程" || good "  共停止 $STOPPED 个进程"
sleep 1

# ---------- 2. 移除系统 CA 证书 ----------
info "第 2/6 步：移除系统 CA 证书..."
CA_REMOVED=0
CA_FILES=(
    "/usr/local/share/ca-certificates/local-github-proxy.crt"
    "/etc/pki/ca-trust/source/anchors/local-github-proxy.crt"
    "/etc/ssl/certs/local-github-proxy.pem"
    "$HOME/.pki/nssdb/local-github-proxy.crt"
)
for f in "${CA_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        rm -f "$f" && { good "  已删除: $f"; CA_REMOVED=$((CA_REMOVED+1)); }
    fi
done
if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates --fresh >/dev/null 2>&1 && good "  系统 CA 库已重建 (Debian/Ubuntu)"
elif command -v update-ca-trust >/dev/null 2>&1; then
    update-ca-trust extract >/dev/null 2>&1 && good "  系统 CA 库已重建 (RHEL/CentOS)"
fi
# NSS 数据库（Chrome 用）
if command -v certutil >/dev/null 2>&1 && [[ -d "$HOME/.pki/nssdb" ]]; then
    certutil -d "$HOME/.pki/nssdb" -D -n "Local GitHub Proxy" 2>/dev/null && \
        good "  已从 NSS 数据库移除证书" || true
fi
[[ $CA_REMOVED -eq 0 ]] && warn "  没有找到已安装的本地证书" || good "  共移除 $CA_REMOVED 个证书文件"

# ---------- 3. 清理 hosts ----------
info "第 3/6 步：清理 $HOSTS ..."
BACKUP="${HOSTS}.bak-uninstall-$(date +%Y%m%d-%H%M%S)"
cp "$HOSTS" "$BACKUP"; good "  已备份到 $(basename "$BACKUP")"

# 3.1 先删除脚本标记段（兼容各版本）
sed -i '/# === GitHub hosts/,/# === end GitHub/d' "$HOSTS" 2>/dev/null
sed -i '/# === GitHub hosts (auto-fixed/,/# === end GitHub hosts/d' "$HOSTS" 2>/dev/null

# 3.2 再删除残留的 GitHub 域名映射行
GITHUB_DOMAINS='github\.com|www\.github\.com|api\.github\.com|codeload\.github\.com|gist\.github\.com|collector\.github\.com|raw\.githubusercontent\.com|assets-cdn\.github\.com|avatars[0-9]?\.githubusercontent\.com|objects\.githubusercontent\.com|github\.githubassets\.com|github\.global\.ssl\.fastly\.net'
BEFORE=$(wc -l < "$HOSTS")
sed -i -E "/^[[:space:]]*[0-9a-fA-F:.]+[[:space:]]+(${GITHUB_DOMAINS})[[:space:]]*$/d" "$HOSTS" 2>/dev/null
# 注释掉的也删
sed -i -E "/^[[:space:]]*#[[:space:]]*[0-9a-fA-F:.]+[[:space:]]+(${GITHUB_DOMAINS})[[:space:]]*$/d" "$HOSTS" 2>/dev/null
AFTER=$(wc -l < "$HOSTS")
REMOVED=$((BEFORE - AFTER))
[[ $REMOVED -gt 0 ]] && good "  已移除 $REMOVED 行 GitHub 相关配置" || warn "  hosts 中没有 GitHub 相关配置"

# 删除尾部多余空行
sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$HOSTS" 2>/dev/null

echo "  ---- hosts 最终内容 ----"
sed 's/^/  /' "$HOSTS"

# ---------- 4. 删除配置文件 ----------
info "第 4/6 步：删除脚本生成的配置文件..."
DELETED=0
for f in proxy-config.json proxy-cert.pfx proxy-cert.cer cert.pem key.pem proxy.log; do
    if [[ -f "$SCRIPT_DIR/$f" ]]; then
        rm -f "$SCRIPT_DIR/$f" && { good "  已删除: $f"; DELETED=$((DELETED+1)); }
    fi
done
[[ $DELETED -eq 0 ]] && warn "  没有需要删除的配置文件" || good "  共删除 $DELETED 个文件"

# ---------- 5. 删除 .desktop 启动器 ----------
info "第 5/6 步：删除桌面启动器..."
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
[[ -z "$DESKTOP_DIR" || ! -d "$DESKTOP_DIR" ]] && DESKTOP_DIR="$HOME/Desktop"
APPS_DIR="$HOME/.local/share/applications"
DT_REMOVED=0
for f in \
    "$DESKTOP_DIR/GitHub-自动修复.desktop" \
    "$HOME/Desktop/GitHub-自动修复.desktop" \
    "$APPS_DIR/GitHub-自动修复.desktop" \
    "$HOME/.local/share/applications/GitHub-自动修复.desktop"
do
    if [[ -f "$f" ]]; then
        rm -f "$f" && { good "  已删除: $f"; DT_REMOVED=$((DT_REMOVED+1)); }
    fi
done
command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$APPS_DIR" 2>/dev/null
[[ $DT_REMOVED -eq 0 ]] && warn "  没有找到已安装的桌面启动器" || good "  共删除 $DT_REMOVED 个启动器"

# ---------- 6. 刷新 DNS ----------
info "第 6/6 步：刷新 DNS 缓存..."
if command -v resolvectl >/dev/null 2>&1; then resolvectl flush-caches 2>/dev/null && good "  已刷新 (resolvectl)"
elif command -v systemd-resolve >/dev/null 2>&1; then systemd-resolve --flush-caches 2>/dev/null && good "  已刷新 (systemd-resolve)"
elif command -v nscd >/dev/null 2>&1; then systemctl restart nscd 2>/dev/null && good "  已刷新 (nscd)"
elif command -v dscacheutil >/dev/null 2>&1; then dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null; good "  已刷新 (macOS)"
else warn "  未找到 DNS 刷新工具（hosts 会立即生效）"; fi

# ---------- 验证 ----------
echo ""
info "验证回滚结果..."

# 7.1 代理端口
if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | grep -q ':443'; then
        warn "  仍有进程监听 443（可能不是代理，属正常）"
    else
        good "  443 端口已释放"
    fi
fi

# 7.2 证书
STILL_CA=0
for f in "${CA_FILES[@]}"; do [[ -f "$f" ]] && STILL_CA=$((STILL_CA+1)); done
[[ $STILL_CA -gt 0 ]] && { warn "  仍有 $STILL_CA 个证书文件未删除"; ALL_CLEAN=0; } || good "  CA 证书已清理"

# 7.3 hosts
STILL=$(grep -ciE '(^|[[:space:]])(www\.|api\.|codeload\.|gist\.|collector\.)?github\.com([[:space:]]|$)|githubusercontent\.com|githubassets\.com' "$HOSTS" 2>/dev/null || echo 0)
if [[ "$STILL" -gt 0 ]]; then
    warn "  hosts 仍有 $STILL 行含 github 的内容："
    grep -inE 'github' "$HOSTS" | sed 's/^/    /' || true
    ALL_CLEAN=0
else
    good "  hosts 已无 GitHub 相关配置"
fi

END_TS=$(date +%s)
echo ""
echo -e "${GREEN}======================================================${NC}"
if [[ $ALL_CLEAN -eq 1 ]]; then
    echo -e "${GREEN} 回滚完成！耗时 $((END_TS - START_TS)) 秒${NC}"
    echo -e "${GREEN} 所有改动已撤销，系统已恢复原始状态${NC}"
else
    echo -e "${YELLOW} 回滚基本完成（耗时 $((END_TS - START_TS)) 秒），但有几项未完全清理${NC}"
    echo -e "${YELLOW} 请查看上方黄色提示${NC}"
fi
echo -e "${GREEN}======================================================${NC}"
echo ""
echo -e "${YELLOW} 注意：回滚后 GitHub 将恢复为「无法访问」的原始状态${NC}"
echo -e "${YELLOW}（因为所有绕过措施都已移除，这是预期行为）${NC}"
echo ""
echo " hosts 备份保留在: $(basename "$BACKUP")"
echo " 如需再次修复，重新运行 fix-github.sh 即可"
echo ""
