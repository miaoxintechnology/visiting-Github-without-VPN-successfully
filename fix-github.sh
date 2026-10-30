#!/usr/bin/env bash
# ============================================================
# GitHub 一键修复 v5  (Linux / macOS)
#
# ★ 核心：不达标就自动重试，直到全部服务达标才结束 ★
#   每一轮都会重新扫描 IP、重新判断封锁类型、重新配置，
#   任何一轮全部达标就立即停止；否则自动进入下一轮。
#
# 自动判断每个域名属于哪种封锁，并采用对应方案：
#   ① DNS 污染 / IP 封锁  -> 换 IP 写入 /etc/hosts（直连）
#   ② SNI 阻断            -> 可选：配置本地 SNI 剥离代理（需 Node.js）
#
# 验证标准：每个服务必须 >=2/3 通过（github.com 用深层路径验证）
#
# 用法：
#   chmod +x fix-github.sh
#   sudo ./fix-github.sh                    # 只做 hosts 直连
#   sudo ./fix-github.sh --proxy            # 启用代理方案（处理 SNI 阻断）
#   sudo ./fix-github.sh --max-rounds 5     # 限制最多 5 轮（默认 0=无限）
#
# 依赖：bash 4+、curl、coreutils；可选：node（代理）、openssl（证书）
# ============================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[*]${NC} $*"; }
good() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[-]${NC} $*"; }
fail() { echo -e "${RED}[x]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTS="${HOSTS_FILE:-/etc/hosts}"
MARK_BEGIN='# === GitHub hosts'
MARK_END='# === end GitHub ==='
TOTAL_START=$(date +%s)

USE_PROXY=0
NO_PROXY_FLAG=0
MAX_ROUNDS=0    # 0 = 无限重试直到达标

# 参数解析
while [[ $# -gt 0 ]]; do
    case "$1" in
        --proxy) USE_PROXY=1; shift ;;
        --no-proxy) USE_PROXY=0; NO_PROXY_FLAG=1; shift ;;
        --max-rounds)
            MAX_ROUNDS="${2:-0}"
            [[ "$MAX_ROUNDS" =~ ^[0-9]+$ ]] || MAX_ROUNDS=0
            shift; [[ $# -gt 0 ]] && shift ;;
        -h|--help)
            echo "用法: sudo $0 [--proxy] [--max-rounds N]"
            echo "  --proxy          启用本地代理方案（处理 SNI 阻断，需 Node.js）"
            echo "  --max-rounds N   最多重试 N 轮（默认 0 = 无限重试直到达标）"
            exit 0 ;;
        *) shift ;;
    esac
done

# ---------- 0. 权限与依赖 ----------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "需要 root 权限（修改 $HOSTS）"; info "请用：sudo $0"; exit 1
fi
for c in curl; do
    command -v "$c" >/dev/null 2>&1 || { fail "缺少依赖：$c"; exit 1; }
done
HAS_OPENSSL=0; command -v openssl >/dev/null 2>&1 && HAS_OPENSSL=1

# ★ 不要求用户预先安装 Node.js：没有就自动装
HAS_NODE=0
NODE_BIN=""

ensure_node() {
    # 1) 系统已装
    if command -v node >/dev/null 2>&1; then
        HAS_NODE=1; NODE_BIN="$(command -v node)"; return 0
    fi
    # 2) 本脚本目录下的便携版
    local nb
    nb=$(find "$SCRIPT_DIR/.node" -name node -type f -path '*/bin/*' 2>/dev/null | head -1)
    if [[ -n "$nb" && -x "$nb" ]]; then
        export PATH="$(dirname "$nb"):$PATH"
        HAS_NODE=1; NODE_BIN="$nb"; return 0
    fi

    info "未检测到 Node.js，正在自动安装（无需手动操作）..."
    # 3) 包管理器
    if command -v apt-get >/dev/null 2>&1; then
        info "  [1/3] apt-get install nodejs ..."
        (apt-get update -qq && apt-get install -y nodejs) >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        info "  [1/3] dnf install nodejs ..."; dnf install -y nodejs >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        info "  [1/3] yum install nodejs ..."; yum install -y nodejs >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        info "  [1/3] pacman -S nodejs ..."; pacman -Sy --noconfirm nodejs >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        info "  [1/3] zypper install nodejs ..."; zypper -n install nodejs >/dev/null 2>&1
    fi
    if command -v node >/dev/null 2>&1; then
        HAS_NODE=1; NODE_BIN="$(command -v node)"
        good "  包管理器安装成功：$NODE_BIN"; return 0
    fi
    warn "  包管理器未成功，改为下载二进制..."

    # 4) 下载官方二进制（国内镜像优先）
    local arch ver
    case "$(uname -m)" in
        x86_64|amd64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) arch="x64" ;;
    esac
    for ver in v22.11.0 v20.18.0; do
        for m in "https://cdn.npmmirror.com/binaries/node/$ver/node-$ver-linux-$arch.tar.xz" \
                 "https://nodejs.org/dist/$ver/node-$ver-linux-$arch.tar.xz"; do
            info "  [2/3] 下载：$m"
            if curl -fsSL --connect-timeout 15 --max-time 240 "$m" -o /tmp/node-dl.tar.xz 2>/dev/null \
               && [[ -s /tmp/node-dl.tar.xz ]] && [[ $(stat -c%s /tmp/node-dl.tar.xz 2>/dev/null || echo 0) -gt 5000000 ]]; then
                info "  [3/3] 解压中..."
                mkdir -p "$SCRIPT_DIR/.node"
                if tar -xJf /tmp/node-dl.tar.xz -C "$SCRIPT_DIR/.node" 2>/dev/null; then
                    rm -f /tmp/node-dl.tar.xz
                    nb=$(find "$SCRIPT_DIR/.node" -name node -type f -path '*/bin/*' 2>/dev/null | head -1)
                    if [[ -n "$nb" && -x "$nb" ]]; then
                        export PATH="$(dirname "$nb"):$PATH"
                        HAS_NODE=1; NODE_BIN="$nb"
                        good "  便携版已就绪：$NODE_BIN"; return 0
                    fi
                fi
            fi
            rm -f /tmp/node-dl.tar.xz 2>/dev/null
        done
    done
    return 1
}

# 默认启用代理方案（proxy.js 存在时），因为 github.com 的 SNI 常被阻断
if [[ -f "$SCRIPT_DIR/proxy.js" && $USE_PROXY -eq 0 && "${NO_PROXY_FLAG:-0}" -eq 0 ]]; then
    USE_PROXY=1
fi
if [[ $USE_PROXY -eq 1 ]]; then
    if ! ensure_node; then
        warn "Node.js 自动安装失败，降级为 hosts 直连（无法处理 SNI 阻断）"
        USE_PROXY=0
    fi
else
    command -v node >/dev/null 2>&1 && { HAS_NODE=1; NODE_BIN="$(command -v node)"; }
fi

good "root ✅ | Node.js: $([[ $HAS_NODE -eq 1 ]] && echo "可用 ($NODE_BIN)" || echo 未安装) | openssl: $([[ $HAS_OPENSSL -eq 1 ]] && echo 可用 || echo 未安装)"
if [[ $MAX_ROUNDS -eq 0 ]]; then
    info "重试策略：不限轮次，直到全部达标才结束（Ctrl+C 可中止）"
else
    info "重试策略：最多 $MAX_ROUNDS 轮"
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------- 1. 工具函数 ----------
# github.com 必须测深层路径：只测根路径会选到「根路径200但深层404」的坏 IP
test_path() {
    case "$1" in
        github.com|www.github.com) echo "/octocat" ;;
        *) echo "/" ;;
    esac
}

test_with_sni() {
    local host="$1" ip="$2" ok=0 bad=0 code path
    path=$(test_path "$host")
    for _ in 1 2 3; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "${host}:443:${ip}" \
               --connect-timeout 1 --max-time 2 "https://${host}${path}" 2>/dev/null)
        if [[ "$code" == "200" || "$code" == "301" ]]; then
            ok=$((ok+1)); [[ $ok -ge 2 ]] && return 0
        else
            bad=$((bad+1)); [[ $bad -ge 2 ]] && return 1
        fi
    done
    [[ $ok -ge 2 ]]
}

test_no_sni() {
    local host="$1" ip="$2" ok=0 bad=0 code path
    local ua='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/132.0.0.0 Safari/537.36'
    path=$(test_path "$host")
    for _ in 1 2 3; do
        code=$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 \
               "https://${ip}${path}" -H "Host: ${host}" -H "User-Agent: ${ua}" 2>/dev/null)
        if [[ "$code" == "200" || "$code" == "301" ]]; then
            ok=$((ok+1)); [[ $ok -ge 2 ]] && return 0
        else
            bad=$((bad+1)); [[ $bad -ge 2 ]] && return 1
        fi
    done
    [[ $ok -ge 2 ]]
}

order_candidates() {
    local suffixes="$1" sfx out="$WORK/ordered.txt"
    : > "$out"
    for sfx in $suffixes; do
        grep -E "\.${sfx}$" "$WORK/tcp-live.txt" >> "$out" 2>/dev/null || true
    done
    grep -vxF -f "$out" "$WORK/tcp-live.txt" >> "$out" 2>/dev/null || cat "$WORK/tcp-live.txt" >> "$out"
    awk '!seen[$0]++' "$out"
}

find_ips() {
    local host="$1" want="$2" suffixes="$3" mode="$4" maxtest="$5"
    local ip found=0 tested=0
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        [[ $found -ge $want || $tested -ge $maxtest ]] && break
        tested=$((tested+1))
        if [[ "$mode" == "nosni" ]]; then
            test_no_sni "$host" "$ip" && { echo "$ip"; found=$((found+1)); }
        else
            test_with_sni "$host" "$ip" && { echo "$ip"; found=$((found+1)); }
        fi
    done < <(order_candidates "$suffixes")
}

verify_service() {
    local url="$1" extra="$2" ok=0 bad=0 code
    for _ in 1 2 3; do
        code=$(curl $extra -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "$url" 2>/dev/null)
        if [[ "$code" == "200" || "$code" == "301" ]]; then
            ok=$((ok+1)); [[ $ok -ge 2 ]] && { echo "$ok"; return; }
        else
            bad=$((bad+1)); [[ $bad -ge 2 ]] && break
        fi
        [[ -n "$extra" ]] && sleep 2
    done
    echo "$ok"
}

# ---------- 2. 一轮：TCP 扫描 ----------
scan_tcp() {
    : > "$WORK/pool.txt"
    for s in 20.205.243 20.27.177 20.201.28 20.205.244 20.27.178; do
        for h in $(seq 140 180); do echo "$s.$h"; done
    done >> "$WORK/pool.txt"
    for s in $(seq 112 127); do
        for h in $(seq 1 45); do echo "140.82.$s.$h"; done
    done >> "$WORK/pool.txt"

    tcp_probe() { timeout 1 bash -c "echo > /dev/tcp/$1/443" 2>/dev/null && echo "$1"; }
    export -f tcp_probe
    local jobs=$(( $(nproc 2>/dev/null || echo 4) * 32 ))
    [[ $jobs -gt 256 ]] && jobs=256; [[ $jobs -lt 32 ]] && jobs=32
    xargs -P "$jobs" -I{} bash -c 'tcp_probe {}' < "$WORK/pool.txt" > "$WORK/tcp-live.txt" 2>/dev/null || true
    wc -l < "$WORK/tcp-live.txt" | tr -d ' '
}

# ---------- 3. 一轮：决策 ----------
declare -A MODE IPS
SERVICES=("github.com|3 4 19 20 21 22|20" "api.github.com|5 6|12" "codeload.github.com|9 10|12")

do_decisions() {
    MODE=(); IPS=()
    for spec in "${SERVICES[@]}"; do
        IFS='|' read -r host sfx maxtest <<< "$spec"
        local prefer=0 nosni direct
        [[ $USE_PROXY -eq 1 && "$host" == "github.com" ]] && prefer=1

        if [[ $prefer -eq 1 ]]; then
            nosni=$(find_ips "$host" 2 "$sfx" nosni "$maxtest" | tr '\n' ' ')
            if [[ $(echo "$nosni" | wc -w) -ge 2 ]]; then
                MODE[$host]="proxy"; IPS[$host]="$nosni"
                good "  $host => 本地代理 ✅ $nosni"; continue
            fi
        fi

        direct=$(find_ips "$host" 2 "$sfx" sni "$maxtest" | tr '\n' ' ')
        if [[ $(echo "$direct" | wc -w) -ge 2 ]]; then
            MODE[$host]="direct"; IPS[$host]="$direct"
            good "  $host => 直连 ✅ $direct"; continue
        fi

        if [[ $USE_PROXY -eq 1 && $prefer -eq 0 ]]; then
            nosni=$(find_ips "$host" 2 "$sfx" nosni "$maxtest" | tr '\n' ' ')
            if [[ $(echo "$nosni" | wc -w) -ge 2 ]]; then
                MODE[$host]="proxy"; IPS[$host]="$nosni"
                good "  $host => SNI 阻断，本地代理 ✅ $nosni"; continue
            fi
        fi

        MODE[$host]="fail"; IPS[$host]=""
        warn "  $host => 未找到可用方案"
    done
    if [[ -n "${MODE[github.com]:-}" ]]; then
        MODE[www.github.com]="${MODE[github.com]}"
        IPS[www.github.com]="${IPS[github.com]}"
        good "  www.github.com => 跟随 github.com（${MODE[github.com]}）"
    fi
}

# ---------- 4. 一轮：配置代理 ----------
do_proxy_config() {
    local need=0 h
    for h in "${!MODE[@]}"; do [[ "${MODE[$h]}" == "proxy" ]] && need=1; done
    [[ $need -eq 0 ]] && return 0

    info "  配置 SNI 剥离代理..."
    if [[ ! -f "$SCRIPT_DIR/cert.pem" || ! -f "$SCRIPT_DIR/key.pem" ]]; then
        if [[ $HAS_OPENSSL -eq 1 ]]; then
            local san=""
            for h in "${!MODE[@]}"; do
                [[ "${MODE[$h]}" == "proxy" ]] || continue
                san="${san}DNS:${h},DNS:*.${h},"
            done
            san="${san}IP:127.0.0.1"
            ( cd "$SCRIPT_DIR" && openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
                -days 3650 -nodes -subj "/CN=Local GitHub Proxy" -addext "subjectAltName=${san}" >/dev/null 2>&1 )
            good "    证书已生成"
        else
            warn "    缺少 openssl，代理方案不可用"
            return 0
        fi
    fi
    if [[ -f "$SCRIPT_DIR/cert.pem" ]]; then
        if command -v update-ca-certificates >/dev/null 2>&1; then
            cp -f "$SCRIPT_DIR/cert.pem" /usr/local/share/ca-certificates/local-github-proxy.crt 2>/dev/null \
                && update-ca-certificates >/dev/null 2>&1 && good "    已导入系统 CA"
        elif command -v update-ca-trust >/dev/null 2>&1; then
            cp -f "$SCRIPT_DIR/cert.pem" /etc/pki/ca-trust/source/anchors/local-github-proxy.crt 2>/dev/null \
                && update-ca-trust >/dev/null 2>&1 && good "    已导入系统 CA"
        fi
    fi
    {
        echo '{'
        echo '  "listenPort": 443,'
        echo '  "cert": "cert.pem",'
        echo '  "key": "key.pem",'
        echo '  "domains": {'
        local first=1 ips ip
        for h in "${!MODE[@]}"; do
            [[ "${MODE[$h]}" == "proxy" ]] || continue
            ips=""
            for ip in ${IPS[$h]}; do ips="${ips}\"${ip}\","; done
            ips="${ips%,}"
            [[ $first -eq 0 ]] && echo ','
            printf '    "%s": [%s]' "$h" "$ips"
            first=0
        done
        echo ''
        echo '  }'
        echo '}'
    } > "$SCRIPT_DIR/proxy-config.json"
    good "    proxy-config.json 已生成"

    if command -v lsof >/dev/null 2>&1; then
        for pid in $(lsof -ti tcp:443 2>/dev/null || true); do
            [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == "node" ]] && kill -9 "$pid" 2>/dev/null || true
        done
    fi
    sleep 1
    ( cd "$SCRIPT_DIR" && nohup node proxy.js >/dev/null 2>&1 & )
    sleep 2
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':443'; then
        good "    代理已启动 (127.0.0.1:443)"
    else
        warn "    代理可能未启动，检查 proxy.log"
    fi
}

# ---------- 5. 一轮：写 hosts ----------
do_write_hosts() {
    local backup="${HOSTS}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$HOSTS" "$backup"
    sed -i "/${MARK_BEGIN}/,/${MARK_END}/d" "$HOSTS"

    {
        echo ""
        echo "${MARK_BEGIN} (v5 $(date '+%m-%d %H:%M')) ==="
        for spec in "${SERVICES[@]}"; do
            IFS='|' read -r host _ <<< "$spec"
            if [[ "${MODE[$host]}" == "proxy" ]]; then
                echo "127.0.0.1 $host"
            else
                for ip in ${IPS[$host]}; do echo "$ip $host"; done
            fi
        done
        if [[ "${MODE[www.github.com]}" == "proxy" ]]; then
            echo "127.0.0.1 www.github.com"
        else
            for ip in ${IPS[www.github.com]}; do echo "$ip www.github.com"; done
        fi
        if [[ "${MODE[github.com]}" == "proxy" ]]; then
            echo "127.0.0.1 gist.github.com"
            echo "127.0.0.1 collector.github.com"
        else
            first_ip=$(echo "${IPS[github.com]}" | awk '{print $1}')
            echo "$first_ip gist.github.com"
            echo "$first_ip collector.github.com"
        fi
        for d in raw.githubusercontent.com assets-cdn.github.com avatars.githubusercontent.com \
                 objects.githubusercontent.com avatars0.githubusercontent.com \
                 avatars1.githubusercontent.com avatars2.githubusercontent.com; do
            echo "185.199.109.133 $d"
        done
        echo "${MARK_END}"
    } >> "$HOSTS"
    good "    hosts 已更新（备份 $(basename "$backup")）"

    if command -v resolvectl >/dev/null 2>&1; then resolvectl flush-caches 2>/dev/null
    elif command -v systemd-resolve >/dev/null 2>&1; then systemd-resolve --flush-caches 2>/dev/null
    elif command -v nscd >/dev/null 2>&1; then systemctl restart nscd 2>/dev/null
    elif command -v dscacheutil >/dev/null 2>&1; then dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
    fi
}

# ---------- 6. 一轮：验证 ----------
do_verify() {
    local all_pass=1 h extra ok
    for h in github.com www.github.com api.github.com codeload.github.com; do
        extra=""
        [[ "${MODE[$h]:-}" == "proxy" ]] && extra="--ssl-no-revoke"
        ok=$(verify_service "https://$h$(test_path "$h")" "$extra")
        if [[ $ok -ge 2 ]]; then
            good "    $h : $ok/3 ✅"
        else
            warn "    $h : $ok/3 ❌"
            all_pass=0
        fi
    done
    [[ $all_pass -eq 1 ]]
}

# ---------- 7. 主循环：不达标就一直重试 ----------
round=0
success=0
while true; do
    round=$((round+1))
    [[ $MAX_ROUNDS -gt 0 && $round -gt $MAX_ROUNDS ]] && break
    round_start=$(date +%s)
    echo ""
    if [[ $round -eq 1 ]]; then
        info "==================== 开始修复 ===================="
    else
        info "==================== 第 $round 轮（自动重试） ===================="
    fi

    info "  并行探测 IP 段..."
    TCP_COUNT=$(scan_tcp)
    if [[ "$TCP_COUNT" -eq 0 ]]; then
        warn "  没有 IP 可达（网络可能中断）"
    else
        good "  TCP 443 可达：$TCP_COUNT 个 IP"
    fi

    if [[ "$TCP_COUNT" -gt 0 ]]; then
        do_decisions
    else
        MODE=(); IPS=()
    fi

    FAIL_COUNT=0
    for spec in "${SERVICES[@]}"; do
        IFS='|' read -r host _ <<< "$spec"
        [[ -z "${MODE[$host]:-}" || "${MODE[$host]}" == "fail" ]] && FAIL_COUNT=$((FAIL_COUNT+1))
    done

    if [[ $FAIL_COUNT -gt 0 ]]; then
        warn "  有 $FAIL_COUNT 个服务未找到方案"
    else
        do_proxy_config
        do_write_hosts
        info "  验证（每服务需 >=2/3）..."
        if do_verify; then
            success=1
            break
        fi
        warn "  有服务未达标"
    fi

    [[ $MAX_ROUNDS -gt 0 && $round -ge $MAX_ROUNDS ]] && break
    round_elapsed=$(( $(date +%s) - round_start ))
    warn "  本轮耗时 ${round_elapsed}s，10 秒后自动重试（Ctrl+C 可中止，已 $round 轮）"
    sleep 10
done

# ---------- 8. 结果 ----------
TOTAL=$(( $(date +%s) - TOTAL_START ))
echo ""
echo -e "${GREEN}============================================================${NC}"
if [[ $success -eq 1 ]]; then
    echo -e "${GREEN} 修复成功！共 $round 轮，总耗时 ${TOTAL} 秒${NC}"
    echo -e "${GREEN} 全部服务已达标 ✅${NC}"
    NEED_PROXY=0
    for h in "${!MODE[@]}"; do [[ "${MODE[$h]}" == "proxy" ]] && NEED_PROXY=1; done
    [[ $NEED_PROXY -eq 1 ]] && echo -e "${YELLOW} 注意：部分域名依赖本地代理，重启后需重新运行本脚本${NC}"
    echo -e "${GREEN} 浏览器请按 Ctrl+Shift+R 强制刷新${NC}"
else
    echo -e "${YELLOW} 已达最大轮次限制（$round 轮），仍未全部达标${NC}"
    echo -e "${YELLOW} 可重新运行本脚本，或去掉 --max-rounds 让它无限重试${NC}"
fi
echo -e "${GREEN}============================================================${NC}"
