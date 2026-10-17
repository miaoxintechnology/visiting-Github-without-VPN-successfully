#!/usr/bin/env bash
# ============================================================
# 安装 GitHub 一键修复 到 Linux 桌面
#
# 作用：生成 .desktop 桌面启动器（Exec 使用绝对路径，最可靠），
#      并安装到「桌面」和「应用菜单」。
#
# 用法：
#   chmod +x install-desktop.sh
#   ./install-desktop.sh
#
# 卸载：
#   ./install-desktop.sh --uninstall
# ============================================================
set -uo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${CYAN}[*]${NC} $*"; }
good() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[-]${NC} $*"; }
fail() { echo -e "${RED}[x]${NC} $*"; }

# 脚本所在目录（绝对路径）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SCRIPT="$SCRIPT_DIR/fix-github.sh"
DESKTOP_NAME="GitHub-自动修复.desktop"

# ---------- 卸载模式 ----------
if [[ "${1:-}" == "--uninstall" ]]; then
    info "卸载 .desktop 启动器..."
    for f in \
        "$HOME/.local/share/applications/$DESKTOP_NAME" \
        "$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")/$DESKTOP_NAME" \
        "$HOME/Desktop/$DESKTOP_NAME"
    do
        [[ -f "$f" ]] && rm -f "$f" && good "已删除: $f"
    done
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
    good "卸载完成"
    exit 0
fi

# ---------- 检查 ----------
[[ -f "$FIX_SCRIPT" ]] || { fail "找不到 $FIX_SCRIPT"; warn "请把本脚本和 fix-github.sh 放在同一目录"; exit 1; }
chmod +x "$FIX_SCRIPT" 2>/dev/null

# 桌面目录（兼容中英文环境）
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
[[ -z "$DESKTOP_DIR" || ! -d "$DESKTOP_DIR" ]] && DESKTOP_DIR="$HOME/Desktop"
[[ -d "$DESKTOP_DIR" ]] || { warn "桌面目录不存在，将只安装到应用菜单"; DESKTOP_DIR=""; }

APPS_DIR="$HOME/.local/share/applications"
mkdir -p "$APPS_DIR"

# ---------- 生成 .desktop ----------
# 注意：Exec 里用绝对路径（$SCRIPT_DIR），避免 %k 在含中文/空格路径下的编码问题
cat > "$SCRIPT_DIR/$DESKTOP_NAME" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=GitHub 自动修复
GenericName=GitHub Access Fixer
Comment=自动识别 DNS 污染 / IP 封锁 / SNI 阻断并修复 GitHub 访问
Comment[en]=Auto-detect DNS pollution / IP blocking / SNI blocking and fix GitHub access
Exec=bash -c 'cd "$SCRIPT_DIR" && sudo ./fix-github.sh; echo; read -p "按回车关闭窗口..."'
Path=$SCRIPT_DIR
Icon=utilities-terminal
Terminal=true
Categories=Network;Utility;
Keywords=github;network;dns;hosts;gfw;proxy;
StartupNotify=false
EOF
chmod +x "$SCRIPT_DIR/$DESKTOP_NAME"
good "已生成启动器: $SCRIPT_DIR/$DESKTOP_NAME"

# ---------- 安装到应用菜单 ----------
cp -f "$SCRIPT_DIR/$DESKTOP_NAME" "$APPS_DIR/"
chmod +x "$APPS_DIR/$DESKTOP_NAME"
good "已安装到应用菜单: $APPS_DIR"

# ---------- 安装到桌面 ----------
if [[ -n "$DESKTOP_DIR" ]]; then
    cp -f "$SCRIPT_DIR/$DESKTOP_NAME" "$DESKTOP_DIR/"
    chmod +x "$DESKTOP_DIR/$DESKTOP_NAME"

    # GNOME 需要标记为「可信」才能双击运行
    if command -v gio >/dev/null 2>&1; then
        gio set "$DESKTOP_DIR/$DESKTOP_NAME" metadata::trusted true 2>/dev/null && \
            good "已标记为可信（GNOME）" || true
    fi
    good "已安装到桌面: $DESKTOP_DIR/$DESKTOP_NAME"
fi

# ---------- 刷新应用数据库 ----------
command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$APPS_DIR" 2>/dev/null && good "应用数据库已刷新"

# ---------- 完成提示 ----------
echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN} 安装完成！${NC}"
echo -e "${GREEN}======================================================${NC}"
echo " 启动方式："
echo "   1. 双击桌面的「GitHub 自动修复」图标"
echo "      （GNOME 桌面可能需要右键 →「允许启动」）"
echo "   2. 或在应用菜单搜索「GitHub 自动修复」"
echo "   3. 或命令行：sudo $FIX_SCRIPT"
echo ""
echo " 注意："
echo "   - 每次点击都会重新扫描并修复（约 1~3 分钟）"
echo "   - 中途会弹出密码框（需要管理员权限改 hosts）"
echo "   - 如果移动了本文件夹，请重新运行本安装脚本"
echo ""
echo -e "${YELLOW} 卸载：$0 --uninstall${NC}"
echo -e "${GREEN}======================================================${NC}"
