#!/usr/bin/env bash
# ============================================================
# GitHub 加速器 v6 · Linux/macOS 公共库
#
# 对应 Windows 版的 common.ps1，提供：
#   日志/步骤输出、平台与包管理器探测、Node.js 与 curl 解析、
#   TCP/HTTPS 探测、证书生成与系统 CA 安装、hosts 段读写、
#   systemd 服务（Linux）/ launchd（macOS）注册、代理启停与健康检查。
#
# 约定：
#   · 所有运行期文件都在本目录（$V6_DIR），不写系统目录（CA 除外）
#   · 私钥用 PEM，chmod 600，只有当前用户（root）可读
#   · 需要 root 才能改 /etc/hosts 与系统 CA
# ============================================================

# ---------- 颜色 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; GRAY=$'\033[0;90m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; GRAY=''; BOLD=''; NC=''
fi

info() { echo -e "${CYAN}[*]${NC} $*"; }
good() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[-]${NC} $*"; }
fail() { echo -e "${RED}[x]${NC} $*"; }
dim()  { echo -e "${GRAY}$*${NC}"; }
step() { echo -e "${BOLD}${CYAN}  [$1] $2${NC}"; }

# ---------- 路径与常量 ----------
# common.sh 由主脚本 source，主脚本已设置 V6_DIR；未设置时自行推断
if [ -z "${V6_DIR:-}" ]; then
    V6_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
export V6_DIR

V6_VERSION="6.1.0"
PROXY_JS="$V6_DIR/proxy.js"
CONFIG_PATH="$V6_DIR/proxy-config.json"
STATE_PATH="$V6_DIR/install-state.json"
PROXY_LOG="$V6_DIR/proxy.log"
PROXY_STATE="$V6_DIR/proxy-state.json"
CERT_PEM="$V6_DIR/cert.pem"
KEY_PEM="$V6_DIR/key.pem"
CER_FILE="$V6_DIR/proxy-cert.cer"

LISTEN_PORT="${LISTEN_PORT:-443}"
LISTEN_HOST="127.0.0.1"
SERVICE_NAME="github-accelerator-v6"
CA_DEBIAN="/usr/local/share/ca-certificates/github-accelerator-v6.crt"
CA_RHEL="/etc/pki/ca-trust/source/anchors/github-accelerator-v6.crt"

# 需要走代理的域名（github.com 的 SNI 被封，只能无 SNI 转发）
ACCEL_DOMAINS=(github.com www.github.com gist.github.com collector.github.com)
# 走直连的域名
RAW_DOMAINS=(raw.githubusercontent.com assets-cdn.github.com avatars.githubusercontent.com
             objects.githubusercontent.com avatars0.githubusercontent.com
             avatars1.githubusercontent.com avatars2.githubusercontent.com)

UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36'

# ---------- 平台探测 ----------
V6_OS='unknown'
V6_PKG=''
V6_INIT=''
detect_platform() {
    case "$(uname -s 2>/dev/null)" in
        Linux*)  V6_OS='linux' ;;
        Darwin*) V6_OS='macos' ;;
        *)       V6_OS='unknown' ;;
    esac
    if [ "$V6_OS" = 'linux' ]; then
        for p in apt-get dnf yum pacman zypper; do
            if command -v "$p" >/dev/null 2>&1; then V6_PKG="$p"; break; fi
        done
        if command -v systemctl >/dev/null 2>&1; then V6_INIT='systemd'; fi
    fi
}
detect_platform

is_root() { [ "$(id -u 2>/dev/null)" -eq 0 ]; }

require_root() {
    if ! is_root; then
        warn '需要 root 权限（修改 /etc/hosts 与系统 CA）'
        info "请用：sudo $0"
        exit 1
    fi
}

# ---------- Node.js ----------
NODE_BIN=''
find_node() {
    if command -v node >/dev/null 2>&1; then
        NODE_BIN="$(command -v node)"; return 0
    fi
    # 本脚本目录下的便携版
    local nb
    nb="$(find "$V6_DIR/.tools/node" -name node -type f -path '*/bin/*' 2>/dev/null | head -1)"
    if [ -n "$nb" ] && [ -x "$nb" ]; then
        export PATH="$(dirname "$nb"):$PATH"
        NODE_BIN="$nb"; return 0
    fi
    return 1
}

install_node() {
    info '未检测到 Node.js，正在自动安装...'
    # 1) 包管理器
    case "$V6_PKG" in
        apt-get) info '  [1/3] apt-get install nodejs'; (apt-get update -qq && apt-get install -y nodejs) >/dev/null 2>&1 ;;
        dnf)     info '  [1/3] dnf install nodejs'; dnf install -y nodejs >/dev/null 2>&1 ;;
        yum)     info '  [1/3] yum install nodejs'; yum install -y nodejs >/dev/null 2>&1 ;;
        pacman)  info '  [1/3] pacman -S nodejs'; pacman -Sy --noconfirm nodejs >/dev/null 2>&1 ;;
        zypper)  info '  [1/3] zypper install nodejs'; zypper -n install nodejs >/dev/null 2>&1 ;;
        *)       info '  [1/3] 无已知包管理器，跳过' ;;
    esac
    if find_node; then good "  包管理器安装成功：$NODE_BIN"; return 0; fi

    # 2) 下载官方二进制（国内镜像优先）
    local arch ver m tmpdir url
    case "$(uname -m)" in
        x86_64|amd64)  arch='x64' ;;
        aarch64|arm64) arch='arm64' ;;
        armv7l)        arch='armv7l' ;;
        *)             arch='x64' ;;
    esac
    local os_tag='linux'
    [ "$V6_OS" = 'macos' ] && os_tag='darwin'
    for ver in v22.11.0 v20.18.0; do
        for m in "https://cdn.npmmirror.com/binaries/node/$ver/node-$ver-$os_tag-$arch.tar.xz" \
                 "https://nodejs.org/dist/$ver/node-$ver-$os_tag-$arch.tar.xz"; do
            info "  [2/3] 下载：$m"
            tmpdir="$(mktemp -d)"
            if curl -fsSL --connect-timeout 15 --max-time 240 "$m" -o "$tmpdir/node.tar.xz" 2>/dev/null \
               && [ -s "$tmpdir/node.tar.xz" ] && [ "$(stat -c%s "$tmpdir/node.tar.xz" 2>/dev/null || echo 0)" -gt 5000000 ]; then
                info '  [3/3] 解压中...'
                mkdir -p "$V6_DIR/.tools/node"
                if tar -xJf "$tmpdir/node.tar.xz" -C "$V6_DIR/.tools/node" 2>/dev/null; then
                    rm -rf "$tmpdir"
                    if find_node; then good "  便携版已就绪：$NODE_BIN"; return 0; fi
                fi
            fi
            rm -rf "$tmpdir"
        done
    done
    return 1
}

ensure_node() {
    if find_node; then return 0; fi
    if install_node; then return 0; fi
    return 1
}

# ---------- curl ----------
CURL_BIN=''
CURL_HAS_PARALLEL=0
find_curl() {
    local best='' best_ver='0.0.0' has_par=0 p line ver
    # 优先路径：可能是更新版本的 curl
    local candidates=()
    command -v curl >/dev/null 2>&1 && candidates+=("$(command -v curl)")
    candidates+=(/usr/local/bin/curl /usr/bin/curl /opt/homebrew/bin/curl /opt/local/bin/curl)
    for p in "${candidates[@]}"; do
        [ -n "$p" ] || continue
        [ -x "$p" ] || continue
        line="$("$p" --version 2>/dev/null | head -1)"
        if echo "$line" | grep -qE 'curl [0-9]+\.[0-9]+'; then
            ver="$(echo "$line" | sed -nE 's/^curl ([0-9]+\.[0-9]+).*/\1/p')"
            [ -n "$ver" ] || continue
            if awk -v a="$ver" -v b="7.66" 'BEGIN{exit !(a>=b)}'; then
                if [ "$has_par" -eq 0 ] || awk -v a="$ver" -v b="$best_ver" 'BEGIN{exit !(a>b)}'; then
                    best="$p"; best_ver="$ver"; has_par=1
                fi
            elif [ "$has_par" -eq 0 ] && awk -v a="$ver" -v b="$best_ver" 'BEGIN{exit !(a>b)}'; then
                best="$p"; best_ver="$ver"
            fi
        fi
    done
    [ -n "$best" ] || best='curl'
    CURL_BIN="$best"
    CURL_HAS_PARALLEL="$has_par"
    return 0
}

# 便携版 curl（Linux 一般不需要，包管理器版本都够新；作为兜底保留接口）
ensure_curl() {
    find_curl
    if [ "$CURL_HAS_PARALLEL" -eq 0 ] && [ -z "${GH_ACCEL_NO_CURL_DOWNLOAD:-}" ]; then
        dim '    curl 版本较老，批量探测将改用串行（不影响功能，只是慢一点）'
    fi
    return 0
}

# ---------- 端口/进程 ----------
port_listening() {
    local port="${1:-$LISTEN_PORT}"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    elif command -v lsof >/dev/null 2>&1; then
        lsof -ti "tcp:${port}" >/dev/null 2>&1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    else
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && exec 3>&- && return 0 || return 1
    fi
}

# 找监听指定端口的 node 进程 PID（只杀本工具的，避免误杀）
find_proxy_pids() {
    local port="${1:-$LISTEN_PORT}" pid pids=''
    if command -v lsof >/dev/null 2>&1; then
        for pid in $(lsof -ti "tcp:${port}" 2>/dev/null || true); do
            case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
                node|nodejs) pids="$pids $pid" ;;
            esac
        done
    fi
    # 兜底：命令行里带 proxy.js 的
    for pid in $(pgrep -f "$V6_DIR/proxy.js" 2>/dev/null || true); do
        pids="$pids $pid"
    done
    echo "$pids" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' '
}

stop_proxy() {
    local pids pid stopped=0
    pids="$(find_proxy_pids)"
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null && stopped=$((stopped+1))
    done
    # systemd 服务也停掉（避免 Restart=on-failure 又拉起来）
    if [ "$V6_INIT" = 'systemd' ] && command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    [ "$stopped" -gt 0 ] && sleep 1
    return 0
}

# 代理健康检查（proxy.js 提供 /__health）
proxy_health() {
    local port="${1:-$LISTEN_PORT}" out
    out="$("${CURL_BIN:-curl}" -k -s -o - -w '\n%{http_code}' --connect-timeout 3 --max-time 5 \
        "https://127.0.0.1:${port}/__health" 2>/dev/null)" || return 1
    local code body
    code="$(echo "$out" | tail -1)"
    body="$(echo "$out" | sed '$d')"
    case "$code" in 200|204) ;; *) return 1 ;; esac
    echo "$body" | grep -q '"ok"[[:space:]]*:[[:space:]]*true' && return 0
    # 有些版本不返回 body，只要 200 也算健康
    [ "$code" = '200' ] && return 0
    return 1
}

# ---------- 证书 ----------
# 需要 openssl 生成 PEM 证书，并安装到系统 CA
has_openssl() { command -v openssl >/dev/null 2>&1; }

ensure_openssl() {
    has_openssl && return 0
    info '缺少 openssl，尝试安装...'
    case "$V6_PKG" in
        apt-get) (apt-get update -qq && apt-get install -y openssl) >/dev/null 2>&1 ;;
        dnf)     dnf install -y openssl >/dev/null 2>&1 ;;
        yum)     yum install -y openssl >/dev/null 2>&1 ;;
        pacman)  pacman -Sy --noconfirm openssl >/dev/null 2>&1 ;;
        zypper)  zypper -n install openssl >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
    has_openssl
}

cert_fingerprint() {
    [ -f "$CERT_PEM" ] || { echo ''; return; }
    openssl x509 -in "$CERT_PEM" -noout -fingerprint -sha256 2>/dev/null | \
        sed -n 's/^.*=//p' | tr -d ':' | tr 'A-Z' 'a-z'
}

cert_not_after() {
    [ -f "$CERT_PEM" ] || { echo 0; return; }
    local d
    d="$(openssl x509 -in "$CERT_PEM" -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')"
    if [ -n "$d" ]; then date -d "$d" +%s 2>/dev/null || echo 0; else echo 0; fi
}

cert_days_left() {
    local exp now
    exp="$(cert_not_after)"; now="$(date +%s)"
    [ "$exp" -gt 0 ] 2>/dev/null || { echo 0; return; }
    echo $(( (exp - now) / 86400 ))
}

# 安装证书到系统信任库
install_ca() {
    [ -f "$CERT_PEM" ] || { warn '  证书文件不存在，跳过 CA 安装'; return 1; }
    case "$V6_OS" in
        linux)
            if command -v update-ca-certificates >/dev/null 2>&1; then
                mkdir -p "$(dirname "$CA_DEBIAN")"
                cp -f "$CERT_PEM" "$CA_DEBIAN"
                update-ca-certificates >/dev/null 2>&1 && { good '  已导入系统 CA（Debian/Ubuntu 系）'; return 0; }
            elif command -v update-ca-trust >/dev/null 2>&1; then
                mkdir -p "$(dirname "$CA_RHEL")"
                cp -f "$CERT_PEM" "$CA_RHEL"
                update-ca-trust extract >/dev/null 2>&1 && { good '  已导入系统 CA（RHEL/CentOS 系）'; return 0; }
            fi
            warn '  未找到系统 CA 更新工具，浏览器可能需要手动信任证书'
            return 1
            ;;
        macos)
            if command -v security >/dev/null 2>&1; then
                security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$CERT_PEM" >/dev/null 2>&1 \
                    && { good '  已导入系统钥匙串'; return 0; }
            fi
            warn '  无法自动导入钥匙串，请手动双击 cert.pem 并设为「始终信任」'
            return 1
            ;;
    esac
    return 1
}

remove_ca() {
    local removed=0
    if [ -f "$CA_DEBIAN" ]; then rm -f "$CA_DEBIAN" && removed=1; fi
    if [ -f "$CA_RHEL" ]; then rm -f "$CA_RHEL" && removed=1; fi
    if [ "$removed" -eq 1 ]; then
        if command -v update-ca-certificates >/dev/null 2>&1; then
            update-ca-certificates --fresh >/dev/null 2>&1
        elif command -v update-ca-trust >/dev/null 2>&1; then
            update-ca-trust extract >/dev/null 2>&1
        fi
    fi
    if [ "$V6_OS" = 'macos' ] && command -v security >/dev/null 2>&1; then
        security delete-certificate -c 'GitHub Accelerator v6' /Library/Keychains/System.keychain >/dev/null 2>&1 || true
    fi
    [ "$removed" -eq 1 ]
}

# 生成新证书（RSA 3072 / SHA256 / 2 年 / CA:TRUE pathlength=0）
ensure_cert() {
    local force="${1:-0}" days_left chain
    if [ "$force" -eq 0 ] && [ -f "$CERT_PEM" ] && [ -f "$KEY_PEM" ]; then
        days_left="$(cert_days_left)"
        if [ "${days_left:-0}" -gt 30 ] 2>/dev/null; then
            chain="$(openssl x509 -in "$CERT_PEM" -noout -text 2>/dev/null | grep -c 'CA:TRUE' || true)"
            if [ "${chain:-0}" -ge 1 ]; then
                good "  复用已有证书（剩余 ${days_left} 天）"
                return 0
            fi
            warn '  已有证书缺少 CA:TRUE，重新生成'
        else
            warn '  已有证书已过期或即将过期，重新生成'
        fi
    fi

    ensure_openssl || { fail '  缺少 openssl，无法生成证书'; return 1; }

    info '  生成新证书（RSA 3072 / SHA256 / 2 年 / CA:TRUE）...'
    local san
    san="DNS:github.com,DNS:www.github.com,DNS:gist.github.com,DNS:collector.github.com,DNS:*.github.com"

    ( cd "$V6_DIR" && openssl req -x509 -newkey rsa:3072 -sha256 -days 730 -nodes \
        -keyout key.pem -out cert.pem \
        -subj '/CN=GitHub Accelerator v6' \
        -addext "subjectAltName=$san" \
        -addext 'basicConstraints=critical,CA:TRUE,pathlength=0' \
        -addext 'keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign' \
        -addext 'extendedKeyUsage=serverAuth' >/dev/null 2>&1 )
    if [ ! -s "$CERT_PEM" ] || [ ! -s "$KEY_PEM" ]; then
        fail '  证书生成失败'; return 1
    fi
    chmod 600 "$KEY_PEM" 2>/dev/null || true
    chmod 644 "$CERT_PEM" 2>/dev/null || true
    cp -f "$CERT_PEM" "$CER_FILE" 2>/dev/null || true

    local fp
    fp="$(cert_fingerprint)"
    good "  证书已生成：${fp:0:16}…  有效期至 $(date -d "@$(cert_not_after)" '+%Y-%m-%d' 2>/dev/null || echo '?')"
    install_ca || true
    return 0
}

# ---------- hosts ----------
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
HOSTS_BEGIN='# === GitHub hosts v6 ('
HOSTS_END='# === end GitHub ==='

hosts_strip_block() {
    local tmp
    tmp="$(mktemp)"
    awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '
        index($0, b) { skip=1; next }
        index($0, e) { skip=0; next }
        !skip { print }
    ' "$HOSTS_FILE" > "$tmp"
    cat "$tmp" > "$HOSTS_FILE"
    rm -f "$tmp"
}

# 写入 hosts 段（$1=1 时只预览不写）
set_hosts_block() {
    local dry="${1:-0}" lines_file tmp
    lines_file="$(mktemp)"
    cat > "$lines_file"

    if [ "$dry" -eq 1 ]; then
        dim '    hosts 将写入以下内容（DryRun 不落盘）：'
        sed 's/^/    /' "$lines_file"
        rm -f "$lines_file"
        return 0
    fi

    local backup="${HOSTS_FILE}.bak-v6-$(date +%Y%m%d-%H%M%S)"
    cp -f "$HOSTS_FILE" "$backup" 2>/dev/null || true
    hosts_strip_block
    tmp="$(mktemp)"
    cat "$HOSTS_FILE" > "$tmp"
    # 去掉尾部空行再加分隔
    printf '\n' >> "$tmp"
    printf '%s %s)\n' "$HOSTS_BEGIN" "$(date '+%Y-%m-%d %H:%M')" >> "$tmp"
    cat "$lines_file" >> "$tmp"
    printf '%s\n' "$HOSTS_END" >> "$tmp"
    cat "$tmp" > "$HOSTS_FILE"
    rm -f "$tmp" "$lines_file"
    flush_dns
    good "  hosts 已写入（备份 $(basename "$backup")）"
}

flush_dns() {
    if command -v resolvectl >/dev/null 2>&1; then resolvectl flush-caches >/dev/null 2>&1
    elif command -v systemd-resolve >/dev/null 2>&1; then systemd-resolve --flush-caches >/dev/null 2>&1
    elif command -v nscd >/dev/null 2>&1; then systemctl restart nscd >/dev/null 2>&1
    elif command -v dscacheutil >/dev/null 2>&1; then dscacheutil -flushcache >/dev/null 2>&1; killall -HUP mDNSResponder >/dev/null 2>&1
    fi
    return 0
}

# ---------- systemd / launchd ----------
SERVICE_FILE_SYSTEM="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_FILE_USER="$HOME/.config/systemd/user/${SERVICE_NAME}.service"

register_service() {
    local node="$1"
    if [ "$V6_INIT" = 'systemd' ]; then
        local target="$SERVICE_FILE_SYSTEM"
        cat > "$target" <<EOF
[Unit]
Description=GitHub Accelerator v6 local TLS proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$V6_DIR
ExecStart=$node $V6_DIR/proxy.js
Restart=on-failure
RestartSec=5
StartLimitBurst=5
Environment=NODE_ENV=production

# 安全性
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$V6_DIR
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "$target"
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
        good "  开机自启已注册（systemd: $SERVICE_NAME）"
        return 0
    elif [ "$V6_OS" = 'macos' ]; then
        local plist="$HOME/Library/LaunchAgents/com.github.accelerator.v6.plist"
        mkdir -p "$(dirname "$plist")"
        cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.github.accelerator.v6</string>
  <key>ProgramArguments</key>
  <array><string>$node</string><string>$V6_DIR/proxy.js</string></array>
  <key>WorkingDirectory</key><string>$V6_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$V6_DIR/proxy.out.log</string>
  <key>StandardErrorPath</key><string>$V6_DIR/proxy.err.log</string>
</dict>
</plist>
EOF
        launchctl unload "$plist" >/dev/null 2>&1 || true
        launchctl load "$plist" >/dev/null 2>&1
        good "  开机自启已注册（launchd）"
        return 0
    fi
    warn '  当前系统没有 systemd/launchd，开机自启不可用（可手动运行 start-proxy.sh）'
    return 1
}

unregister_service() {
    if [ "$V6_INIT" = 'systemd' ]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE_SYSTEM" "$SERVICE_FILE_USER"
        systemctl daemon-reload >/dev/null 2>&1
        return 0
    elif [ "$V6_OS" = 'macos' ]; then
        local plist="$HOME/Library/LaunchAgents/com.github.accelerator.v6.plist"
        launchctl unload "$plist" >/dev/null 2>&1 || true
        rm -f "$plist"
        return 0
    fi
    return 0
}

service_registered() {
    if [ "$V6_INIT" = 'systemd' ]; then
        [ -f "$SERVICE_FILE_SYSTEM" ] || [ -f "$SERVICE_FILE_USER" ]
    else
        [ -f "$HOME/Library/LaunchAgents/com.github.accelerator.v6.plist" ]
    fi
}

# 启动代理（优先 systemd，否则直接 nohup）
start_proxy_service() {
    local node="$1"
    if [ "$V6_INIT" = 'systemd' ] && [ -f "$SERVICE_FILE_SYSTEM" ]; then
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
    else
        local log="$V6_DIR/proxy.daemon.log"
        ( cd "$V6_DIR" && nohup "$node" proxy.js >> "$log" 2>&1 & )
    fi
    # 等待健康
    local i
    for i in $(seq 1 40); do
        if proxy_health "$LISTEN_PORT"; then return 0; fi
        sleep 0.5
    done
    return 1
}

# ---------- 状态文件 ----------
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

write_install_state() {
    local mode="$1" fp="$2" ips="$3"
    local ips_json
    ips_json="$(printf '%s' "$ips" | awk -F',' '{out=""; for(i=1;i<=NF;i++){gsub(/^ +| +$/,"",$i); if($i!=""){out=(out==""?"":out",")"\"" $i "\""}} print out}')"
    cat > "$STATE_PATH" <<EOF
{
  "version": 6,
  "versionString": "$V6_VERSION",
  "installedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "platform": "$V6_OS",
  "mode": "$(json_escape "$mode")",
  "listenPort": $LISTEN_PORT,
  "certFile": "cert.pem",
  "keyFile": "key.pem",
  "certFingerprint": "$(json_escape "$fp")",
  "serviceName": "$SERVICE_NAME",
  "domains": { "github.com": [$ips_json] }
}
EOF
    chmod 600 "$STATE_PATH" 2>/dev/null || true
}

read_install_state_field() {
    local key="$1"
    [ -f "$STATE_PATH" ] || { echo ''; return; }
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\{0,1\\}\\([^\",}]*\\)\"\\{0,1\\}.*/\\1/p" "$STATE_PATH" | head -1
}

# ---------- 网络探测 ----------
# TCP 扫描 GitHub 网段（并行）
tcp_scan() {
    local tmp jobs
    tmp="$(mktemp)"
    {
        for s in 20.205.243 20.27.177 20.201.28 20.205.244 20.27.178; do
            for h in $(seq 140 180); do echo "$s.$h"; done
        done
        for s in $(seq 112 127); do
            for h in $(seq 1 45); do echo "140.82.$s.$h"; done
        done
    } > "$tmp.pool"

    _tcp_probe() { timeout 1 bash -c "echo > /dev/tcp/$1/443" 2>/dev/null && echo "$1"; }
    export -f _tcp_probe
    jobs=$(( $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4) * 32 ))
    [ "$jobs" -gt 256 ] && jobs=256
    [ "$jobs" -lt 32 ] && jobs=32
    xargs -P "$jobs" -I{} bash -c '_tcp_probe {}' < "$tmp.pool" 2>/dev/null | sort -u > "$tmp.live"
    cat "$tmp.live"
    rm -f "$tmp" "$tmp.pool" "$tmp.live"
}

test_path() {
    case "$1" in
        github.com|www.github.com) echo '/octocat' ;;
        *) echo '/' ;;
    esac
}

# 带 SNI 测试单个 IP（2/3 通过）
test_sni() {
    local host="$1" ip="$2" path ok=0 i code
    path="$(test_path "$host")"
    for i in 1 2 3; do
        code="$("${CURL_BIN:-curl}" -s -o /dev/null -w '%{http_code}' --resolve "${host}:443:${ip}" \
                --connect-timeout 2 --max-time 6 "https://${host}${path}" 2>/dev/null)"
        case "$code" in 200|301|302) ok=$((ok+1)); [ "$ok" -ge 2 ] && return 0 ;; esac
    done
    return 1
}

# 无 SNI 测试（Host 头指定域名）
test_nosni() {
    local host="$1" ip="$2" path ok=0 i code
    path="$(test_path "$host")"
    for i in 1 2 3; do
        code="$("${CURL_BIN:-curl}" -k -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 6 \
                "https://${ip}${path}" -H "Host: ${host}" -H "User-Agent: ${UA}" 2>/dev/null)"
        case "$code" in 200|301|302) ok=$((ok+1)); [ "$ok" -ge 2 ] && return 0 ;; esac
    done
    return 1
}

# 无 SNI 时上游证书是否覆盖目标域名且链有效
check_nosni_cert() {
    local host="$1" ip="$2" out subject
    out="$(echo | timeout 8 openssl s_client -connect "${ip}:443" -servername '' 2>/dev/null)" || return 1
    subject="$(printf '%s' "$out" | sed -n 's/^subject=//p' | head -1)"
    # 证书必须覆盖 host（GitHub 无 SNI 时返回 github.com 证书）
    printf '%s' "$subject" | grep -qiE "(^|[/,= ])(\*\.)?${host//./\\.}([^a-z0-9.-]|$)" && return 0
    # subject 里没有就用 SAN
    printf '%s' "$out" | grep -qiE "DNS:[^,]*(\*\.)?${host//./\\.}" && return 0
    return 1
}

# 找可用 IP：$1=host $2=mode(sni|nosni) $3=want $4=Suffixes(空格分隔) $5=MaxTest
find_verified_ips() {
    local host="$1" mode="$2" want="$3" suffixes="$4" max_test="$5"
    local ordered='' ip sfx tested=0 found='' ok

    # 按后缀优先级排序候选
    for sfx in $suffixes; do
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            case "$ip" in *".$sfx") ;; *) continue ;; esac
            case " $ordered " in *" $ip "*) ;; *) ordered="$ordered $ip" ;; esac
        done <<< "$TCP_LIVE"
    done
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        case " $ordered " in *" $ip "*) ;; *) ordered="$ordered $ip" ;; esac
    done <<< "$TCP_LIVE"

    for ip in $ordered; do
        [ "$tested" -ge "$max_test" ] && break
        [ "$(echo "$found" | wc -w)" -ge "$want" ] && break
        tested=$((tested+1))
        if [ "$mode" = 'nosni' ]; then
            ok=0
            test_nosni "$host" "$ip" && ok=1
            if [ "$ok" -eq 1 ]; then
                if check_nosni_cert "$host" "$ip"; then
                    found="$found $ip"
                    dim "      √ $host -> $ip（证书覆盖 $host，链有效）"
                else
                    dim "      - $host -> $ip（无 SNI 证书不匹配）"
                fi
            fi
        else
            if test_sni "$host" "$ip"; then
                found="$found $ip"
            fi
        fi
    done
    echo "$found" | xargs -n1 2>/dev/null | awk 'NF' | head -"$want" | tr '\n' ',' | sed 's/,$//'
}

# 端到端验证（每个服务 2/3 通过）
test_service() {
    local url="$1" insecure="${2:-0}" ok=0 i code
    for i in 1 2 3; do
        if [ "$insecure" -eq 1 ]; then
            code="$("${CURL_BIN:-curl}" -k -s -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 12 "$url" 2>/dev/null)"
        else
            code="$("${CURL_BIN:-curl}" -s -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 12 "$url" 2>/dev/null)"
        fi
        case "$code" in 200|301|302) ok=$((ok+1)); [ "$ok" -ge 2 ] && { echo "$ok"; return 0; } ;; esac
    done
    echo "$ok"
    return 1
}

# HEAD 探测（只取响应头，不下载 body）
# 原因：GFW 对无 SNI 连接限速 ~15-25 KB/s，github.com 首页 360KB 的 GET
# 要 20~30 秒，容易被验证超时误判成「000 失败」；favicon.ico（6KB）
# 用 HEAD 只要 0.3 秒，能准确反映链路是否通。
test_service_head() {
    local url="$1" ok=0 i code
    for i in 1 2 3; do
        code="$("${CURL_BIN:-curl}" -s -I -o /dev/null -w '%{http_code}' \
                --connect-timeout 5 --max-time 25 -H "User-Agent: $UA" "$url" 2>/dev/null)"
        case "$code" in 200|301|302) ok=$((ok+1)); [ "$ok" -ge 2 ] && { echo "$ok"; return 0; } ;; esac
    done
    echo "$ok"
    return 1
}

test_all_services() {
    local spec host path ok all_ok=0
    for spec in "github.com|/favicon.ico" "www.github.com|/favicon.ico" \
                "api.github.com|/" "codeload.github.com|/"; do
        host="${spec%%|*}"
        path="${spec#*|}"
        ok="$(test_service_head "https://${host}${path}")" || true
        if [ "${ok:-0}" -ge 2 ]; then
            good "    $host : $ok/3 ✅"
        else
            warn "    $host : ${ok:-0}/3 ❌"
            all_ok=1
        fi
    done
    return "$all_ok"
}
