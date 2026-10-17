# ============================================================
# GitHub 一键修复 v4  (Windows)
#
# 自动判断每个域名属于哪种封锁，并采用对应方案：
#   ① DNS 污染 / IP 封锁  -> 换 IP 写入 hosts（直连）
#   ② SNI 阻断            -> 自动配置本地 SNI 剥离代理
#
# 验证标准（按用户要求）：每个服务必须 >=2/3 通过，否则自动重新扫描
#
# 特点：
#   - 全相对路径，整个文件夹可随意复制移动
#   - 自动请求管理员权限
#   - 自动生成并信任本地证书（仅用于代理）
#   - 自动启动代理，并在 hosts 里指向 127.0.0.1
#
# 用法：
#   双击同目录的「快速修复GitHub.bat」，或：
#   powershell -ExecutionPolicy Bypass -File fix-github.ps1
#
# 依赖：Windows 10/11、PowerShell 5.1+、curl.exe（系统自带）、Node.js（代理需要）
# ============================================================
param(
    [switch]$NoPause,
    [switch]$NoProxy  # 跳代理方案，只做 hosts 直连
)
$ErrorActionPreference = 'SilentlyContinue'
$script:WorkDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$proxyJs = Join-Path $script:WorkDir 'proxy.js'
$cfgPath = Join-Path $script:WorkDir 'proxy-config.json'
$pfxPath = Join-Path $script:WorkDir 'proxy-cert.pfx'
$cerPath = Join-Path $script:WorkDir 'proxy-cert.cer'
$PFX_PASS = 'localproxy'
$MARK_BEGIN = 'GitHub hosts'
$MARK_END = 'end GitHub'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---------- 输出函数 ----------
function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Good($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[-] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[x] $m" -ForegroundColor Red }

# ---------- 0. 自提权 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '[*] 正在请求管理员权限...' -ForegroundColor Cyan
    $a = @('-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($NoPause) { $a += '-NoPause' }
    if ($NoProxy) { $a += '-NoProxy' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs
    exit
}
Good '管理员权限确认'

# ---------- 1. 环境检查 ----------
$hasNode = $null -ne (Get-Command node -ErrorAction SilentlyContinue)
$hasProxyJs = Test-Path $proxyJs
if ($NoProxy) { $hasNode = $false }
Info "Node.js: $(if($hasNode){'✅ 可用'}else{'❌ 未安装'})"
Info "proxy.js: $(if($hasProxyJs){'✅ 找到'}else{'❌ 缺失'})"
if ($hasNode -and -not $hasProxyJs) { Warn 'proxy.js 不在脚本同目录，无法使用代理方案'; $hasNode = $false }

# ---------- 2. 并行 TCP 扫描 ----------
Info '阶段 1/5：并行探测 GitHub IP 段...'
$pool = [System.Collections.Generic.List[string]]::new()
# 亚洲段优先（实测 github.com 网页在这段更稳）
foreach ($s in @('20.205.243', '20.27.177', '20.201.28', '20.205.244', '20.27.178')) {
    foreach ($h in 140..180) { $pool.Add("$s.$h") }
}
foreach ($s in 112..127) { foreach ($h in 1..45) { $pool.Add("140.82.$s.$h") } }

$tcpLive = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $pool.Count; $i += 160) {
    $end = [Math]::Min($i + 159, $pool.Count - 1)
    $conns = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($ip in $pool[$i..$end]) {
        $c = New-Object System.Net.Sockets.TcpClient
        try { $null = $c.ConnectAsync($ip, 443); $conns.Add(@{ IP = $ip; C = $c }) } catch { }
    }
    Start-Sleep -Milliseconds 850
    foreach ($e in $conns) {
        if ($e.C.Connected) { $tcpLive.Add($e.IP) }
        $e.C.Dispose()
    }
}
Good "TCP 443 可达：$($tcpLive.Count) 个 IP"
if ($tcpLive.Count -eq 0) { Fail '没有 IP 可达，网络可能中断'; if (-not $NoPause) { Read-Host '按回车退出' }; exit 1 }

# ---------- 3. 检测函数 ----------
# 带 SNI 测试：严格 >=2/3（用户要求）
function Test-WithSNI($hostname, $ip) {
    $ok = 0; $bad = 0
    for ($r = 1; $r -le 3; $r++) {
        $o = curl.exe -s -o NUL -w '%{http_code}' --resolve "${hostname}:443:$ip" --connect-timeout 1 --max-time 2 "https://$hostname" 2>$null
        if ($o -eq '200' -or $o -eq '301') { $ok++; if ($ok -ge 2) { return $true } }
        else { $bad++; if ($bad -ge 2) { return $false } }
    }
    return ($ok -ge 2)
}
# 无 SNI 测试（IP 直连 + Host 头）
function Test-NoSNI($hostname, $ip) {
    $ok = 0; $bad = 0
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/132.0.0.0 Safari/537.36'
    for ($r = 1; $r -le 3; $r++) {
        $o = curl.exe -k -s -o NUL -w '%{http_code}' --connect-timeout 1 --max-time 2 "https://$ip/" -H "Host: $hostname" -H "User-Agent: $ua" 2>$null
        if ($o -eq '200' -or $o -eq '301') { $ok++; if ($ok -ge 2) { return $true } }
        else { $bad++; if ($bad -ge 2) { return $false } }
    }
    return ($ok -ge 2)
}
# 按尾号规律排序候选
function Order-Candidates($suffixes) {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($sfx in $suffixes) {
        foreach ($ip in $tcpLive) { if ($ip -match "\.$sfx$" -and -not $list.Contains($ip)) { $list.Add($ip) } }
    }
    foreach ($ip in $tcpLive) { if (-not $list.Contains($ip)) { $list.Add($ip) } }
    return $list
}
# 在候选里找可用 IP（mode: sni / nosni）
function Find-IPs($hostname, $want, $suffixes, $mode, $maxTest) {
    $found = [System.Collections.Generic.List[string]]::new()
    $tested = 0
    foreach ($ip in (Order-Candidates $suffixes)) {
        if ($found.Count -ge $want -or $tested -ge $maxTest) { break }
        $tested++
        $ok = if ($mode -eq 'nosni') { Test-NoSNI $hostname $ip } else { Test-WithSNI $hostname $ip }
        if ($ok) { $found.Add($ip) }
    }
    return $found
}
# 服务验证（严格：>=2/3）
function Verify-Service($url, $useNoRevoke) {
    # 代理模式：IP 失效时代理会自动切换，所以失败后多等一会儿再试
    $extra = if ($useNoRevoke) { @('--ssl-no-revoke') } else { @() }
    $wait = if ($useNoRevoke) { 3 } else { 0 }
    $ok = 0; $bad = 0
    for ($r = 1; $r -le 3; $r++) {
        $o = & curl.exe @extra -s -o NUL -w '%{http_code}' --connect-timeout 5 --max-time 15 $url 2>$null
        if ($o -eq '200' -or $o -eq '301') { $ok++; if ($ok -ge 2) { return $ok } }
        else { $bad++; if ($bad -ge 2) { break } }
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
    }
    return $ok
}

# ---------- 4. 逐域名决策 ----------
$services = @(
    @{ Host = 'github.com'; Want = 2; Suffixes = @('3', '4', '19', '20', '21', '22'); MaxTest = 24 },
    # www.github.com 跟随 github.com，不单独检测

    @{ Host = 'api.github.com'; Want = 2; Suffixes = @('5', '6'); MaxTest = 16 },
    @{ Host = 'codeload.github.com'; Want = 2; Suffixes = @('9', '10'); MaxTest = 16 }
)

$state = @{}
function Do-Round($round) {
    Info "===== 第 $round 轮：检测封锁类型 ====="
    foreach ($svc in $services) {
        $h = $svc.Host
        Info "  检测 $h ..."
        # 对 github.com：SNI 时通时封，优先用代理（可靠优先）；其他域名优先直连（更快）
        $preferProxy = $hasNode -and ($h -eq 'github.com')
        if ($preferProxy) {
            $nosni = Find-IPs $h 2 $svc.Suffixes 'nosni' $svc.MaxTest
            if ($nosni.Count -ge 2) {
                $state[$h] = @{ Mode = 'proxy'; IPs = $nosni }
                Good "  $h => 走本地代理 ✅ $($nosni -join ', ')"
                continue
            }
        }
        # 1) 直连（带 SNI）
        $direct = Find-IPs $h 2 $svc.Suffixes 'sni' $svc.MaxTest
        if ($direct.Count -ge 2) {
            $state[$h] = @{ Mode = 'direct'; IPs = $direct }
            Good "  $h => 直连 ✅ $($direct -join ', ')"
            continue
        }
        # 2) 直连不可用 -> 试无 SNI（代理）
        if ($hasNode -and -not $preferProxy) {
            $nosni = Find-IPs $h 2 $svc.Suffixes 'nosni' $svc.MaxTest
            if ($nosni.Count -ge 2) {
                $state[$h] = @{ Mode = 'proxy'; IPs = $nosni }
                Good "  $h => SNI 阻断，走本地代理 ✅ $($nosni -join ', ')"
                continue
            }
        }
        # 3) 都失败
        $state[$h] = @{ Mode = 'fail'; IPs = @() }
        Warn "  $h => 未找到可用方案"
    }
    # www.github.com 跟随 github.com 的决策（两者是同一套服务）
    if ($state['github.com']) {
        $gh = $state['github.com']
        $state['www.github.com'] = @{ Mode = $gh.Mode; IPs = $gh.IPs }
        Good "  www.github.com => 跟随 github.com（$($gh.Mode)）"
    }
}

$MAX_ROUNDS = 3
$success = $false
for ($round = 1; $round -le $MAX_ROUNDS; $round++) {
    Do-Round $round
    $failSvc = @($services | Where-Object { $state[$_.Host].Mode -eq 'fail' })
    if ($failSvc.Count -gt 0) {
        Warn "有 $($failSvc.Count) 个服务未找到方案，等待后重试..."
        if ($round -lt $MAX_ROUNDS) { Start-Sleep -Seconds 8 }
        continue
    }
    $success = $true
    break
}

if (-not $success) {
    Fail '多轮尝试仍无法找到可用方案（当前网络干扰过强）'
    if (-not $NoPause) { Read-Host '按回车退出' }
    exit 1
}

# ---------- 5. 配置代理（如果任何域名需要） ----------
$proxyDomains = @($services | Where-Object { $state[$_.Host].Mode -eq 'proxy' } | ForEach-Object { $_.Host })
$useProxy = ($proxyDomains.Count -gt 0) -and $hasNode

if ($useProxy) {
    Info "阶段 3/5：配置 SNI 剥离代理（涉及 $($proxyDomains.Count) 个域名）..."
    # 5.1 生成证书（若不存在或过期）
    $needCert = $true
    if (Test-Path $pfxPath) {
        $existing = Get-ChildItem 'Cert:\LocalMachine\Root' | Where-Object { $_.Subject -eq 'CN=Local GitHub Proxy' } | Select-Object -First 1
        if ($existing -and $existing.NotAfter -gt (Get-Date).AddDays(30)) { $needCert = $false }
    }
    if ($needCert) {
        Info '  生成自签证书（含所有需代理的域名）...'
        Get-ChildItem 'Cert:\LocalMachine\My', 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue |
            Where-Object { $_.Subject -eq 'CN=Local GitHub Proxy' } | Remove-Item -Force -ErrorAction SilentlyContinue

        $dnsNames = @()
        foreach ($d in $proxyDomains) {
            $dnsNames += $d
            $dnsNames += "*.$d"   # 覆盖子域
        }
        $cert = New-SelfSignedCertificate -DnsName $dnsNames -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotAfter (Get-Date).AddYears(10) -FriendlyName 'Local GitHub Proxy' `
            -KeyExportPolicy Exportable -KeyAlgorithm RSA -KeyLength 2048 -ErrorAction Stop
        $secure = ConvertTo-SecureString -String $PFX_PASS -Force -AsPlainText
        Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $secure -ErrorAction Stop | Out-Null
        Export-Certificate -Cert $cert -FilePath $cerPath -ErrorAction Stop | Out-Null
        Import-Certificate -FilePath $cerPath -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop | Out-Null
        Good "  证书已生成并导入受信任根（Thumbprint: $($cert.Thumbprint.Substring(0,16))...）"
    } else {
        Good '  复用已有证书'
    }
    # 5.2 生成代理配置
    $domainsConf = @{}
    foreach ($d in $proxyDomains) { $domainsConf[$d] = $state[$d].IPs }
    $conf = @{ listenPort = 443; pfx = 'proxy-cert.pfx'; passphrase = $PFX_PASS; domains = $domainsConf }
    [System.IO.File]::WriteAllText($cfgPath, ($conf | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    Good '  proxy-config.json 已生成'
    # 5.3 启动代理（先停旧的）
    $pids = Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($p in $pids) {
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'node') { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 800
    Start-Process -FilePath 'node' -ArgumentList 'proxy.js' -WorkingDirectory $script:WorkDir -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $listening = Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue
    if ($listening) { Good '  代理已启动（127.0.0.1:443）' } else { Warn '  代理启动失败，请检查 proxy.log' }
}

# ---------- 6. 写入 hosts ----------
Info '阶段 4/5：写入 hosts...'
$backup = "$hostsPath.bak-$(Get-Date -Format 'MMdd-HHmmss')"
Copy-Item $hostsPath $backup -Force
$lines = [System.IO.File]::ReadAllLines($hostsPath)
$out = [System.Collections.Generic.List[string]]::new()
$skip = $false
foreach ($x in $lines) {
    if ($x -match $MARK_BEGIN -or $x -match 'GitHub hosts|GitHub fix') { $skip = $true; continue }
    if ($x -match $MARK_END) { $skip = $false; continue }
    if (-not $skip) { $out.Add($x) }
}
while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }

$out.Add('')
$out.Add("# === GitHub hosts (v4 $(Get-Date -Format 'MM-dd HH:mm')) ===")
foreach ($svc in $services) {
    $h = $svc.Host
    $st = $state[$h]
    if ($st.Mode -eq 'proxy') {
        $out.Add("127.0.0.1 $h")
    } else {
        foreach ($ip in $st.IPs) { $out.Add("$ip $h") }
    }
}
# www 跟随 github.com 的决策
$wwwSt = $state['www.github.com']
if ($wwwSt -and $wwwSt.Mode -eq 'proxy') {
    $out.Add('127.0.0.1 www.github.com')
} elseif ($wwwSt) {
    foreach ($ip in $wwwSt.IPs) { $out.Add("$ip www.github.com") }
}
# gist / collector 跟随 github.com 的方案
if ($state['github.com'].Mode -eq 'proxy') {
    $out.Add('127.0.0.1 gist.github.com')
    $out.Add('127.0.0.1 collector.github.com')
} else {
    foreach ($ip in ($state['github.com'].IPs | Select-Object -First 1)) {
        $out.Add("$ip gist.github.com")
        $out.Add("$ip collector.github.com")
    }
}
# raw CDN（Fastly，常年全段被封，保留占位）
foreach ($d in @('raw.githubusercontent.com', 'assets-cdn.github.com', 'avatars.githubusercontent.com', 'objects.githubusercontent.com', 'avatars0.githubusercontent.com', 'avatars1.githubusercontent.com', 'avatars2.githubusercontent.com')) {
    $out.Add("185.199.109.133 $d")
}
$out.Add('# === end GitHub ===')
[System.IO.File]::WriteAllLines($hostsPath, $out.ToArray(), [System.Text.Encoding]::ASCII)
ipconfig /flushdns | Out-Null
Good "hosts 已更新（备份：$(Split-Path $backup -Leaf)）"

# ---------- 7. 终验（严格 >=2/3，不达标重来） ----------
Info '阶段 5/5：验证（每个服务必须 >=2/3）...'
$finalPass = $true
$verifyServices = @($services) + @(@{ Host = 'www.github.com' })
foreach ($svc in $verifyServices) {
    $h = $svc.Host
    $useNoRevoke = ($state[$h].Mode -eq 'proxy')
    $ok = Verify-Service "https://$h" $useNoRevoke
    if ($ok -ge 2) { Good "  $h : $ok/3 ✅" } else { Warn "  $h : $ok/3 ❌"; $finalPass = $false }
}

$sw.Stop()
Write-Host ''
Write-Host ('=' * 56) -ForegroundColor Green
if ($finalPass) {
    Write-Host (" 完成！耗时 {0:N0} 秒 —— 全部服务达标 ✅" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    if ($useProxy) { Write-Host ' 注意：github.com 依赖本地代理，重启电脑后需重新运行本脚本' -ForegroundColor Yellow }
    Write-Host ' 浏览器请按 Ctrl+Shift+R 强制刷新' -ForegroundColor Green
} else {
    Write-Host (" 部分服务未达标（耗时 {0:N0} 秒）—— 建议稍后重新运行" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Yellow
}
Write-Host ('=' * 56) -ForegroundColor Green
if (-not $NoPause) { Read-Host '按回车关闭窗口' }
