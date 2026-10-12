# ============================================================
# GitHub 快速修复 (Fast IP rotator)
#
# 特点：
#   - 全相对路径，整个文件夹可随意复制/移动到任何位置
#   - 自动请求管理员权限（无需手动右键）
#   - 并行扫描全 IP 段，约 60-120 秒完成（旧脚本要 10 分钟）
#
# 原理：GFW 对 GitHub 的 IP 封锁快速轮换，本脚本扫描所有
#      TCP 可达 IP，curl 验证后按服务写入 hosts。
#
# 用法：双击同目录的 "快速修复GitHub.bat"
#      或：powershell -ExecutionPolicy Bypass -File fix-github-fast.ps1
# ============================================================
param([switch]$NoPause)
$ErrorActionPreference = 'SilentlyContinue'

# ---------- 自动提权（用 $PSCommandPath，路径安全） ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[*] 正在请求管理员权限..." -ForegroundColor Cyan
    $argList = @('-ExecutionPolicy', 'Bypass', '-File', "$PSCommandPath")
    if ($NoPause) { $argList += '-NoPause' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Good($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[-] $m" -ForegroundColor Yellow }

Good "管理员权限确认"

# ---------- 1. 并行 TCP 探测 ----------
Info "阶段 1/4：并行 TCP 探测 GitHub IP 段（约 6 秒）..."
# 顺序很重要：亚洲段(Azure)优先 —— 实测 140.82.x 整段对 github.com 网页已被 SNI 阻断，
# 而亚洲段仍可用；api/codeload 则相反（140.82.x 的 .6/.9 尾号 IP 反而正常）。
$pool = [System.Collections.Generic.List[string]]::new()
foreach ($s in @('20.205.243', '20.27.177', '20.201.28', '20.205.244', '20.27.178')) {
    foreach ($h in 140..180) { $pool.Add("$s.$h") }
}
foreach ($s in 112..127) { foreach ($h in 1..45) { $pool.Add("140.82.$s.$h") } }
Info "候选池：$($pool.Count) 个 IP"

$tcpLive = [System.Collections.Generic.List[string]]::new()
$batch = 160
for ($i = 0; $i -lt $pool.Count; $i += $batch) {
    $end = [Math]::Min($i + $batch - 1, $pool.Count - 1)
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
if ($tcpLive.Count -eq 0) {
    Warn "没有 IP 可达，网络可能中断。"
    if (-not $NoPause) { Read-Host "按回车退出" }
    exit 1
}

# ---------- 2. 按服务验证 ----------
# 优先按尾号规律排序（.3/.4/.19/.20=网页, .6=api, .9=codeload）
function Get-Ordered($suffixes) {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($sfx in $suffixes) {
        foreach ($ip in $tcpLive) {
            if ($ip -match "\.$sfx$" -and -not $list.Contains($ip)) { $list.Add($ip) }
        }
    }
    foreach ($ip in $tcpLive) { if (-not $list.Contains($ip)) { $list.Add($ip) } }
    return $list
}

function Find-Alive($hostname, $want, $suffixes, $maxTest) {
    $found = [System.Collections.Generic.List[string]]::new()
    $tested = 0
    foreach ($ip in (Get-Ordered $suffixes)) {
        if ($found.Count -ge $want -or $tested -ge $maxTest) { break }
        $tested++
        $o = curl.exe -s -o NUL -w "%{http_code}" --resolve "$hostname`:443:$ip" --connect-timeout 1 --max-time 2 "https://$hostname" 2>$null
        if ($o -eq '200' -or $o -eq '301') { $found.Add($ip) }
    }
    return $found
}

Info "阶段 2/4：验证 github.com（目标 8 个）..."
$mainIPs = Find-Alive 'github.com' 8 @('3', '4', '19', '20', '21', '22') 70
if ($mainIPs.Count -eq 0) {
    Warn "暂未找到可用的 github.com IP（当前干扰较强）。"
    Warn "建议：稍等 1-2 分钟再运行一次，或使用代理。"
    if (-not $NoPause) { Read-Host "按回车退出" }
    exit 1
}
Good "github.com 可用：$($mainIPs -join ', ')"

Info "阶段 3/4：验证 www / api / codeload..."
$wwwIPs = Find-Alive 'www.github.com' 3 @('3', '4', '19') 30
$apiIPs = Find-Alive 'api.github.com' 3 @('6', '5') 30
$cdIPs = Find-Alive 'codeload.github.com' 3 @('9', '10') 30
if ($wwwIPs.Count -eq 0) { $wwwIPs = $mainIPs | Select-Object -First 2 }
if ($apiIPs.Count -eq 0) { $apiIPs = $mainIPs | Select-Object -First 2 }
if ($cdIPs.Count -eq 0) { $cdIPs = $mainIPs | Select-Object -First 2 }
Good "www: $($wwwIPs -join ',') | api: $($apiIPs -join ',') | codeload: $($cdIPs -join ',')"

# ---------- 3. 写入 hosts ----------
Info "阶段 4/4：写入 hosts..."
$backup = "$hostsPath.bak-$(Get-Date -Format 'MMdd-HHmmss')"
Copy-Item $hostsPath $backup -Force

$lines = [System.IO.File]::ReadAllLines($hostsPath)
$out = [System.Collections.Generic.List[string]]::new()
$skip = $false
foreach ($x in $lines) {
    if ($x -match 'GitHub hosts|GitHub fix') { $skip = $true; continue }
    if ($x -match 'end GitHub') { $skip = $false; continue }
    if (-not $skip) { $out.Add($x) }
}
while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }

$out.Add('')
$out.Add("# === GitHub hosts (fast-fix $(Get-Date -Format 'MM-dd HH:mm')) ===")
foreach ($ip in $mainIPs) { $out.Add("$ip github.com") }
foreach ($ip in $wwwIPs) { $out.Add("$ip www.github.com") }
foreach ($ip in $apiIPs) { $out.Add("$ip api.github.com") }
foreach ($ip in $cdIPs) { $out.Add("$ip codeload.github.com") }
$out.Add("$($mainIPs[0]) gist.github.com")
$out.Add("$($mainIPs[0]) collector.github.com")
foreach ($d in @('raw.githubusercontent.com', 'assets-cdn.github.com', 'avatars.githubusercontent.com', 'objects.githubusercontent.com', 'avatars0.githubusercontent.com', 'avatars1.githubusercontent.com', 'avatars2.githubusercontent.com')) {
    $out.Add("185.199.109.133 $d")
}
$out.Add('# === end GitHub ===')

[System.IO.File]::WriteAllLines($hostsPath, $out.ToArray(), [System.Text.Encoding]::ASCII)
ipconfig /flushdns | Out-Null
Good "hosts 已更新（备份：$(Split-Path $backup -Leaf)）"

# ---------- 4. 验证 ----------
Info "验证连通性..."
$pass = 0
foreach ($t in @(
        @{ N = 'github.com'; U = 'https://github.com' },
        @{ N = 'www'; U = 'https://www.github.com' },
        @{ N = 'api'; U = 'https://api.github.com' },
        @{ N = 'codeload'; U = 'https://codeload.github.com' })) {
    $ok = 0
    foreach ($i in 1..3) {
        $o = curl.exe -s -o NUL -w "%{http_code}" --connect-timeout 2 --max-time 5 $t.U 2>$null
        if ($o -eq '200' -or $o -eq '301') { $ok++ }
    }
    if ($ok -ge 2) { $pass++; Good "$($t.N): $ok/3" } else { Warn "$($t.N): $ok/3（波动，刷新重试即可）" }
}

$sw.Stop()
Write-Host ''
Write-Host ('=' * 52) -ForegroundColor Green
Write-Host (" 完成！耗时 {0:N0} 秒 | 服务可用 {1}/4" -f $sw.Elapsed.TotalSeconds, $pass) -ForegroundColor Green
Write-Host " 浏览器请按 Ctrl+F5 强制刷新" -ForegroundColor Green
Write-Host ('=' * 52) -ForegroundColor Green
if (-not $NoPause) { Read-Host "按回车关闭窗口" }
