#!/usr/bin/env bash
# ============================================================
# GitHub 一键修复 v4  (Linux / macOS)
#
# 自动判断每个域名属于哪种封锁，并采用对应方案：
#   ① DNS 污染 / IP 封锁  -> 换 IP 写入 /etc/hosts（直连）
#   ② SNI 阻断            -> 可选：配置本地 SNI 剥离代理（需 Node.js）
#
# 验证标准：每个服务必须 >=2/3 通过，否则自动重新扫描（最多 3 轮）
#
# 用法：
#   chmod +x fix-github.sh
#   sudo ./fix-github.sh              # 只做 hosts 直连（推荐，无需额外依赖）
#   sudo ./fix-github.sh --proxy      # 启用代理方案（处理 SNI 阻断，需要 Node.js）
#
# 依赖：bash 4+、curl、coreutils（seq/nproc/timeout）
#       可选：node（代理方案）、openssl（生成证书）
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
START_TS=$(date +%s)
MAX_ROUNDS=3

USE_PROXY=0
for a in "$@"; do
    case "$a" in
        --proxy) USE_PROXY=1 ;;
        --no-proxy) USE_PROXY=0 ;;
        -h|--help)
            echo "用法: sudo $0 [--proxy]"
            echo "  --proxy     启用本地代理方案（处理 SNI 阻断，需 Node.js）"
            exit 0 ;;
    esac
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------- 0. 权限与依赖 ----------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "需要 root 权限（修改 $HOSTS）"; info "请用：sudo $0"; exit 1
fi
for c in curl; do
    command -v "$c" >/dev/null 2>&1 || { fail "缺少依赖：$c"; exit 1; }
done
HAS_NODE=0; command -v node >/dev/null 2>&1 && HAS_NODE=1
HAS_OPENSSL=0; command -v openssl >/dev/null 2>&1 && HAS_OPENSSL=1
[[ -f "$SCRIPT_DIR/proxy.js" ]] || { HAS_NODE=0; }
good "root 权限确认 | Node.js: $([[ $HAS_NODE -eq 1 ]] && echo 可用 || echo 未安装) | openssl: $([[ $HAS_OPENSSL -eq 1 ]] && echo 可用 || echo 未安装)"
[[ $USE_PROXY -eq 1 && $HAS_NODE -eq 0 ]] && { warn "要求代理方案但 Node.js 不可用，降级为 hosts 直连"; USE_PROXY=0; }

# ---------- 1. TCP 并行扫描 ----------
info "阶段 1/5：并行探测 GitHub IP 段..."
: > "$WORK/pool.txt"
for s in 20.205.243 20.27.177 20.201.28 20.205.244 20.27.178; do
    for h in $(seq 140 180); do echo "$s.$h"; done
done >> "$WORK/pool.txt"
for s in $(seq 112 127); do
    for h in $(seq 1 45); do echo "140.82.$s.$h"; done
done >> "$WORK/pool.txt"

tcp_probe() { timeout 1 bash -c "echo > /dev/tcp/$1/443" 2>/dev/null && echo "$1"; }
export -f tcp_probe
JOBS=$(( $(nproc 2>/dev/null || echo 4) * 32 )); [[ $JOBS -gt 256 ]] && JOBS=256; [[ $JOBS -lt 32 ]] && JOBS=32
xargs -P "$JOBS" -I{} bash -c 'tcp_probe {}' < "$WORK/pool.txt" > "$WORK/tcp-live.txt" 2>/dev/null || true
TCP_COUNT=$(wc -l < "$WORK/tcp-live.txt" | tr -d ' ')
good "TCP 443 可达：$TCP_COUNT 个 IP"
[[ "$TCP_COUNT" -eq 0 ]] && { fail "没有 IP 可达，网络可能中断"; exit 1; }

# ---------- 2. 检测函数 ----------
# ★ 关键：github.com 必须测「深层路径」，只测根路径会选到
#   「根路径 200 但深层路径 404」的坏 IP（实测 140.82.112.2 就是这种）
test_path() {
    case "$1" in
        github.com|www.github.com) echo "/octocat" ;;
        *) echo "/" ;;
    esac
}
# 带 SNI 测试（严格 >=2/3）
test_with_sni() {
    local host="$1" ip="$2" ok=0 bad=0 code
    for _ in 1 2 3; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "${host}:443:${ip}" \
               --connect-timeout 1 --max-time 2 "https://${host}$(test_path "$host")" 2>/dev/null)
        if [[ "$code" == "200" || "$code" == "301" ]]; then
            ok=$((ok+1)); [[ $ok -ge 2 ]] && return 0
        else
            bad=$((bad+1)); [[ $bad -ge 2 ]] && return 1
        fi
    done
    [[ $ok -ge 2 ]]
}
# 无 SNI 测试（IP 直连 + Host 头）
test_no_sni() {
    local host="$1" ip="$2" ok=0 bad=0 code
    local ua='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/132.0.0.0 Safari/537.36'
    for _ in 1 2 3; do
        code=$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 \
               "https://${ip}$(test_path "$host")" -H "Host: ${host}" -H "User-Agent: ${ua}" 2>/dev/null)
        if [[ "$code" == "200" || "$code" == "301" ]]; then
            ok=$((ok+1)); [[ $ok -ge 2 ]] && return 0
        else
            bad=$((bad+1)); [[ $bad -ge 2 ]] && return 1
        fi
    done
    [[ $ok -ge 2 ]]
}
# 按尾号排序候选
order_candidates() {
    local suffixes="$1" sfx out="$WORK/ordered.txt"
    : > "$out"
    for sfx in $suffixes; do
        grep -E "\.${sfx}$" "$WORK/tcp-live.txt" >> "$out" 2>/dev/null || true
    done
    grep -vxF -f "$out" "$WORK/tcp-live.txt" >> "$out" 2>/dev/null || cat "$WORK/tcp-live.txt" >> "$out"
    awk '!seen[$0]++' "$out"
}
# 在候选里找可用 IP；mode: sni | nosni
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
# 服务验证（>=2/3）
verify_service() {
    local url="$1" extra="$2" ok=0 bad=0 code
    for _ in 1 2 3; do
        code=$(curl $extra -s -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 30 "$url" 2>/dev/null)
        if [[ "$code" == "200" || "$code" == "301" ]]; then
            ok=$((ok+1)); [[ $ok -ge 2 ]] && { echo "$ok"; return; }
        else
            bad=$((bad+1)); [[ $bad -ge 2 ]] && break
        fi
        [[ -n "$extra" ]] && sleep 3
    done
    echo "$ok"
}

# ---------- 3. 逐轮决策 ----------
declare -A MODE IPS
SERVICES=("github.com|2|3 4 19 20 21 22|20" "api.github.com|2|5 6|12" "codeload.github.com|2|9 10|12")

for round in $(seq 1 $MAX_ROUNDS); do
    info "===== 第 $round 轮：检测封锁类型 ====="
    for spec in "${SERVICES[@]}"; do
        IFS='|' read -r host want sfx maxtest <<< "$spec"
        info "  检测 $host ..."
        direct=$(find_ips "$host" "$want" "$sfx" sni "$maxtest" | tr '\n' ' ')
        if [[ $(echo "$direct" | wc -w) -ge 2 ]]; then
            MODE[$host]="direct"; IPS[$host]="$direct"
            good "  $host => 直连 ✅ $direct"; continue
        fi
        if [[ $USE_PROXY -eq 1 ]]; then
            nosni=$(find_ips "$host" "$want" "$sfx" nosni "$maxtest" | tr '\n' ' ')
            if [[ $(echo "$nosni" | wc -w) -ge 2 ]]; then
                MODE[$host]="proxy"; IPS[$host]="$nosni"
                good "  $host => SNI 阻断，走本地代理 ✅ $nosni"; continue
            fi
        fi
        MODE[$host]="fail"; IPS[$host]=""
        warn "  $host => 未找到可用方案"
    done
    # www 跟随 github.com
    if [[ -n "${MODE[github.com]:-}" ]]; then
        MODE[www.github.com]="${MODE[github.com]}"
        IPS[www.github.com]="${IPS[github.com]}"
        good "  www.github.com => 跟随 github.com（${MODE[github.com]}）"
    fi
    FAILED=0
    for spec in "${SERVICES[@]}"; do
        IFS='|' read -r host _ <<< "$spec"
        [[ "${MODE[$host]:-}" == "fail" ]] && FAILED=$((FAILED+1))
    done
    if [[ $FAILED -eq 0 ]]; then break; fi
    warn "有 $FAILED 个服务未找到方案，等待后重试..."
    [[ $round -lt $MAX_ROUNDS ]] && sleep 10
done

FAILED=0
for spec in "${SERVICES[@]}"; do
    IFS='|' read -r host _ <<< "$spec"
    [[ "${MODE[$host]:-}" == "fail" ]] && FAILED=$((FAILED+1))
done
if [[ $FAILED -gt 0 ]]; then
    fail "多轮尝试仍无法找到可用方案（当前网络干扰过强）"; exit 1
fi

# ---------- 4. 代理配置（可选） ----------
NEED_PROXY=0
for h in "${!MODE[@]}"; do [[ "${MODE[$h]}" == "proxy" ]] && NEED_PROXY=1; done

if [[ $NEED_PROXY -eq 1 ]]; then
    info "阶段 3/5：配置 SNI 剥离代理..."
    # 4.1 证书
    if [[ ! -f "$SCRIPT_DIR/cert.pem" || ! -f "$SCRIPT_DIR/key.pem" ]]; then
        if [[ $HAS_OPENSSL -eq 1 ]]; then
            info "  生成自签证书..."
            SAN=""
            for h in "${!MODE[@]}"; do
                [[ "${MODE[$h]}" == "proxy" ]] || continue
                SAN="${SAN}DNS:${h},DNS:*.${h},"
            done
            SAN="${SAN}IP:127.0.0.1"
            ( cd "$SCRIPT_DIR" && openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
                -days 3650 -nodes -subj "/CN=Local GitHub Proxy" -addext "subjectAltName=${SAN}" >/dev/null 2>&1 )
            good "  证书已生成"
        else
            warn "  缺少 openssl，无法生成证书；代理方案将不可用"
        fi
    fi
    # 4.2 信任证书（尽力而为）
    if [[ -f "$SCRIPT_DIR/cert.pem" ]]; then
        if command -v update-ca-certificates >/dev/null 2>&1; then
            cp "$SCRIPT_DIR/cert.pem" /usr/local/share/ca-certificates/local-github-proxy.crt 2>/dev/null \
                && update-ca-certificates >/dev/null 2>&1 && good "  证书已导入系统 CA（Debian/Ubuntu）"
        elif command -v update-ca-trust >/dev/null 2>&1; then
            cp "$SCRIPT_DIR/cert.pem" /etc/pki/ca-trust/source/anchors/local-github-proxy.crt 2>/dev/null \
                && update-ca-trust >/dev/null 2>&1 && good "  证书已导入系统 CA（RHEL/CentOS）"
        else
            warn "  未识别系统 CA 工具，请手动信任 $SCRIPT_DIR/cert.pem"
        fi
        warn "  提示：Chrome 使用独立证书库，可能需另行导入（certutil -d ~/.pki/nssdb -A ...）"
    fi
    # 4.3 生成配置 + 启动代理
    {
        echo '{'
        echo '  "listenPort": 443,'
        echo '  "cert": "cert.pem",'
        echo '  "key": "key.pem",'
        echo '  "domains": {'
        first=1
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
    good "  proxy-config.json 已生成"

    # 停掉监听 443 的旧代理
    if command -v lsof >/dev/null 2>&1; then
        OLD=$(lsof -ti tcp:443 2>/dev/null || true)
        [[ -n "$OLD" ]] && kill -9 $OLD 2>/dev/null || true
    fi
    sleep 1
    ( cd "$SCRIPT_DIR" && nohup node proxy.js >/dev/null 2>&1 & )
    sleep 2
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':443'; then
        good "  代理已启动（127.0.0.1:443）"
    elif command -v lsof >/dev/null 2>&1 && lsof -ti tcp:443 >/dev/null 2>&1; then
        good "  代理已启动（127.0.0.1:443）"
    else
        warn "  代理可能未启动，请检查 $SCRIPT_DIR/proxy.log"
    fi
fi

# ---------- 5. 写入 hosts ----------
info "阶段 4/5：写入 $HOSTS ..."
BACKUP="${HOSTS}.bak-$(date +%Y%m%d-%H%M%S)"
cp "$HOSTS" "$BACKUP"; good "已备份到 $BACKUP"
sed -i "/${MARK_BEGIN}/,/${MARK_END}/d" "$HOSTS"

{
    echo ""
    echo "${MARK_BEGIN} (v4 $(date '+%m-%d %H:%M')) ==="
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
good "hosts 已更新"

# 刷新 DNS
if command -v resolvectl >/dev/null 2>&1; then resolvectl flush-caches 2>/dev/null && good "DNS 缓存已刷新 (resolvectl)"
elif command -v systemd-resolve >/dev/null 2>&1; then systemd-resolve --flush-caches 2>/dev/null && good "DNS 缓存已刷新"
elif command -v nscd >/dev/null 2>&1; then systemctl restart nscd 2>/dev/null && good "DNS 缓存已刷新 (nscd)"
elif command -v dscacheutil >/dev/null 2>&1; then dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null; good "DNS 缓存已刷新 (macOS)"
else warn "未找到 DNS 刷新工具（hosts 会立即生效）"; fi

# ---------- 6. 终验 ----------
info "阶段 5/5：验证（每个服务必须 >=2/3）..."
PASS=0; TOTAL=0
VERIFY_HOSTS=("github.com" "www.github.com" "api.github.com" "codeload.github.com")
for h in "${VERIFY_HOSTS[@]}"; do
    TOTAL=$((TOTAL+1))
    extra=""
    [[ "${MODE[$h]:-}" == "proxy" ]] && extra="--ssl-no-revoke"
    ok=$(verify_service "https://$h$(test_path "$h")" "$extra")
    if [[ $ok -ge 2 ]]; then
        good "  $h : $ok/3 ✅"; PASS=$((PASS+1))
    else
        warn "  $h : $ok/3 ❌"
    fi
done

END_TS=$(date +%s)
echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN} 完成！耗时 $((END_TS - START_TS)) 秒 | 达标 ${PASS}/${TOTAL}${NC}"
[[ $NEED_PROXY -eq 1 ]] && echo -e "${YELLOW} 注意：部分域名依赖本地代理，重启后需重新运行本脚本${NC}"
echo -e "${GREEN} 浏览器请按 Ctrl+Shift+R 强制刷新${NC}"
echo -e "${GREEN} 恢复原状：sudo cp $BACKUP $HOSTS${NC}"
echo -e "${GREEN}======================================================${NC}"
