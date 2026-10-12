#!/usr/bin/env bash
# ============================================================
# GitHub 快速修复 (Linux / macOS)
#
# 并行扫描 GitHub 全部 IP 段，自动找出当前可用的 IP 写入 /etc/hosts。
# 全程约 30~60 秒（比 Windows 版更快，因为 Linux 的并行能力更强）。
#
# 用法：
#   chmod +x fix-github-linux.sh
#   sudo ./fix-github-linux.sh
#
# 依赖：bash 4+、curl（几乎所有发行版都有）
# ============================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[*]${NC} $*"; }
good() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[-]${NC} $*"; }

HOSTS="${HOSTS_FILE:-/etc/hosts}"
MARK_BEGIN='# === GitHub hosts'
MARK_END='# === end GitHub ==='
START_TS=$(date +%s)

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------- 0. 依赖与权限 ----------
for c in curl; do
    command -v "$c" >/dev/null 2>&1 || { warn "缺少依赖：$c，请先安装"; exit 1; }
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "需要 root 权限才能修改 $HOSTS"
    info "请用：sudo $0"
    exit 1
fi
good "root 权限确认"

# ---------- 1. 生成候选 IP 池（亚洲段优先）----------
info "阶段 1/5：生成候选 IP 池..."
: > "$WORK/pool.txt"

# 亚洲段（微软 Azure）—— 实测 github.com 网页在这段更稳，优先扫描
for s in 20.205.243 20.27.177 20.201.28 20.205.244 20.27.178; do
    for h in $(seq 140 180); do echo "$s.$h"; done
done >> "$WORK/pool.txt"

# GitHub 自有段 —— 网页常被封，但 .6/.9 尾号对 api/codeload 通常可用
for s in $(seq 112 127); do
    for h in $(seq 1 45); do echo "140.82.$s.$h"; done
done >> "$WORK/pool.txt"

POOL_COUNT=$(wc -l < "$WORK/pool.txt" | tr -d ' ')
info "候选池：$POOL_COUNT 个 IP"

# ---------- 2. 并行 TCP 探测 ----------
info "阶段 2/5：并行 TCP 探测 443 端口..."
tcp_probe() {
    local ip="$1"
    if timeout 1 bash -c "echo > /dev/tcp/$ip/443" 2>/dev/null; then
        echo "$ip"
    fi
}
export -f tcp_probe

# 并发度按 CPU 核数动态调整（最高 256）
JOBS=$(( $(nproc 2>/dev/null || echo 4) * 32 ))
[[ $JOBS -gt 256 ]] && JOBS=256
[[ $JOBS -lt 32 ]] && JOBS=32

xargs -P "$JOBS" -I{} bash -c 'tcp_probe {}' < "$WORK/pool.txt" > "$WORK/tcp-live.txt" 2>/dev/null || true
TCP_COUNT=$(wc -l < "$WORK/tcp-live.txt" | tr -d ' ')
good "TCP 443 可达：$TCP_COUNT 个 IP"

if [[ "$TCP_COUNT" -eq 0 ]]; then
    warn "没有 IP 可达，网络可能中断"
    exit 1
fi

# ---------- 3. 按服务验证可用性 ----------
# 按 IP 尾号规律排序：.3/.4/.19/.20=网页  .5/.6=api  .9/.10=codeload
order_by_suffix() {
    local suffixes="$1"
    local list="$WORK/ordered.txt"
    : > "$list"
    for sfx in $suffixes; do
        grep -E "\.${sfx}$" "$WORK/tcp-live.txt" >> "$list" 2>/dev/null || true
    done
    # 补齐其余 IP（去重）
    grep -vxF -f "$list" "$WORK/tcp-live.txt" >> "$list" 2>/dev/null || cat "$WORK/tcp-live.txt" >> "$list"
    awk '!seen[$0]++' "$list"
}

# 用法：find_alive <host> <want> <maxTest> "<suffixes>"
find_alive() {
    local host="$1" want="$2" maxtest="$3" suffixes="$4"
    local found=0 tested=0 ip code
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        [[ $found -ge $want || $tested -ge $maxtest ]] && break
        tested=$((tested + 1))
        code=$(curl -s -o /dev/null -w '%{http_code}' \
            --resolve "${host}:443:${ip}" \
            --connect-timeout 1 --max-time 2 \
            "https://${host}" 2>/dev/null)
        if [[ "$code" == "200" || "$code" == "301" ]]; then
            echo "$ip"
            found=$((found + 1))
        fi
    done < <(order_by_suffix "$suffixes")
}

info "阶段 3/5：验证 github.com（目标 8 个）..."
MAIN_IPS=$(find_alive github.com 8 70 "3 4 19 20 21 22" | head -8)
if [[ -z "$MAIN_IPS" ]]; then
    warn "暂未找到可用的 github.com IP（当前干扰较强）"
    warn "建议：等 1~2 分钟后再运行一次"
    exit 1
fi
good "github.com 可用：$(echo "$MAIN_IPS" | tr '\n' ' ')"

info "阶段 4/5：验证 www / api / codeload..."
WWW_IPS=$(find_alive www.github.com 3 30 "3 4 19" | head -3)
API_IPS=$(find_alive api.github.com 3 30 "6 5" | head -3)
CD_IPS=$(find_alive codeload.github.com 3 30 "9 10" | head -3)

# 兜底
[[ -z "$WWW_IPS" ]] && WWW_IPS=$(echo "$MAIN_IPS" | head -2)
[[ -z "$API_IPS" ]] && API_IPS=$(echo "$MAIN_IPS" | head -2)
[[ -z "$CD_IPS" ]] && CD_IPS=$(echo "$MAIN_IPS" | head -2)

good "www: $(echo "$WWW_IPS" | tr '\n' ' ')"
good "api: $(echo "$API_IPS" | tr '\n' ' ')"
good "codeload: $(echo "$CD_IPS" | tr '\n' ' ')"

# ---------- 4. 写入 hosts ----------
info "阶段 5/5：写入 $HOSTS ..."
BACKUP="${HOSTS}.bak-$(date +%Y%m%d-%H%M%S)"
cp "$HOSTS" "$BACKUP"
good "已备份到 $BACKUP"

# 删除旧的 GitHub 段（含 Windows 版脚本写入的段）
sed -i "/${MARK_BEGIN}/,/${MARK_END}/d" "$HOSTS"

{
    echo ""
    echo "${MARK_BEGIN} (fast-fix $(date '+%m-%d %H:%M')) ==="
    while IFS= read -r ip; do [[ -n "$ip" ]] && echo "$ip github.com"; done <<< "$MAIN_IPS"
    while IFS= read -r ip; do [[ -n "$ip" ]] && echo "$ip www.github.com"; done <<< "$WWW_IPS"
    while IFS= read -r ip; do [[ -n "$ip" ]] && echo "$ip api.github.com"; done <<< "$API_IPS"
    while IFS= read -r ip; do [[ -n "$ip" ]] && echo "$ip codeload.github.com"; done <<< "$CD_IPS"
    echo "$(echo "$MAIN_IPS" | head -1) gist.github.com"
    echo "$(echo "$MAIN_IPS" | head -1) collector.github.com"
    # raw CDN（Fastly）常年全段被封，保留占位
    for d in raw.githubusercontent.com assets-cdn.github.com avatars.githubusercontent.com \
             objects.githubusercontent.com avatars0.githubusercontent.com \
             avatars1.githubusercontent.com avatars2.githubusercontent.com; do
        echo "185.199.109.133 $d"
    done
    echo "${MARK_END}"
} >> "$HOSTS"

good "hosts 已更新"

# ---------- 刷新 DNS 缓存 ----------
if command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches 2>/dev/null && good "DNS 缓存已刷新 (resolvectl)"
elif command -v systemd-resolve >/dev/null 2>&1; then
    systemd-resolve --flush-caches 2>/dev/null && good "DNS 缓存已刷新 (systemd-resolve)"
elif command -v nscd >/dev/null 2>&1; then
    systemctl restart nscd 2>/dev/null && good "DNS 缓存已刷新 (nscd)"
elif command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -flushcache 2>/dev/null
    killall -HUP mDNSResponder 2>/dev/null
    good "DNS 缓存已刷新 (macOS)"
else
    warn "未找到 DNS 缓存刷新工具，可忽略（hosts 立即生效）"
fi

# ---------- 验证 ----------
echo ""
info "验证连通性..."
PASS=0
for pair in "github.com|https://github.com" \
            "www|https://www.github.com" \
            "api|https://api.github.com" \
            "codeload|https://codeload.github.com"; do
    name="${pair%%|*}"; url="${pair##*|}"
    ok=0
    for _ in 1 2 3; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "$url" 2>/dev/null)
        [[ "$code" == "200" || "$code" == "301" ]] && ok=$((ok + 1))
    done
    if [[ $ok -ge 2 ]]; then
        good "$name: $ok/3"
        PASS=$((PASS + 1))
    else
        warn "$name: $ok/3（波动，刷新重试即可）"
    fi
done

END_TS=$(date +%s)
echo ""
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} 完成！耗时 $((END_TS - START_TS)) 秒 | 服务可用 ${PASS}/4${NC}"
echo -e "${GREEN} 浏览器请按 Ctrl+Shift+R 强制刷新${NC}"
echo -e "${GREEN} 恢复原状：cp $BACKUP $HOSTS${NC}"
echo -e "${GREEN}====================================================${NC}"
