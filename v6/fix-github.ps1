# ============================================================
# GitHub 一键修复 v6 (Windows)
#
# 相比 v5：
#   * 每个域名可写入多个 IP（默认 5 个），代理内做健康度排序与故障转移
#   * 开机自启：注册计划任务，登录后自动拉起代理（v5 重启即失效）
#   * 证书私钥只保存在加密 PFX 中（随机口令 + DPAPI + 文件 ACL），
#     不再把私钥留在证书存储、不再使用硬编码口令 localproxy
#   * 上游证书严格校验（证书链 + 主机名），失败才降级并记安全警告
#   * 代理只服务 allowlist 域名，未知 Host 返回 403（不再是开放转发）
#   * 先验证代理真的能打开 GitHub，再改 hosts（避免把网搞断）
#   * 代理异常时自动回退到 v5 遗留代理，避免安装失败导致断网
#   * 支持 -DryRun 预览、-Doctor 自检
#
# 用法：
#   双击「快速修复GitHub.bat」
#   或：powershell -ExecutionPolicy Bypass -File fix-github.ps1
#
# 参数：
#   -IpsPerDomain N   每个域名保留的可用 IP 数（默认 5）
#   -MaxRounds N      验证不通过时最多重试轮数（0 = 无限，默认 3）
#   -ListenPort N     代理监听端口（默认 443，一般不用改）
#   -NoProxy          只写 hosts 直连，不装代理
#   -DryRun           只扫描并打印计划，不修改系统
#   -Doctor           只做体检并打印当前状态
#   -CleanLegacy      安装成功后删除 v5 遗留的证书/配置/口令文件
#   -ForceCert        强制重新生成证书
#   -NoPause          结束后不暂停（供自动化调用）
# ============================================================
param(
    [int]$IpsPerDomain = 5,
    [int]$MaxRounds = 3,
    [int]$ListenPort = 443,
    [switch]$NoProxy,
    [switch]$NoPause,
    [switch]$DryRun,
    [switch]$Doctor,
    [switch]$CleanLegacy,
    [switch]$ForceCert
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$script:ForwardArgs = @()
if ($IpsPerDomain -ne 5) { $script:ForwardArgs += @('-IpsPerDomain', "$IpsPerDomain") }
if ($MaxRounds -ne 3) { $script:ForwardArgs += @('-MaxRounds', "$MaxRounds") }
if ($ListenPort -ne 443) { $script:ForwardArgs += @('-ListenPort', "$ListenPort") }
if ($NoProxy) { $script:ForwardArgs += '-NoProxy' }
if ($NoPause) { $script:ForwardArgs += '-NoPause' }
if ($CleanLegacy) { $script:ForwardArgs += '-CleanLegacy' }
if ($ForceCert) { $script:ForwardArgs += '-ForceCert' }

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36'
$script:TcpLive = @()

function Show-Banner {
    Show-AccelIcon
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Cyan
    Write-Host ("  GitHub 加速器 v{0}  ·  多 IP + 开机自启 + 全程校验" -f $script:DshAccelVersion) -ForegroundColor White
    Write-Host ('=' * 62) -ForegroundColor Cyan
    if ($DryRun) { Warn 'DryRun 模式：只扫描并预览计划，不会修改 hosts / 证书 / 计划任务' }
}

# ---------------- IP 探测 ----------------
function Invoke-TcpScan {
    Info '  并行探测 GitHub 网段（约 10 秒）...'
    $pool = New-Object System.Collections.Generic.List[string]
    foreach ($s in @('20.205.243', '20.27.177', '20.201.28', '20.205.244', '20.27.178')) {
        foreach ($h in 140..180) { $pool.Add("$s.$h") }
    }
    foreach ($s in 112..127) { foreach ($h in 1..45) { $pool.Add("140.82.$s.$h") } }

    $live = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $pool.Count; $i += 160) {
        $end = [Math]::Min($i + 159, $pool.Count - 1)
        $conns = New-Object System.Collections.Generic.List[object]
        foreach ($ip in $pool[$i..$end]) {
            $c = New-Object System.Net.Sockets.TcpClient
            try { $null = $c.ConnectAsync($ip, 443); $conns.Add([pscustomobject]@{ IP = $ip; C = $c }) } catch { try { $c.Dispose() } catch {} }
        }
        Start-Sleep -Milliseconds 900
        foreach ($e in $conns) {
            try { if ($e.C.Connected) { $live.Add($e.IP) } } catch {}
            try { $e.C.Dispose() } catch {}
        }
    }
    return $live
}

function Get-TestPath {
    param([string]$Hostname)
    if ($Hostname -eq 'github.com' -or $Hostname -eq 'www.github.com') { return '/octocat' }
    return '/'
}

function Test-Ip {
    param([string]$Hostname, [string]$Ip, [string]$Mode)
    $path = Get-TestPath $Hostname
    $ok = 0
    $bad = 0
    for ($r = 1; $r -le 3; $r++) {
        if ($Mode -eq 'nosni') {
            $code = Get-HttpCode -Url "https://$Ip$path" -Insecure -MaxTime 5 -ConnectTimeout 2 `
                -Headers @{ 'Host' = $Hostname; 'User-Agent' = $UA }
        } else {
            $code = Get-HttpCode -Url "https://$Hostname$path" -ResolveHost $Hostname -ResolveIp $Ip -MaxTime 6 -ConnectTimeout 2
        }
        if ($code -eq '200' -or $code -eq '301' -or $code -eq '302') {
            $ok++
            if ($ok -ge 2) { return $true }
        } else {
            $bad++
            if ($bad -ge 2) { return $false }
        }
    }
    return $false
}

function Test-CertCoversHost {
    param([string[]]$Names, [string]$Hostname)
    foreach ($n in $Names) {
        if (-not $n) { continue }
        if ($n -eq $Hostname) { return $true }
        if ($n.StartsWith('*.')) {
            $suffix = $n.Substring(1)   # ".github.com"
            if ($Hostname.EndsWith($suffix) -and $Hostname.Length -gt $suffix.Length) { return $true }
        }
    }
    return $false
}

# 连到 IP 且「不发 SNI」，取回上游默认证书；用于确认该 IP 在无 SNI 时提供的证书能覆盖目标域名
function Get-NoSniCertProbe {
    param([string]$Ip, [int]$TimeoutMs = 5000)
    $tcp = $null; $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($Ip, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $null }
        $tcp.EndConnect($iar)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, { param($s, $c, $ch, $e) return $true })
        $ssl.ReadTimeout = $TimeoutMs
        $ssl.AuthenticateAsClient($Ip)     # 目标是 IP，.NET 不会发送 SNI
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $names = New-Object System.Collections.Generic.List[string]
        $cn = $cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        if ($cn) { $names.Add($cn) }
        foreach ($ext in $cert.Extensions) {
            if ($ext.Oid.Value -eq '2.5.29.17') {
                foreach ($m in [regex]::Matches($ext.Format($false), 'DNS\s*(?:Name)?\s*=\s*([^,]+)')) {
                    $n = $m.Groups[1].Value.Trim()
                    if ($n) { $names.Add($n) }
                }
            }
        }
        $chainOk = $false
        try {
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $chainOk = $chain.Build($cert)
        } catch {}
        return [pscustomobject]@{ Names = $names.ToArray(); ChainOk = $chainOk; Subject = $cert.Subject }
    } catch { return $null }
    finally {
        if ($ssl) { try { $ssl.Dispose() } catch {} }
        if ($tcp) { try { $tcp.Dispose() } catch {} }
    }
}

function Test-IpsNoSniBatch {
    param([string]$Hostname, [string[]]$Ips)
    if (-not $Ips -or $Ips.Count -eq 0) { return @() }
    $path = Get-TestPath $Hostname
    $a = @(
        '-s', '-o', 'NUL', '-w', '%{url_effective} %{http_code}\n',
        '--connect-timeout', '2', '--max-time', '6', '-k',
        '-Z', '--parallel-max', '16',
        '-H', "Host: $Hostname", '-H', "User-Agent: $UA"
    )
    foreach ($ip in $Ips) { $a += @('-o', 'NUL', "https://$ip$path") }
    $lines = @(& curl.exe @a 2>$null)
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^https://([0-9.]+)\S*\s+(\d{3})\s*$') {
            $ip = $Matches[1]
            $code = $Matches[2]
            if (($code -eq '200' -or $code -eq '301' -or $code -eq '302') -and -not $hits.Contains($ip)) {
                $hits.Add($ip)
            }
        }
    }
    return $hits.ToArray()
}

function Find-VerifiedIps {
    param([string]$Hostname, [string]$Mode, [int]$Want, [string[]]$Suffixes, [int]$MaxTest = 40)
    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($sfx in $Suffixes) {
        foreach ($ip in $script:TcpLive) {
            if ($ip -match "\.$sfx$" -and -not $ordered.Contains($ip)) { $ordered.Add($ip) }
        }
    }
    foreach ($ip in $script:TcpLive) { if (-not $ordered.Contains($ip)) { $ordered.Add($ip) } }

    $candidates = @($ordered | Select-Object -First $MaxTest)
    $found = New-Object System.Collections.Generic.List[string]

    if ($Mode -eq 'nosni') {
        # 批量并发探测（两轮确认，等价于 2/3 通过）
        $pass1 = @(Test-IpsNoSniBatch -Hostname $Hostname -Ips $candidates)
        if ($pass1.Count -eq 0) { return @() }
        $pass2 = @(Test-IpsNoSniBatch -Hostname $Hostname -Ips $pass1)
        $confirmed = New-Object System.Collections.Generic.List[string]
        foreach ($ip in $pass1) {
            if ($pass2 -contains $ip) { $confirmed.Add($ip) }
        }
        # 关键：无 SNI 时必须确认上游返回的证书真的覆盖目标域名，否则代理会退化成「不校验证书」
        $certOk = New-Object System.Collections.Generic.List[string]
        foreach ($ip in $confirmed) {
            $probe = Get-NoSniCertProbe -Ip $ip
            if ($probe -and $probe.ChainOk -and (Test-CertCoversHost -Names $probe.Names -Hostname $Hostname)) {
                $certOk.Add($ip)
                Write-Host ("      √ {0} -> {1}（证书覆盖 {0}，链有效）" -f $Hostname, $ip) -ForegroundColor DarkGray
            } else {
                $subj = ''
                if ($probe) { $subj = $probe.Subject }
                Write-Host ("      - {0} -> {1}（无 SNI 证书不匹配：{2}）" -f $Hostname, $ip, $subj) -ForegroundColor DarkGray
            }
        }
        if ($certOk.Count -gt 0) {
            $confirmed = $certOk
        } else {
            Warn ("  没有找到无 SNI 证书覆盖 {0} 的 IP，代理将退化为不校验证书（allowDegraded）" -f $Hostname)
        }
        foreach ($ip in $confirmed) {
            if ($found.Count -ge $Want) { break }
            $found.Add($ip)
            Write-Host "      + $Hostname -> $ip" -ForegroundColor DarkGray
        }
        return $found.ToArray()
    }

    $tested = 0
    foreach ($ip in $candidates) {
        if ($found.Count -ge $Want -or $tested -ge $MaxTest) { break }
        $tested++
        if (Test-Ip -Hostname $Hostname -Ip $ip -Mode $Mode) {
            $found.Add($ip)
            Write-Host "      + $Hostname -> $ip" -ForegroundColor DarkGray
        }
    }
    return $found.ToArray()
}

function Select-RawIp {
    foreach ($ip in $script:RawIpCandidates) {
        $code = Get-HttpCode -Url 'https://raw.githubusercontent.com/' -ResolveHost 'raw.githubusercontent.com' -ResolveIp $ip -MaxTime 8
        if ($code -eq '200' -or $code -eq '301' -or $code -eq '302') { return $ip }
    }
    return $script:RawIpCandidates[1]
}

# ---------------- 证书 ----------------
function Ensure-AccelCertificate {
    param([string]$Mode, [switch]$Force)

    $state = Read-JsonFile -Path $script:StatePath

    # 复用：状态里的指纹仍在受信任根、且 30 天内不过期、PFX 与口令都可用
    if (-not $Force -and $state -and $state.certThumbprint -and (Test-Path $script:PfxPath) -and (Test-Path $script:SecretPath)) {
        $rootCert = Get-ChildItem 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $state.certThumbprint } | Select-Object -First 1
        if ($rootCert -and $rootCert.NotAfter -gt (Get-Date).AddDays(30)) {
            try {
                $pass = Unprotect-SecretFile -Path $script:SecretPath
                $pfxCert = Get-PfxCertificateObject -Path $script:PfxPath -PlainPassword $pass
                if ($pfxCert.Thumbprint -eq $state.certThumbprint) {
                    Good "  复用已有证书 $($state.certThumbprint.Substring(0,16))…（有效期至 $($rootCert.NotAfter.ToString('yyyy-MM-dd'))）"
                    return [pscustomobject]@{ Thumbprint = $state.certThumbprint; Pass = $pass; Reused = $true }
                }
            } catch { Warn '  已有证书/口令不可用，将重新生成' }
        }
    }

    Info '  清理旧证书（含 v5 遗留的 CN=github.com）...'
    $null = Remove-AccelCerts -State $state

    Info '  生成新证书（RSA 3072 / SHA256 / 2 年 / CA:TRUE pathlength=0）...'
    $pass = New-RandomPassword -Length 40
    $dnsNames = @('github.com', 'www.github.com', 'gist.github.com', 'collector.github.com', '*.github.com')
    $cert = New-SelfSignedCertificate -DnsName $dnsNames -CertStoreLocation 'Cert:\LocalMachine\My' `
        -NotAfter (Get-Date).AddYears(2) -FriendlyName 'GitHub Accelerator v6 CA' `
        -KeyExportPolicy Exportable -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
        -TextExtension @('2.5.29.19={critical}{text}ca=1&pathlength=0') -ErrorAction Stop

    $secure = ConvertTo-SecureString -String $pass -AsPlainText -Force
    Export-PfxCertificate -Cert $cert -FilePath $script:PfxPath -Password $secure | Out-Null
    Export-Certificate -Cert $cert -FilePath $script:CerPath | Out-Null
    $null = Install-RootCertificate -CerPath $script:CerPath -StoreLocation 'LocalMachine' -StoreName 'Root'

    # 私钥只存在于受 ACL + DPAPI 保护的 PFX 中，不留在证书存储
    Remove-Item -Path "Cert:\LocalMachine\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue

    Protect-SecretFile -Path $script:SecretPath -Plain $pass
    Set-PrivateFileAcl -Path $script:PfxPath
    Set-PrivateFileAcl -Path $script:SecretPath

    $inRoot = Get-ChildItem 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $cert.Thumbprint } | Select-Object -First 1
    if (-not $inRoot) { throw '证书导入「受信任的根证书颁发机构」失败' }
    $inMy = Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $cert.Thumbprint } | Select-Object -First 1
    if ($inMy) { throw '私钥仍留在个人证书存储中，清理失败' }

    Good "  证书已就绪：$($cert.Thumbprint.Substring(0,16))…  有效期至 $($cert.NotAfter.ToString('yyyy-MM-dd'))"
    Good '  私钥仅保存在加密 PFX（随机口令 + DPAPI），文件 ACL 仅当前用户与 SYSTEM 可读'
    return [pscustomobject]@{ Thumbprint = $cert.Thumbprint; Pass = $pass; Reused = $false }
}

# ---------------- 配置 / 启动 ----------------
function Write-InstallState {
    param([string]$Mode, $CertInfo, [string[]]$GithubIps)
    $obj = [ordered]@{
        version        = 6
        installedAt    = (Get-Date).ToString('o')
        mode           = $Mode
        listenPort     = $ListenPort
        pfx            = 'proxy-cert.pfx'
        certThumbprint = $(if ($CertInfo) { $CertInfo.Thumbprint } else { '' })
        taskName       = $script:TaskName
        domains        = @{ 'github.com' = @($GithubIps) }
        ipsPerDomain   = $IpsPerDomain
    }
    ConvertTo-JsonFile -Path $script:StatePath -Object $obj -Depth 8
}

function Write-ProxyConfig {
    param([string[]]$GithubIps)
    $conf = [ordered]@{
        version         = 6
        listenPort      = $ListenPort
        listenHost      = '127.0.0.1'
        pfx             = 'proxy-cert.pfx'
        upstreamVerify  = 'strict'
        allowDegraded   = $true
        maxBufferBytes  = 1048576
        maxRewriteBytes = 4194304
        connectTimeoutMs = 12000
        raceTimeoutMs    = 4500
        raceConcurrency  = 4
        bodyTimeoutMs   = 180000
        logMaxBytes     = 2097152
        maxConnections  = 1024
        domains         = @{ 'github.com' = $GithubIps }
    }
    ConvertTo-JsonFile -Path $script:ConfigPath -Object $conf -Depth 8
    Good "  代理配置已写入（github.com：$($GithubIps.Count) 个 IP）"
}

function Start-ProxyViaTask {
    param([string]$NodeExe)
    $t = Get-AccelTask
    if ($t) {
        # 先确保旧实例已退出，否则 MultipleInstances=IgnoreNew 会忽略本次启动
        try { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Milliseconds 1000
        Start-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    } else {
        $env:GH_ACCEL_PFX_PASS = Unprotect-SecretFile -Path $script:SecretPath
        Start-Process -FilePath $NodeExe -ArgumentList '"proxy.js"' -WorkingDirectory $script:WorkDir -WindowStyle Hidden
    }
    for ($i = 0; $i -lt 40; $i++) {
        $h = Get-ProxyHealth -Port $ListenPort
        if ($h -and $h.ok) { return $true }
        Start-Sleep -Milliseconds 750
    }
    return $false
}

function Test-AllServices {
    $checks = @(
        @{ H = 'github.com'; P = '/octocat' },
        @{ H = 'www.github.com'; P = '/octocat' },
        @{ H = 'api.github.com'; P = '/' },
        @{ H = 'codeload.github.com'; P = '/' }
    )
    $allPass = $true
    foreach ($c in $checks) {
        $code = Get-HttpCode -Url ("https://{0}{1}" -f $c.H, $c.P) -MaxTime 25 -Headers @{ 'User-Agent' = $UA }
        if ($code -eq '200' -or $code -eq '301' -or $code -eq '302') {
            Good ("    {0,-24} {1}" -f $c.H, $code)
        } else {
            Warn ("    {0,-24} {1}" -f $c.H, $code)
            $allPass = $false
        }
    }
    return $allPass
}

# ---------------- 体检 ----------------
# 实现见 common.ps1 的 Show-Doctor（doctor.ps1 复用同一份）

# ============================ 主流程 ============================
Show-Banner

if ($Doctor) {
    Show-Doctor
    if (-not $NoPause) { Read-Host '按回车关闭窗口' }
    exit 0
}

if (-not (Test-Path -LiteralPath $script:ProxyJs)) {
    Fail "缺少 proxy.js（应位于 $($script:WorkDir)）"
    if (-not $NoPause) { Read-Host '按回车关闭窗口' }
    exit 1
}

if (-not $DryRun) {
    if (-not (Test-IsAdmin)) {
        Request-Elevation -ScriptPath $PSCommandPath -Arguments $script:ForwardArgs
        exit
    }
    Good '管理员权限确认'
}

$node = Find-Node
if (-not $node -and -not $DryRun) { $node = Install-Node }
if ($node) { Good "Node.js：$node" }
elseif (-not $NoProxy) {
    Warn 'Node.js 不可用：本次只能做 hosts 直连（无法处理 SNI 阻断）'
    $NoProxy = $true
}

try {
    $round = 0
    $success = $false
    $hostsWritten = $false
    $certInfo = $null
    $finalState = $null

    while ($true) {
        $round++
        if ($MaxRounds -gt 0 -and $round -gt $MaxRounds) { break }
        Write-Host ''
        Info ("==================== 第 {0} 轮 ====================" -f $round)

        # 1) 扫描
        $script:TcpLive = @(Invoke-TcpScan)
        if ($script:TcpLive.Count -eq 0) {
            Warn '  没有任何 GitHub IP 可达（网络可能中断）'
            if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) { break }
            Start-Sleep -Seconds 8
            continue
        }
        Good ("  TCP 443 可达：{0} 个 IP" -f $script:TcpLive.Count)

        # 2) 逐域名选 IP
        Info '  选择可用 IP（每域名多选备用）...'
        $state = @{}
        $proxyIps = @()
        $directIps = @()

        if (-not $NoProxy -and $node) {
            $proxyIps = @(Find-VerifiedIps -Hostname 'github.com' -Mode 'nosni' -Want $IpsPerDomain -Suffixes @('3', '4', '19', '20', '21', '22') -MaxTest 48)
        }
        # 无论是否用代理都扫一组直连 IP，作为代理失败时的回退
        $directIps = @(Find-VerifiedIps -Hostname 'github.com' -Mode 'sni' -Want ([Math]::Min(2, $IpsPerDomain)) -Suffixes @('3', '4', '19', '20', '21', '22') -MaxTest 10)

        if ($proxyIps.Count -ge 2) {
            $state['github.com'] = @{ Mode = 'proxy'; IPs = $proxyIps }
            Good ("  github.com => 本地代理（{0} 个 IP）" -f $proxyIps.Count)
        } elseif ($directIps.Count -ge 1) {
            $state['github.com'] = @{ Mode = 'direct'; IPs = $directIps }
            Good ("  github.com => 直连（{0} 个 IP）" -f $directIps.Count)
        } else {
            $state['github.com'] = @{ Mode = 'fail'; IPs = @() }
            Warn '  github.com => 未找到可用 IP'
        }

        $apiIps = @(Find-VerifiedIps -Hostname 'api.github.com' -Mode 'sni' -Want $IpsPerDomain -Suffixes @('5', '6') -MaxTest 14)
        $codeloadIps = @(Find-VerifiedIps -Hostname 'codeload.github.com' -Mode 'sni' -Want $IpsPerDomain -Suffixes @('9', '10') -MaxTest 14)
        $state['api.github.com'] = @{ Mode = 'direct'; IPs = $apiIps }
        $state['codeload.github.com'] = @{ Mode = 'direct'; IPs = $codeloadIps }
        Good ("  api.github.com => {0} 个 IP" -f $apiIps.Count)
        Good ("  codeload.github.com => {0} 个 IP" -f $codeloadIps.Count)

        if ($apiIps.Count -eq 0 -or $codeloadIps.Count -eq 0 -or $state['github.com'].Mode -eq 'fail') {
            Warn '  本轮 IP 选择不完整'
            if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) { break }
            Start-Sleep -Seconds 6
            continue
        }

        $rawIp = Select-RawIp
        $state['raw'] = @{ Mode = 'direct'; IPs = @($rawIp) }

        # 3) DryRun：只打印计划
        if ($DryRun) {
            Write-Host ''
            Info '===== DryRun 计划（不会修改任何系统设置）====='
            Info ("  证书：{0}" -f $(if ($state['github.com'].Mode -eq 'proxy') { '生成/复用受信任根证书，私钥只存于加密 PFX' } else { '直连模式，不需要证书' }))
            Info ("  代理：{0}" -f $(if ($state['github.com'].Mode -eq 'proxy') { "127.0.0.1:$ListenPort，仅服务 github.com（$($proxyIps.Count) 个 IP）" } else { '不启用' }))
            Info ("  开机自启：计划任务 {0}（登录后 20 秒启动，失败自动重启）" -f $script:TaskName)
            Info ("  api.github.com：{0}" -f ($apiIps -join ', '))
            Info ("  codeload.github.com：{0}" -f ($codeloadIps -join ', '))
            Info ("  raw.githubusercontent.com：{0}" -f $rawIp)
            $preview = New-Object System.Collections.Generic.List[string]
            if ($state['github.com'].Mode -eq 'proxy') {
                foreach ($h in $script:AccelDomains) { $preview.Add("127.0.0.1 $h") }
            } else {
                foreach ($h in $script:AccelDomains) { $preview.Add("$($directIps[0]) $h") }
            }
            foreach ($ip in $apiIps) { $preview.Add("$ip api.github.com") }
            foreach ($ip in $codeloadIps) { $preview.Add("$ip codeload.github.com") }
            foreach ($d in $script:RawDomains) { $preview.Add("$rawIp $d") }
            Set-GitHubHostsBlock -BlockLines $preview.ToArray() -DryRun
            Write-Host ''
            Good 'DryRun 完成：去掉 -DryRun 即可正式安装'
            $finalState = $state
            $success = $true
            break
        }

        # 4) 证书
        if ($state['github.com'].Mode -eq 'proxy') {
            Step 1 '准备证书（受信任根 + 加密私钥）'
            # 先停掉旧代理：避免它在旧证书被删除后继续用它对外提供 TLS（浏览器会短暂报证书错误）
            $null = Stop-AccelProxy -Port $ListenPort
            $certInfo = Ensure-AccelCertificate -Mode 'proxy' -Force:$ForceCert

            Step 2 '写入代理配置'
            Write-ProxyConfig -GithubIps $proxyIps
            Write-InstallState -Mode 'proxy' -CertInfo $certInfo -GithubIps $proxyIps
        }

        # 5) 计划任务 + 启动
        if ($state['github.com'].Mode -eq 'proxy') {
            Step 3 '配置开机自启'
            Register-AccelTask
        } else {
            Step 3 '直连模式：不启用代理/自启'
            $null = Stop-AccelProxy -Port $ListenPort
            if (Get-AccelTask) { $null = Unregister-AccelTask }
            Write-InstallState -Mode 'direct' -CertInfo $null -GithubIps $directIps
        }

        Step 4 '启动代理并验证（先验证，再改 hosts）'
        $ok = $false
        if ($state['github.com'].Mode -eq 'proxy') {
            $env:GH_ACCEL_PFX_PASS = $certInfo.Pass
            $ok = Start-ProxyViaTask -NodeExe $node
            if ($ok) {
                $probe = Test-ProxyServesGithub -Port $ListenPort
                if ($probe.Ok) {
                    Good ("  代理严格校验通过：HTTP {0}（证书受系统信任）" -f $probe.Status)
                } else {
                    Warn ("  代理严格校验失败：{0}" -f $probe.Error)
                    $ok = $false
                }
            } else {
                Warn '  代理没有在 30 秒内起来'
            }
        } else {
            $ok = $true
        }

        if (-not $ok) {
            Warn '  本轮启动失败，尝试恢复旧版代理以保持 GitHub 可用...'
            if (-not $NoProxy) {
                if (Start-LegacyProxy -NodeExe $node) { Good '  已恢复旧版代理（v5），GitHub 仍然可用' }
                else { Warn '  旧版代理也不可用，GitHub 可能暂时无法访问' }
            }
            if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) { break }
            Start-Sleep -Seconds 8
            continue
        }

        # 6) 写 hosts
        Step 5 '写入 hosts'
        $block = New-Object System.Collections.Generic.List[string]
        if ($state['github.com'].Mode -eq 'proxy') {
            foreach ($h in $script:AccelDomains) { $block.Add("127.0.0.1 $h") }
        } else {
            foreach ($h in $script:AccelDomains) { $block.Add("$($directIps[0]) $h") }
        }
        foreach ($ip in $apiIps) { $block.Add("$ip api.github.com") }
        foreach ($ip in $codeloadIps) { $block.Add("$ip codeload.github.com") }
        foreach ($d in $script:RawDomains) { $block.Add("$rawIp $d") }
        Set-GitHubHostsBlock -BlockLines $block.ToArray()
        $hostsWritten = $true

        # 7) 端到端验证
        Step 6 '端到端验证'
        if (Test-AllServices) {
            $success = $true
            $finalState = $state
            break
        }
        Warn '  有服务未达标'
        if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) { break }
        Start-Sleep -Seconds 6
    }

    # ---------------- 结果 ----------------
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor $(if ($success) { 'Green' } else { 'Yellow' })
    if ($success -and $finalState) {
        $mode = $finalState['github.com'].Mode
        if ($DryRun) { Good 'DryRun：安装计划预览完成（未修改系统）' }
        else { Good ("v6 安装完成（{0} 轮）" -f $round) }
        if ($mode -eq 'proxy') {
            Good ("  代理：https://127.0.0.1:{0}  仅服务 github.com" -f $ListenPort)
            Good ("  github.com 备用 IP：{0}" -f (($finalState['github.com'].IPs) -join ', '))
        }
        $task = Get-AccelTask
        if ($task) { Good "  开机自启：已启用（$($script:TaskName)）" }
        if ($hostsWritten) { Good '  hosts：已写入并验证通过' }
        Write-Host ''
        Info '提示：浏览器请按 Ctrl+Shift+R 强刷一次；GitHub Copilot / gh CLI 等客户端请完全退出后重开。'
        Info '回滚：双击「一键回滚.bat」，会删除证书（含 v5 的 CN=github.com）、计划任务与 hosts 配置。'
        if ($CleanLegacy -and $mode -eq 'proxy') {
            Info '正在清理 v5 遗留文件...'
            foreach ($d in (Get-LegacyDirs)) {
                foreach ($f in @('proxy-config.json', 'proxy-cert.pfx', 'proxy-cert.cer', 'proxy-pass.dat')) {
                    $p = Join-Path $d $f
                    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; Good "  已删除 $p" }
                }
            }
        } elseif ($mode -eq 'proxy') {
            $legacy = @(Get-LegacyDirs)
            if ($legacy.Count -gt 0) {
                Warn '检测到 v5 遗留文件（含口令为 localproxy 的根证书私钥），建议执行：'
                Write-Host ("      powershell -ExecutionPolicy Bypass -File `"{0}`" -CleanLegacy" -f $PSCommandPath) -ForegroundColor DarkGray
            }
        }
    } else {
        Warn '未能在限定轮次内完成安装'
        if ($hostsWritten) {
            Warn '  hosts 已改为指向本机，但端到端验证未通过；可运行「一键回滚.bat」恢复，或重新运行本脚本'
        } else {
            Warn '  hosts 未改动（保持原状），可稍后重试'
        }
    }
    Write-Host ('=' * 62) -ForegroundColor $(if ($success) { 'Green' } else { 'Yellow' })
    Write-Host ''
}
catch {
    Fail "安装失败：$($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    # 保底：如果代理已被停掉且端口空闲，尝试把 v5 遗留代理拉起来，保证 GitHub 可用
    if (-not (Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue)) {
        $nodeForFallback = Find-Node
        if ($nodeForFallback -and (Start-LegacyProxy -NodeExe $nodeForFallback)) {
            Warn '已尝试恢复旧版代理（v5），请确认 GitHub 是否可用'
        }
    }
    Warn '可运行「一键回滚.bat」清理，或把上面的错误发给我排查'
    exit 1
}
finally {
    Remove-Item Env:\GH_ACCEL_PFX_PASS -ErrorAction SilentlyContinue
}

if (-not $NoPause) { Read-Host '按回车关闭窗口' }
exit 0
