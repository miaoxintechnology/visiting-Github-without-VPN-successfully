#!/usr/bin/env bash
# ============================================================
# GitHub 加速器 v6 · Linux / macOS
#
# 适用：Linux（systemd 系）或 macOS，在中国大陆网络下访问 github.com
#      遇到 SNI 阻断 / DNS 污染的场景。
#
# 与 Windows 版 v6 功能对齐：
#   · 每域名多选备用 IP（默认 5 个），代理内按健康度排序、自动故障转移
#   · 开机自启（systemd 服务 / launchd）
#   · 私钥用 PEM chmod 600，仅 root 可读（对应 Windows 的 DPAPI+ACL 方案）
#   · 上游证书严格校验，全部失败才降级并记 SECURITY 日志
#   · 代理只服务 allowlist 里的域名
#   · 先起代理并验证，再改 hosts（代理起不来不动 hosts）
#   · 安装状态记录在 install-state.json，便于回滚
#
# 用法：
#   sudo ./fix-github.sh                 # 安装/修复
#   sudo ./fix-github.sh --dry-run       # 只预览计划，不做任何修改
#   sudo ./fix-github.sh --doctor        # 只做体检
#   sudo ./fix-github.sh --no-proxy      # 只做 hosts 直连（不装代理）
#   sudo ./fix-github.sh --ips 5         # 每域名保留几个备用 IP（默认 5）
#   sudo ./fix-github.sh --rounds 0      # 不达标时无限重试（默认 3 轮）
#
# 依赖：bash 4+、curl、openssl；Node.js 没有会自动安装
# ============================================================
set -uo pipefail

V6_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export V6_DIR
# shellcheck source=/dev/null
. "$V6_DIR/common.sh"

# ---------- 参数 ----------
IPS_PER_DOMAIN=5
MAX_ROUNDS=3
NO_PROXY=0
DRY_RUN=0
DOCTOR=0
FORCE_CERT=0
CLEAN_LEGACY=0
NO_PAUSE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ips)        IPS_PER_DOMAIN="${2:-5}"; shift 2 ;;
        --rounds)     MAX_ROUNDS="${2:-3}"; shift 2 ;;
        --port)       LISTEN_PORT="${2:-443}"; shift 2 ;;
        --no-proxy)   NO_PROXY=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --doctor)     DOCTOR=1; shift ;;
        --force-cert) FORCE_CERT=1; shift ;;
        --clean-legacy) CLEAN_LEGACY=1; shift ;;
        --no-pause)   NO_PAUSE=1; shift ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) warn "未知参数：$1"; shift ;;
    esac
done
case "$IPS_PER_DOMAIN" in ''|*[!0-9]*) IPS_PER_DOMAIN=5 ;; esac
case "$MAX_ROUNDS" in ''|*[!0-9]*) MAX_ROUNDS=3 ;; esac
case "$LISTEN_PORT" in ''|*[!0-9]*) LISTEN_PORT=443 ;; esac

# ---------- Banner ----------
show_banner() {
    if [ -n "${GH_ACCEL_NO_ICON:-}" ]; then return 0; fi
    cat <<'BANNER'

   ____ _ _   _   _       _
  / ___(_) |_| | | |_   _| |__
 | |  _| | __| |_| | | | | '_ \
 | |_| | | |_|  _  | |_| | |_) |
  \____|_|\__|_| |_|\__,_|_.__/

BANNER
    echo "=============================================================="
    echo "  GitHub 加速器 v${V6_VERSION}  ·  多 IP + 开机自启 + 全程校验"
    echo "=============================================================="
}

# ---------- 体检 ----------
run_doctor() {
    show_banner
    echo
    info '===== 环境体检 ====='
    if is_root; then good '  权限：root'; else warn '  权限：非 root（安装需要 root）'; fi
    if find_node; then good "  Node.js：$($NODE_BIN --version 2>/dev/null)  $NODE_BIN"; else warn '  Node.js：未安装'; fi
    find_curl
    good "  curl：$("$CURL_BIN" --version 2>/dev/null | head -1)"
    if [ "$CURL_HAS_PARALLEL" -eq 1 ]; then good '  curl 支持 --parallel'; else warn '  curl 不支持 --parallel（会用串行/降级，不影响功能）'; fi

    if [ -f "$STATE_PATH" ]; then
        good "  安装状态：已安装（模式 $(read_install_state_field mode)）"
    else
        warn '  安装状态：未安装（没有 install-state.json）'
    fi

    if service_registered; then good "  开机自启：已注册（$SERVICE_NAME）"; else warn '  开机自启：未注册'; fi

    if port_listening "$LISTEN_PORT"; then good "  端口 $LISTEN_PORT：有进程监听"; else warn "  端口 $LISTEN_PORT：没有进程监听"; fi

    if proxy_health "$LISTEN_PORT"; then good '  代理健康：正常'; else warn '  代理健康：无响应'; fi

    local dns
    dns="$(getent hosts github.com 2>/dev/null | awk '{print $1}' | head -1)"
    if [ "$dns" = '127.0.0.1' ]; then good '  DNS：github.com -> 127.0.0.1（走本机代理）'
    else warn "  DNS：github.com -> ${dns:-解析失败}"; fi

    if [ -f "$CERT_PEM" ]; then
        good "  证书：$($(true) ; cert_fingerprint | cut -c1-16)…  剩余 $(cert_days_left) 天"
    else
        warn '  证书：不存在'
    fi

    if [ -f "$CA_DEBIAN" ] || [ -f "$CA_RHEL" ]; then good '  系统 CA：已安装'; else warn '  系统 CA：未安装'; fi

    echo
    if proxy_health "$LISTEN_PORT" && [ "$dns" = '127.0.0.1' ]; then
        good '体检结论：代理链路正常 ✅'
    else
        warn '体检结论：代理链路不完整，可运行「sudo ./fix-github.sh」重新安装'
    fi
    echo
}

# ---------- 写代理配置 ----------
write_proxy_config() {
    local ips_csv="$1" ips_json
    ips_json="$(printf '%s' "$ips_csv" | tr ',' '\n' | awk 'NF{printf "%s\"%s\"", (n++?", ":" "), $0}')"
    cat > "$CONFIG_PATH" <<EOF
{
  "version": 6,
  "listenPort": $LISTEN_PORT,
  "listenHost": "127.0.0.1",
  "cert": "cert.pem",
  "key": "key.pem",
  "upstreamVerify": "strict",
  "allowDegraded": true,
  "maxBufferBytes": 1048576,
  "maxRewriteBytes": 4194304,
  "connectTimeoutMs": 12000,
  "raceTimeoutMs": 4500,
  "raceConcurrency": 4,
  "bodyTimeoutMs": 180000,
  "logMaxBytes": 2097152,
  "maxConnections": 1024,
  "domains": {
    "github.com": [$ips_json ]
  }
}
EOF
    chmod 600 "$CONFIG_PATH" 2>/dev/null || true
    good "  代理配置已写入（github.com：$(echo "$ips_csv" | tr ',' '\n' | awk 'NF' | wc -l) 个 IP）"
}

# ---------- 主流程 ----------
show_banner

if [ "$DOCTOR" -eq 1 ]; then
    run_doctor
    [ "$NO_PAUSE" -eq 0 ] && [ -t 0 ] && read -r -p '按回车关闭...' _
    exit 0
fi

if [ ! -f "$PROXY_JS" ]; then
    fail "缺少 proxy.js（应位于 $V6_DIR）"
    exit 1
fi

if [ "$DRY_RUN" -eq 0 ]; then
    require_root
    good '管理员权限确认（root）'
fi

# Node
NODE_OK=0
if ensure_node; then
    NODE_OK=1
    good "Node.js：$NODE_BIN（$("$NODE_BIN" --version 2>/dev/null)）"
elif [ "$NO_PROXY" -eq 0 ]; then
    warn 'Node.js 不可用：本次只能做 hosts 直连（无法处理 SNI 阻断）'
    NO_PROXY=1
fi
ensure_curl

# ---------------- 主循环 ----------------
round=0
success=0
hosts_written=0
final_mode=''
final_ips=''
cert_fp=''

while : ; do
    round=$((round+1))
    if [ "$MAX_ROUNDS" -gt 0 ] && [ "$round" -gt "$MAX_ROUNDS" ]; then break; fi
    echo
    info "==================== 第 $round 轮 ===================="

    # 1) TCP 扫描
    info '  并行探测 GitHub 网段（约 10 秒）...'
    TCP_LIVE="$(tcp_scan)"
    if [ -z "$TCP_LIVE" ]; then
        warn '  没有任何 GitHub IP 可达（网络可能中断）'
        if [ "$MAX_ROUNDS" -gt 0 ] && [ "$round" -ge "$MAX_ROUNDS" ]; then break; fi
        sleep 8
        continue
    fi
    good "  TCP 443 可达：$(echo "$TCP_LIVE" | wc -l) 个 IP"

    # 2) 逐域名选 IP
    info '  选择可用 IP（每域名多选备用）...'
    proxy_ips=''
    direct_ips=''
    if [ "$NO_PROXY" -eq 0 ] && [ "$NODE_OK" -eq 1 ]; then
        proxy_ips="$(find_verified_ips 'github.com' 'nosni' "$IPS_PER_DOMAIN" '3 4 19 20 21 22' 48)"
    fi
    direct_ips="$(find_verified_ips 'github.com' 'sni' 2 '3 4 19 20 21 22' 10)"
    api_ips="$(find_verified_ips 'api.github.com' 'sni' "$IPS_PER_DOMAIN" '5 6' 14)"
    codeload_ips="$(find_verified_ips 'codeload.github.com' 'sni' "$IPS_PER_DOMAIN" '9 10' 14)"

    proxy_count="$(echo "$proxy_ips" | tr ',' '\n' | awk 'NF' | wc -l)"
    direct_count="$(echo "$direct_ips" | tr ',' '\n' | awk 'NF' | wc -l)"
    api_count="$(echo "$api_ips" | tr ',' '\n' | awk 'NF' | wc -l)"
    codeload_count="$(echo "$codeload_ips" | tr ',' '\n' | awk 'NF' | wc -l)"

    mode='fail'
    if [ "$proxy_count" -ge 2 ]; then
        mode='proxy'
        good "  github.com => 本地代理（$proxy_count 个 IP）"
    elif [ "$direct_count" -ge 1 ]; then
        mode='direct'
        good "  github.com => 直连（$direct_count 个 IP）"
    else
        warn '  github.com => 未找到可用 IP'
    fi

    if [ "$mode" = 'fail' ] || [ "$api_count" -eq 0 ] || [ "$codeload_count" -eq 0 ]; then
        WarnMsg='  本轮 IP 选择不完整'
        warn "$WarnMsg"
        if [ "$MAX_ROUNDS" -gt 0 ] && [ "$round" -ge "$MAX_ROUNDS" ]; then break; fi
        sleep 6
        continue
    fi

    # raw.githubusercontent.com 选一个可用 IP
    raw_ip='185.199.109.133'
    for cand in 185.199.109.133 185.199.108.133 185.199.110.133 185.199.111.133; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --resolve "raw.githubusercontent.com:443:$cand" \
                --connect-timeout 3 --max-time 8 'https://raw.githubusercontent.com/' 2>/dev/null)"
        case "$code" in 200|301|302) raw_ip="$cand"; break ;; esac
    done

    # 3) DryRun
    if [ "$DRY_RUN" -eq 1 ]; then
        echo
        info '===== DryRun 计划（不会修改任何系统设置）====='
        if [ "$mode" = 'proxy' ]; then
            info '  证书：生成/复用受信任根证书，私钥 PEM chmod 600（仅 root 可读）'
            info "  代理：127.0.0.1:$LISTEN_PORT，仅服务 github.com（$proxy_count 个 IP）"
        else
            info '  证书：直连模式，不需要证书'
            info '  代理：不启用'
        fi
        info "  开机自启：$(if [ "$V6_INIT" = 'systemd' ]; then echo "systemd 服务 $SERVICE_NAME"; elif [ "$V6_OS" = 'macos' ]; then echo 'launchd LaunchAgent'; else echo '当前系统不支持'; fi)"
        info "  api.github.com：$(echo "$api_ips" | tr ',' ' ')"
        info "  codeload.github.com：$(echo "$codeload_ips" | tr ',' ' ')"
        info "  raw.githubusercontent.com：$raw_ip"
        {
            if [ "$mode" = 'proxy' ]; then
                for h in "${ACCEL_DOMAINS[@]}"; do echo "127.0.0.1 $h"; done
            else
                first_direct="$(echo "$direct_ips" | cut -d, -f1)"
                for h in "${ACCEL_DOMAINS[@]}"; do echo "$first_direct $h"; done
            fi
            echo "$api_ips" | tr ',' '\n' | awk 'NF{print $0" api.github.com"}'
            echo "$codeload_ips" | tr ',' '\n' | awk 'NF{print $0" codeload.github.com"}'
            for d in "${RAW_DOMAINS[@]}"; do echo "$raw_ip $d"; done
        } | set_hosts_block 1
        echo
        good 'DryRun 完成：去掉 --dry-run 即可正式安装'
        final_mode="$mode"
        final_ips="$proxy_ips"
        success=1
        break
    fi

    # 4) 证书
    if [ "$mode" = 'proxy' ]; then
        step '1/6' '准备证书（受信任根 + PEM 私钥）'
        stop_proxy >/dev/null 2>&1 || true
        if ! ensure_cert "$FORCE_CERT"; then
            warn '  证书准备失败，本轮跳过'
            if [ "$MAX_ROUNDS" -gt 0 ] && [ "$round" -ge "$MAX_ROUNDS" ]; then break; fi
            sleep 6
            continue
        fi
        cert_fp="$(cert_fingerprint)"

        step '2/6' '写入代理配置'
        write_proxy_config "$proxy_ips"
        write_install_state 'proxy' "$cert_fp" "$proxy_ips"
    else
        step '2/6' '直连模式：写入安装状态'
        write_install_state 'direct' '' "$direct_ips"
    fi

    # 5) 开机自启
    if [ "$mode" = 'proxy' ]; then
        step '3/6' '配置开机自启'
        register_service "$NODE_BIN" || true
    else
        step '3/6' '直连模式：不启用代理/自启'
        stop_proxy >/dev/null 2>&1 || true
        unregister_service >/dev/null 2>&1 || true
    fi

    # 6) 启动代理并验证
    step '4/6' '启动代理并验证（先验证，再改 hosts）'
    ok=0
    if [ "$mode" = 'proxy' ]; then
        if start_proxy_service "$NODE_BIN"; then
            # 严格校验：直接访问 github.com（会被 hosts 之外的真实 DNS 影响，这里用 --resolve 指到 127.0.0.1）
            code="$(curl -s -o /dev/null -w '%{http_code}' --resolve "github.com:443:127.0.0.1" \
                    --connect-timeout 5 --max-time 20 'https://github.com/' 2>/dev/null)"
            case "$code" in
                200|301)
                    good "  代理严格校验通过：HTTP $code（证书受系统信任）"
                    ok=1 ;;
                *)
                    warn "  代理严格校验失败：HTTP $code"
                    # 证书没被信任时 curl 会失败，但浏览器可能已信任；这里不直接判死
                    if [ -f "$CA_DEBIAN" ] || [ -f "$CA_RHEL" ]; then
                        warn '  系统 CA 已安装但校验失败，可能是本机时间/证书链问题'
                    fi
                    ok=0 ;;
            esac
        else
            warn '  代理没有在 20 秒内起来'
        fi
    else
        ok=1
    fi

    if [ "$ok" -ne 1 ] && [ "$mode" = 'proxy' ]; then
        warn '  本轮启动失败（不会修改 hosts）'
        if [ "$MAX_ROUNDS" -gt 0 ] && [ "$round" -ge "$MAX_ROUNDS" ]; then break; fi
        sleep 8
        continue
    fi

    # 7) 写 hosts
    step '5/6' '写入 hosts'
    {
        if [ "$mode" = 'proxy' ]; then
            for h in "${ACCEL_DOMAINS[@]}"; do echo "127.0.0.1 $h"; done
        else
            first_direct="$(echo "$direct_ips" | cut -d, -f1)"
            for h in "${ACCEL_DOMAINS[@]}"; do echo "$first_direct $h"; done
        fi
        echo "$api_ips" | tr ',' '\n' | awk 'NF{print $0" api.github.com"}'
        echo "$codeload_ips" | tr ',' '\n' | awk 'NF{print $0" codeload.github.com"}'
        for d in "${RAW_DOMAINS[@]}"; do echo "$raw_ip $d"; done
    } | set_hosts_block 0
    hosts_written=1

    # 8) 端到端验证
    step '6/6' '端到端验证'
    if test_all_services; then
        success=1
        final_mode="$mode"
        final_ips="$proxy_ips"
        break
    fi
    warn '  有服务未达标'
    if [ "$MAX_ROUNDS" -gt 0 ] && [ "$round" -ge "$MAX_ROUNDS" ]; then break; fi
    sleep 6
done

# ---------------- 结果 ----------------
echo
if [ "$success" -eq 1 ]; then
    echo -e "${GREEN}==============================================================${NC}"
    if [ "$DRY_RUN" -eq 1 ]; then
        good 'DryRun：安装计划预览完成（未修改系统）'
    else
        good "v6 安装完成（$round 轮）"
    fi
    if [ "$final_mode" = 'proxy' ]; then
        good "  代理：https://127.0.0.1:$LISTEN_PORT  仅服务 github.com"
        good "  github.com 备用 IP：$(echo "$final_ips" | tr ',' ' ')"
    elif [ "$final_mode" = 'direct' ]; then
        good '  模式：直连（无需代理）'
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
        if service_registered; then good "  开机自启：已启用（$SERVICE_NAME）"; fi
        if [ "$hosts_written" -eq 1 ]; then good '  hosts：已写入并验证通过'; fi
        echo
        info '提示：浏览器请按 Ctrl+Shift+R 强刷一次；gh CLI 等客户端请完全退出后重开。'
        info '回滚：sudo ./uninstall.sh（删除证书、服务与 hosts 配置）'
        if [ "$CLEAN_LEGACY" -eq 1 ] && [ "$final_mode" = 'proxy' ]; then
            info '正在清理 v5 遗留文件...'
            for d in "$V6_DIR/../v5" "$V6_DIR/../github-hosts-fix" "$HOME/github-hosts-fix"; do
                [ -d "$d" ] || continue
                for f in proxy-config.json proxy-cert.pfx proxy-cert.cer proxy-pass.dat cert.pem key.pem; do
                    if [ -f "$d/$f" ]; then rm -f "$d/$f" && good "  已删除 $d/$f"; fi
                done
            done
        fi
    fi
    echo -e "${GREEN}==============================================================${NC}"
    [ "$NO_PAUSE" -eq 0 ] && [ -t 0 ] && read -r -p '按回车关闭...' _
    exit 0
else
    echo -e "${YELLOW}==============================================================${NC}"
    warn '未能在限定轮次内完成安装'
    if [ "$hosts_written" -eq 1 ]; then
        warn '  hosts 已改为指向本机，但端到端验证未通过；可运行 sudo ./uninstall.sh 恢复，或重新运行本脚本'
    else
        warn '  hosts 未改动（保持原状），可稍后重试'
    fi
    echo -e "${YELLOW}==============================================================${NC}"
    [ "$NO_PAUSE" -eq 0 ] && [ -t 0 ] && read -r -p '按回车关闭...' _
    exit 1
fi
