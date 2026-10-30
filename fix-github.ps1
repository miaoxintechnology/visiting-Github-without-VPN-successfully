# ============================================================
# GitHub 一键修复 v5  (Windows)
#
# ★ 核心：不达标就自动重试，直到全部服务达标才结束 ★
#   每一轮都会重新扫描 IP、重新判断封锁类型、重新配置，
#   任何一轮全部达标就立即停止；否则自动进入下一轮。
#
# 自动判断每个域名属于哪种封锁，并采用对应方案：
#   ① DNS 污染 / IP 封锁  -> 换 IP 写入 hosts（直连）
#   ② SNI 阻断            -> 自动配置本地 SNI 剥离代理
#
# 验证标准：每个服务必须 >=2/3 通过（github.com 用深层路径验证）
#
# 用法：
#   双击同目录的「快速修复GitHub.bat」
#   或：powershell -ExecutionPolicy Bypass -File fix-github.ps1
#
# 参数：
#   -MaxRounds N   最多重试 N 轮（默认 0 = 无限重试直到达标）
#   -NoProxy       跳过代理方案，只做 hosts 直连
#   -NoPause       结束后不暂停（供自动化调用）
#
# 依赖：Windows 10/11、PowerShell 5.1+、curl.exe、Node.js（代理需要）
# ============================================================
param(
    [switch]$NoPause,
    [switch]$NoProxy,
    [int]$MaxRounds = 0
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
$script:TotalStart = Get-Date

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
    if ($MaxRounds -gt 0) { $a += @('-MaxRounds', "$MaxRounds") }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs
    exit
}
Good '管理员权限确认'

# ---------- 1. 环境检查 & Node.js 自动获取 ----------
# ★ 不要求用户预先安装 Node.js：没有就自动装（winget 或下载便携版 zip）
$hasProxyJs = Test-Path $proxyJs
if ($NoProxy) { $hasProxyJs = $false }

function Find-Node {
    $n = Get-Command node -ErrorAction SilentlyContinue
    if ($n) { return $n.Source }
    $nodeDir = Join-Path $script:WorkDir '.node'
    if (Test-Path $nodeDir) {
        $found = Get-ChildItem $nodeDir -Recurse -Filter 'node.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Install-Node {
    Info '未检测到 Node.js，正在自动安装（无需手动操作）...'

    # 方案 A: winget（Windows 10 1809+ 自带 App Installer）
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Info '  [1/3] 尝试 winget 安装 Node.js LTS...'
        & winget install OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $n = Find-Node
        if ($n) { Good "  winget 安装成功：$n"; return $n }
        Warn '  winget 未成功，改用便携版...'
    } else {
        Info '  [1/3] 系统无 winget，跳过'
    }

    # 方案 B: 下载便携版 zip（国内镜像优先，无需安装到系统）
    $nodeDir = Join-Path $script:WorkDir '.node'
    New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null
    $versions = @('v22.11.0', 'v20.18.0')
    $mirrors = @(
        'https://cdn.npmmirror.com/binaries/node/{0}/node-{0}-win-x64.zip',
        'https://npmmirror.com/mirrors/node/{0}/node-{0}-win-x64.zip',
        'https://nodejs.org/dist/{0}/node-{0}-win-x64.zip'
    )
    foreach ($ver in $versions) {
        foreach ($m in $mirrors) {
            $url = $m -f $ver
            $zip = Join-Path $env:TEMP "node-$ver.zip"
            Info "  [2/3] 下载便携版：$url"
            try {
                $oldProgress = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 180 -UseBasicParsing -ErrorAction Stop
                $ProgressPreference = $oldProgress
                if ((Get-Item $zip).Length -gt 10MB) {
                    Info '  [3/3] 解压中...'
                    Expand-Archive -Path $zip -DestinationPath $nodeDir -Force -ErrorAction Stop
                    $n = Find-Node
                    if ($n) { Good "  便携版已就绪：$n"; return $n }
                } else {
                    Warn '  文件异常（可能是错误页）'
                }
            } catch { Warn "  失败：$($_.Exception.Message)" }
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
        }
    }
    return $null
}

$script:NodeExe = $null
if ($hasProxyJs) {
    $script:NodeExe = Find-Node
    if (-not $script:NodeExe) { $script:NodeExe = Install-Node }
    if ($script:NodeExe) { Good "Node.js：$script:NodeExe" }
    else { Warn 'Node.js 不可用 —— 将只做 hosts 直连（无法处理 SNI 阻断）' }
} else {
    Info 'proxy.js 不在同目录，只做 hosts 直连'
}
$hasNode = ($null -ne $script:NodeExe)
if ($MaxRounds -eq 0) { Info '重试策略：不限轮次，直到全部达标才结束（Ctrl+C 可中止）' }
else { Info "重试策略：最多 $MaxRounds 轮" }

# ---------- 2. 服务定义 ----------
# www.github.com 跟随 github.com，不单独检测
$services = @(
    @{ Host = 'github.com'; Suffixes = @('3', '4', '19', '20', '21', '22'); MaxTest = 24 },
    @{ Host = 'api.github.com'; Suffixes = @('5', '6'); MaxTest = 16 },
    @{ Host = 'codeload.github.com'; Suffixes = @('9', '10'); MaxTest = 16 }
)

# ---------- 3. 工具函数 ----------
# github.com 必须测深层路径：只测根路径会选到「根路径200但深层404」的坏 IP
function Get-TestPath($hostname) {
    if ($hostname -eq 'github.com' -or $hostname -eq 'www.github.com') { return '/octocat' }
    return '/'
}

function Test-WithSNI($hostname, $ip) {
    $ok = 0; $bad = 0
    $path = Get-TestPath $hostname
    for ($r = 1; $r -le 3; $r++) {
        $o = curl.exe -s -o NUL -w '%{http_code}' --resolve "${hostname}:443:$ip" --connect-timeout 1 --max-time 2 "https://$hostname$path" 2>$null
        if ($o -eq '200' -or $o -eq '301') { $ok++; if ($ok -ge 2) { return $true } }
        else { $bad++; if ($bad -ge 2) { return $false } }
    }
    return ($ok -ge 2)
}

function Test-NoSNI($hostname, $ip) {
    $ok = 0; $bad = 0
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/132.0.0.0 Safari/537.36'
    $path = Get-TestPath $hostname
    for ($r = 1; $r -le 3; $r++) {
        $o = curl.exe -k -s -o NUL -w '%{http_code}' --connect-timeout 1 --max-time 2 "https://$ip$path" -H "Host: $hostname" -H "User-Agent: $ua" 2>$null
        if ($o -eq '200' -or $o -eq '301') { $ok++; if ($ok -ge 2) { return $true } }
        else { $bad++; if ($bad -ge 2) { return $false } }
    }
    return ($ok -ge 2)
}

function Order-Candidates($suffixes) {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($sfx in $suffixes) {
        foreach ($ip in $script:tcpLive) { if ($ip -match "\.$sfx$" -and -not $list.Contains($ip)) { $list.Add($ip) } }
    }
    foreach ($ip in $script:tcpLive) { if (-not $list.Contains($ip)) { $list.Add($ip) } }
    return $list
}

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

function Verify-Service($url, $useNoRevoke) {
    $extra = if ($useNoRevoke) { @('--ssl-no-revoke') } else { @() }
    $wait = if ($useNoRevoke) { 2 } else { 0 }
    $ok = 0; $bad = 0
    for ($r = 1; $r -le 3; $r++) {
        $o = & curl.exe @extra -s -o NUL -w '%{http_code}' --connect-timeout 5 --max-time 15 $url 2>$null
        if ($o -eq '200' -or $o -eq '301') { $ok++; if ($ok -ge 2) { return $ok } }
        else { $bad++; if ($bad -ge 2) { break } }
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
    }
    return $ok
}

# ---------- 4. 一轮：TCP 扫描 ----------
function Invoke-TcpScan {
    $pool = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @('20.205.243', '20.27.177', '20.201.28', '20.205.244', '20.27.178')) {
        foreach ($h in 140..180) { $pool.Add("$s.$h") }
    }
    foreach ($s in 112..127) { foreach ($h in 1..45) { $pool.Add("140.82.$s.$h") } }

    $live = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $pool.Count; $i += 160) {
        $end = [Math]::Min($i + 159, $pool.Count - 1)
        $conns = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($ip in $pool[$i..$end]) {
            $c = New-Object System.Net.Sockets.TcpClient
            try { $null = $c.ConnectAsync($ip, 443); $conns.Add(@{ IP = $ip; C = $c }) } catch { }
        }
        Start-Sleep -Milliseconds 850
        foreach ($e in $conns) {
            if ($e.C.Connected) { $live.Add($e.IP) }
            $e.C.Dispose()
        }
    }
    return $live
}

# ---------- 5. 一轮：逐域名决策 ----------
function Invoke-Decisions {
    $state = @{}
    foreach ($svc in $services) {
        $h = $svc.Host
        # github.com：SNI 时通时封，优先用代理（可靠优先）
        $preferProxy = $hasNode -and ($h -eq 'github.com')
        if ($preferProxy) {
            $nosni = Find-IPs $h 2 $svc.Suffixes 'nosni' $svc.MaxTest
            if ($nosni.Count -ge 2) {
                $state[$h] = @{ Mode = 'proxy'; IPs = $nosni }
                Good "  $h => 本地代理 ✅ $($nosni -join ', ')"
                continue
            }
        }
        $direct = Find-IPs $h 2 $svc.Suffixes 'sni' $svc.MaxTest
        if ($direct.Count -ge 2) {
            $state[$h] = @{ Mode = 'direct'; IPs = $direct }
            Good "  $h => 直连 ✅ $($direct -join ', ')"
            continue
        }
        if ($hasNode -and -not $preferProxy) {
            $nosni = Find-IPs $h 2 $svc.Suffixes 'nosni' $svc.MaxTest
            if ($nosni.Count -ge 2) {
                $state[$h] = @{ Mode = 'proxy'; IPs = $nosni }
                Good "  $h => SNI 阻断，本地代理 ✅ $($nosni -join ', ')"
                continue
            }
        }
        $state[$h] = @{ Mode = 'fail'; IPs = @() }
        Warn "  $h => 未找到可用方案"
    }
    # www 跟随 github.com
    if ($state['github.com']) {
        $state['www.github.com'] = @{ Mode = $state['github.com'].Mode; IPs = $state['github.com'].IPs }
        Good "  www.github.com => 跟随 github.com（$($state['github.com'].Mode)）"
    }
    return $state
}

# ---------- 6. 一轮：配置代理 ----------
function Invoke-ProxyConfig($state) {
    $proxyDomains = @($services | Where-Object { $state[$_.Host].Mode -eq 'proxy' } | ForEach-Object { $_.Host })
    if ($proxyDomains.Count -eq 0 -or -not $hasNode) { return }

    Info "  配置 SNI 剥离代理（$($proxyDomains.Count) 个域名）..."
    # 证书：必须带 Basic Constraints CA:TRUE，否则浏览器判定「服务器证书无效」
    $needCert = $true
    if (Test-Path $pfxPath) {
        $existing = Get-ChildItem 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Subject -match 'github\.com' } | Select-Object -First 1
        if ($existing) {
            $hasCa = $existing.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' }
            if ($hasCa -and $existing.NotAfter -gt (Get-Date).AddDays(30)) { $needCert = $false }
        }
    }
    if ($needCert) {
        # 彻底清理历史遗留的本地代理证书（多个同名证书会干扰浏览器信任判断）
        foreach ($storeName in @('Root', 'My')) {
            try {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
                $store.Open('ReadWrite')
                $toRemove = @($store.Certificates | Where-Object { $_.Subject -match 'github\.com|gravatar\.com|CN=Local' })
                foreach ($c in $toRemove) { try { $store.Remove($c) } catch { } }
                $store.Close()
            } catch { }
        }
        $dnsNames = @()
        foreach ($d in $proxyDomains) { $dnsNames += $d; $dnsNames += "*.$d" }
        $cert = New-SelfSignedCertificate -DnsName $dnsNames -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotAfter (Get-Date).AddYears(10) -FriendlyName 'Local GitHub Proxy' `
            -KeyExportPolicy Exportable -KeyAlgorithm RSA -KeyLength 2048 `
            -TextExtension @('2.5.29.19={critical}{text}ca=1&pathlength=0') -ErrorAction Stop
        $secure = ConvertTo-SecureString -String $PFX_PASS -Force -AsPlainText
        Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $secure -ErrorAction Stop | Out-Null
        Export-Certificate -Cert $cert -FilePath $cerPath -ErrorAction Stop | Out-Null
        Import-Certificate -FilePath $cerPath -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop | Out-Null
        Good '    证书已生成并导入受信任根'
    }
    # 配置 + 启动
    $domainsConf = @{}
    foreach ($d in $proxyDomains) { $domainsConf[$d] = $state[$d].IPs }
    $conf = @{ listenPort = 443; pfx = 'proxy-cert.pfx'; passphrase = $PFX_PASS; domains = $domainsConf }
    [System.IO.File]::WriteAllText($cfgPath, ($conf | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

    $pids = Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($p in $pids) {
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'node') { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 600
    Start-Process -FilePath $script:NodeExe -ArgumentList 'proxy.js' -WorkingDirectory $script:WorkDir -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if (Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue) { Good '    代理已启动 (127.0.0.1:443)' }
    else { Warn '    代理启动失败，检查 proxy.log' }
}

# ---------- 7. 一轮：写 hosts ----------
function Invoke-HostsWrite($state) {
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
    $out.Add("# === GitHub hosts (v5 $(Get-Date -Format 'MM-dd HH:mm')) ===")
    foreach ($svc in $services) {
        $h = $svc.Host
        if ($state[$h].Mode -eq 'proxy') { $out.Add("127.0.0.1 $h") }
        else { foreach ($ip in $state[$h].IPs) { $out.Add("$ip $h") } }
    }
    $wwwSt = $state['www.github.com']
    if ($wwwSt.Mode -eq 'proxy') { $out.Add('127.0.0.1 www.github.com') }
    elseif ($wwwSt) { foreach ($ip in $wwwSt.IPs) { $out.Add("$ip www.github.com") } }

    if ($state['github.com'].Mode -eq 'proxy') {
        $out.Add('127.0.0.1 gist.github.com')
        $out.Add('127.0.0.1 collector.github.com')
    } else {
        $firstIp = $state['github.com'].IPs | Select-Object -First 1
        $out.Add("$firstIp gist.github.com")
        $out.Add("$firstIp collector.github.com")
    }
    foreach ($d in @('raw.githubusercontent.com', 'assets-cdn.github.com', 'avatars.githubusercontent.com', 'objects.githubusercontent.com', 'avatars0.githubusercontent.com', 'avatars1.githubusercontent.com', 'avatars2.githubusercontent.com')) {
        $out.Add("185.199.109.133 $d")
    }
    $out.Add('# === end GitHub ===')
    [System.IO.File]::WriteAllLines($hostsPath, $out.ToArray(), [System.Text.Encoding]::ASCII)
    ipconfig /flushdns | Out-Null
    Good "    hosts 已更新（备份 $(Split-Path $backup -Leaf)）"
}

# ---------- 8. 一轮：验证 ----------
function Test-AllServices($state) {
    $allPass = $true
    $verifyHosts = @('github.com', 'www.github.com', 'api.github.com', 'codeload.github.com')
    foreach ($h in $verifyHosts) {
        $useNoRevoke = ($state[$h].Mode -eq 'proxy')
        $ok = Verify-Service "https://$h$(Get-TestPath $h)" $useNoRevoke
        if ($ok -ge 2) { Good "    $h : $ok/3 ✅" }
        else { Warn "    $h : $ok/3 ❌"; $allPass = $false }
    }
    return $allPass
}

# ---------- 9. 主循环：不达标就一直重试 ----------
$round = 0
$success = $false
while ($true) {
    $round++
    if ($MaxRounds -gt 0 -and $round -gt $MaxRounds) { break }

    $roundStart = Get-Date
    Write-Host ''
    if ($round -eq 1) { Info '==================== 开始修复 ====================' }
    else { Info "==================== 第 $round 轮（自动重试） ====================" }

    # 9.1 重新扫描 TCP（IP 会随时间变化，每轮都重扫）
    Info '  并行探测 IP 段...'
    $script:tcpLive = Invoke-TcpScan
    if ($script:tcpLive.Count -eq 0) {
        Warn '  没有 IP 可达（网络可能中断）'
    } else {
        Good "  TCP 443 可达：$($script:tcpLive.Count) 个 IP"
    }

    # 9.2 决策
    if ($script:tcpLive.Count -gt 0) {
        $state = Invoke-Decisions
    } else {
        $state = @{}
    }

    # 9.3 检查是否有域名找不到方案
    $failSvc = @($services | Where-Object { -not $state[$_.Host] -or $state[$_.Host].Mode -eq 'fail' })

    if ($failSvc.Count -gt 0) {
        Warn "  未找到方案：$(($failSvc | ForEach-Object { $_.Host }) -join ', ')"
    } else {
        # 9.4 应用配置
        Invoke-ProxyConfig $state
        Invoke-HostsWrite $state

        # 9.5 验证
        Info '  验证（每服务需 >=2/3）...'
        if (Test-AllServices $state) {
            $success = $true
            break
        }
        Warn '  有服务未达标'
    }

    # 9.6 是否继续
    if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) { break }
    $elapsed = [math]::Round(((Get-Date) - $roundStart).TotalSeconds)
    $wait = 10
    Warn "  本轮耗时 ${elapsed}s，${wait} 秒后自动重试（Ctrl+C 可中止，已进行 $round 轮）"
    Start-Sleep -Seconds $wait
}

# ---------- 10. 结果 ----------
$total = [math]::Round(((Get-Date) - $script:TotalStart).TotalSeconds)
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor $(if ($success) { 'Green' } else { 'Yellow' })
if ($success) {
    Write-Host " 修复成功！共 $round 轮，总耗时 $total 秒" -ForegroundColor Green
    Write-Host ' 全部服务已达标 ✅' -ForegroundColor Green
    $needProxy = @($services | Where-Object { $state[$_.Host].Mode -eq 'proxy' }).Count -gt 0
    if ($needProxy) { Write-Host ' 注意：github.com 依赖本地代理，重启电脑后需重新运行本脚本' -ForegroundColor Yellow }
    Write-Host ' 浏览器请按 Ctrl+Shift+R 强制刷新' -ForegroundColor Green
} else {
    Write-Host " 已达最大轮次限制（$round 轮），仍未全部达标" -ForegroundColor Yellow
    Write-Host ' 可重新运行本脚本，或去掉 -MaxRounds 参数让它无限重试' -ForegroundColor Yellow
}
Write-Host ('=' * 60) -ForegroundColor $(if ($success) { 'Green' } else { 'Yellow' })
if (-not $NoPause) { Read-Host '按回车关闭窗口' }
