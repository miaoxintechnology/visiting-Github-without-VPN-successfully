#!/usr/bin/env bash
# ============================================================
# GitHub 加速器 v6 · 安装 Linux 桌面启动器
#
# 生成 .desktop 并安装到「桌面」和「应用菜单」。
# Exec 使用绝对路径（支持含中文/空格的路径），最可靠。
#
# 用法：
#   ./install-desktop.sh              # 安装
#   ./install-desktop.sh --uninstall  # 卸载
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME='GitHub加速器v6'

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
info() { echo -e "${CYAN}[*]${NC} $*"; }
good() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[-]${NC} $*"; }
fail() { echo -e "${RED}[x]${NC} $*"; }

DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
[ -z "$DESKTOP_DIR" ] || [ ! -d "$DESKTOP_DIR" ] && DESKTOP_DIR="$HOME/Desktop"
APPS_DIR="$HOME/.local/share/applications"
mkdir -p "$APPS_DIR"

# ---------- 卸载 ----------
if [ "${1:-}" = '--uninstall' ]; then
    info '卸载桌面启动器...'
    for f in "$APPS_DIR/$APP_NAME.desktop" "$DESKTOP_DIR/$APP_NAME.desktop" "$HOME/Desktop/$APP_NAME.desktop"; do
        [ -f "$f" ] && rm -f "$f" && good "  已删除：$f"
    done
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null
    good '卸载完成'
    exit 0
fi

# ---------- 检查 ----------
[ -f "$SCRIPT_DIR/fix-github.sh" ] || { fail "找不到 $SCRIPT_DIR/fix-github.sh"; exit 1; }
chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true

make_desktop() {
    local name="$1" exec_cmd="$2" comment="$3" out="$4"
    cat > "$out" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
GenericName=GitHub Accelerator v6
Comment=$comment
Exec=$exec_cmd
Path=$SCRIPT_DIR
Icon=utilities-terminal
Terminal=true
Categories=Network;Utility;
Keywords=github;network;dns;hosts;gfw;proxy;
StartupNotify=false
EOF
    chmod +x "$out"
}

# ---------- 生成 ----------
info '生成 .desktop 启动器...'
make_desktop 'GitHub加速器v6 · 快速修复' \
    "bash -c 'cd \"$SCRIPT_DIR\" && sudo ./fix-github.sh; echo; read -p \"按回车关闭窗口...\"'" \
    '扫描 IP、装证书、起代理、写 hosts（需要 root）' \
    "$SCRIPT_DIR/$APP_NAME.desktop"
good "  已生成：$SCRIPT_DIR/$APP_NAME.desktop"

make_desktop 'GitHub加速器v6 · 只启动代理' \
    "bash -c 'cd \"$SCRIPT_DIR\" && ./start-proxy.sh; echo; read -p \"按回车关闭窗口...\"'" \
    '代理没起来时快速拉起（不重扫、不改 hosts）' \
    "$SCRIPT_DIR/$APP_NAME-只启动代理.desktop"
good "  已生成：$SCRIPT_DIR/$APP_NAME-只启动代理.desktop"

make_desktop 'GitHub加速器v6 · 体检' \
    "bash -c 'cd \"$SCRIPT_DIR\" && ./doctor.sh; echo; read -p \"按回车关闭窗口...\"'" \
    '只读体检：报告链路是否完整' \
    "$SCRIPT_DIR/$APP_NAME-体检.desktop"
good "  已生成：$SCRIPT_DIR/$APP_NAME-体检.desktop"

make_desktop 'GitHub加速器v6 · 一键回滚' \
    "bash -c 'cd \"$SCRIPT_DIR\" && sudo ./uninstall.sh; echo; read -p \"按回车关闭窗口...\"'" \
    '删除证书、服务与 hosts 配置（需要 root）' \
    "$SCRIPT_DIR/$APP_NAME-一键回滚.desktop"
good "  已生成：$SCRIPT_DIR/$APP_NAME-一键回滚.desktop"

# ---------- 安装到应用菜单 ----------
for f in "$SCRIPT_DIR"/"$APP_NAME"*.desktop; do
    [ -f "$f" ] || continue
    cp -f "$f" "$APPS_DIR/"
    chmod +x "$APPS_DIR/$(basename "$f")"
done
good "已安装到应用菜单：$APPS_DIR"

# ---------- 安装到桌面 ----------
if [ -d "$DESKTOP_DIR" ]; then
    for f in "$SCRIPT_DIR"/"$APP_NAME"*.desktop; do
        [ -f "$f" ] || continue
        cp -f "$f" "$DESKTOP_DIR/"
        chmod +x "$DESKTOP_DIR/$(basename "$f")"
        command -v gio >/dev/null 2>&1 && gio set "$DESKTOP_DIR/$(basename "$f")" metadata::trusted true 2>/dev/null || true
    done
    good "已安装到桌面：$DESKTOP_DIR"
fi

# ---------- 刷新 ----------
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null && good '应用数据库已刷新'

echo
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN} 安装完成！${NC}"
echo -e "${GREEN}======================================================${NC}"
echo ' 桌面上现在有 4 个图标：'
echo '   快速修复 / 只启动代理 / 体检 / 一键回滚'
echo ''
echo ' GNOME 桌面首次需要右键 →「允许启动」'
echo ''
echo -e "${YELLOW} 卸载启动器：./install-desktop.sh --uninstall${NC}"
echo -e "${GREEN}======================================================${NC}"
