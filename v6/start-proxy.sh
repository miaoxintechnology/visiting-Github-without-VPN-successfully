#!/usr/bin/env bash
# ============================================================
# GitHub 加速器 v6 · 只启动代理（Linux / macOS）
#
# 代理没起来时快速拉起：不重新扫描 IP、不改 hosts。
#
# 用法：
#   ./start-proxy.sh              # 普通用户即可（systemd 服务已注册时）
#   sudo ./start-proxy.sh         # 未注册服务时需要 root
# ============================================================
set -uo pipefail

V6_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export V6_DIR
# shellcheck source=/dev/null
. "$V6_DIR/common.sh"

NO_PAUSE=0
[ "${1:-}" = '--no-pause' ] && NO_PAUSE=1

echo
echo -e "${CYAN}===== GitHub 本地代理 =====${NC}"

# 1. 前置检查
if [ ! -f "$PROXY_JS" ]; then
    fail "缺少 proxy.js（应与本脚本同目录）"; exit 1
fi
if [ ! -f "$CONFIG_PATH" ]; then
    fail '缺少 proxy-config.json'
    warn '请先运行：sudo ./fix-github.sh（会自动生成配置）'
    exit 1
fi
if ! find_node; then
    fail '找不到 Node.js'
    warn '请先运行：sudo ./fix-github.sh（它会自动安装 Node.js）'
    exit 1
fi
good "Node.js：$NODE_BIN"

# 2. 是否已在运行
if proxy_health "$LISTEN_PORT"; then
    good "代理已在运行（127.0.0.1:$LISTEN_PORT）"
    [ "$NO_PAUSE" -eq 0 ] && [ -t 0 ] && sleep 2
    exit 0
fi

# 3. 启动
info '启动代理...'
if [ "$V6_INIT" = 'systemd' ] && service_registered; then
    if ! is_root; then
        fail '需要 root 才能启动系统服务'
        warn '请用：sudo ./start-proxy.sh'
        exit 1
    fi
    systemctl start "$SERVICE_NAME" >/dev/null 2>&1
else
    occupied_pids="$(find_proxy_pids)"
    if [ -z "$occupied_pids" ] && port_listening "$LISTEN_PORT"; then
        fail "端口 $LISTEN_PORT 被其他进程占用"
        warn '请先停止占用该端口的程序'
        exit 1
    fi
    ( cd "$V6_DIR" && nohup "$NODE_BIN" proxy.js >> "$V6_DIR/proxy.daemon.log" 2>&1 & )
fi

# 4. 等待健康
ok=0
for _ in $(seq 1 40); do
    if proxy_health "$LISTEN_PORT"; then ok=1; break; fi
    sleep 0.5
done

if [ "$ok" -eq 1 ]; then
    good "代理已启动！(127.0.0.1:$LISTEN_PORT)"
    echo
    dim ' GitHub 现在可以访问了'
    dim ' 如果浏览器还打不开，按 Ctrl+Shift+R 强刷'
else
    fail '代理启动失败'
    for lf in "$PROXY_LOG" "$V6_DIR/proxy.daemon.log"; do
        if [ -f "$lf" ]; then
            dim " --- $(basename "$lf") 最后几行 ---"
            tail -5 "$lf" | sed 's/^/  /'
        fi
    done
    warn '可运行 sudo ./fix-github.sh 重新完整修复'
fi

[ "$NO_PAUSE" -eq 0 ] && [ -t 0 ] && read -r -p '按回车关闭...' _
exit $((1-ok))
