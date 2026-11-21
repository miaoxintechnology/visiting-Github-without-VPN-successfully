# ============================================================
# GitHub 加速器 v6 · 公共库（由各脚本 dot-source 引入）
# 兼容 Windows PowerShell 5.1
# ============================================================

$script:DshAccelVersion = '6.1.0'

# ---------------- 启动图标 ----------------
$script:AccelIcon = @'
                      .-+*##@@@@@@@@##*+-.
                 .=*#@@@@@@@@@@@@@@@@@@@@@@#*=.
              -*@@@@@#*=:.            .:=*#@@@@@*-
           :*@@@@#+:                        :+#@@@@*:
         -#@@@#=                                =#@@@#-
       :#@@@#:      =**=                =**=      :#@@@#:
      *@@@#.      .#@@@@#.            .#@@@@#.      .#@@@*
    .#@@#-       :#@@##@@#:          :#@@##@@#:       -#@@#.
   :#@@#        =@@@#  #@@@=        =@@@#  #@@@=        #@@#:
  .#@@#        +@@@*    *@@@+      +@@@*    *@@@+        #@@#.
  #@@#        +@@@+      +@@@#=..=#@@@+      +@@@+        #@@#
 *@@#.       :@@@*         *@@@@@@@@*         *@@@:       .#@@*
.@@@*        #@@#            :=++=:            #@@#        *@@@.
*@@@.       :@@@=                              =@@@:       .@@@*
#@@#        *@@@                                @@@*        #@@#
@@@#        #@@#                                #@@#        #@@@
#@@#  :+=-: #@@#       #@#            #@#       #@@# :-=+:  #@@#
#@@#   .:-++#@@#       -+:            :+-       #@@#++-:.   #@@#
+@@@.  .::--#@@@                                @@@#--::.  .@@@+
 #@@# :+=---=@@@=          .#*    *#.          =@@@=---=+: #@@#
 +@@@-    :-+#@@#           #@@@@@@#           #@@#+-:    -@@@+
  #@@# .#*+-.:@@@*            .--.            *@@@:.-+*#. #@@#
   #@@#.      =@@@+                          +@@@=      .#@@#
    #@@#-      +@@@#                        #@@@+      -#@@#
     #@@@*      -@@@#                      #@@@-      *@@@#
      =#@@#=     #@@#                      #@@#     =#@@#=
        *@@@#=   #@@#                      #@@#   =#@@@*
          +@@@@#-#@@#   +*=#-      -#=*+   #@@#-#@@@@+
            -#@@@@@@# ##*=-+*#*  *#*+-=*## #@@@@@@#-
               =#@@@*  --. :--    --: .--  *@@@#=
                  ..   =@@@@@.    .@@@@@=   ..
                        +#@#-      -#@#+
'@

# 执行前打印图标（设置环境变量 GH_ACCEL_NO_ICON=1 可关闭，便于自动化解析输出）
function Show-AccelIcon {
    param([string]$Color = 'DarkCyan')
    if ($env:GH_ACCEL_NO_ICON -eq '1') { return }
    foreach ($line in ($script:AccelIcon -split "\r?\n")) {
        Write-Host $line -ForegroundColor $Color
    }
    Write-Host ''
}
$script:WorkDir = $PSScriptRoot
if (-not $script:WorkDir) { $script:WorkDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:TaskName = 'GitHubAcceleratorV6'
$script:StatePath = Join-Path $script:WorkDir 'install-state.json'
$script:ConfigPath = Join-Path $script:WorkDir 'proxy-config.json'
$script:PfxPath = Join-Path $script:WorkDir 'proxy-cert.pfx'
$script:CerPath = Join-Path $script:WorkDir 'proxy-cert.cer'
$script:SecretPath = Join-Path $script:WorkDir 'proxy-pass.dat'
$script:ProxyJs = Join-Path $script:WorkDir 'proxy.js'
$script:LogsDir = Join-Path $script:WorkDir 'logs'
$script:RunProxy = Join-Path $script:WorkDir 'run-proxy.ps1'
$script:HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$script:DefaultPort = 443
$script:HostsMarkBegin = '# === GitHub hosts v6'
$script:HostsMarkEnd = '# === end GitHub ==='
$script:AccelDomains = @('github.com', 'www.github.com', 'gist.github.com', 'collector.github.com')
$script:RawDomains = @(
    'raw.githubusercontent.com', 'assets-cdn.github.com', 'avatars.githubusercontent.com',
    'objects.githubusercontent.com', 'avatars0.githubusercontent.com',
    'avatars1.githubusercontent.com', 'avatars2.githubusercontent.com'
)
$script:RawIpCandidates = @('185.199.108.133', '185.199.109.133', '185.199.110.133', '185.199.111.133')

# ---------------- 输出 ----------------
function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Good($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[-] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[x] $m" -ForegroundColor Red }
function Step($n, $m) { Write-Host "[$n] $m" -ForegroundColor White }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    param([string]$ScriptPath, [string[]]$Arguments)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"") + $Arguments
    Write-Host '[*] 需要管理员权限（修改 hosts / 安装证书 / 注册开机自启），正在请求...' -ForegroundColor Cyan
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
}

# 以管理员运行，若未提权则退出
function Assert-AdminOrExit {
    if (-not (Test-IsAdmin)) {
        Request-Elevation -ScriptPath $PSCommandPath -Arguments $script:ForwardArgs
        exit
    }
    Good '管理员权限确认'
}

# ---------------- 文件 / JSON ----------------
function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        return ($text | ConvertFrom-Json)
    } catch { return $null }
}

function Write-TextFileAtomic {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $Text, $utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function ConvertTo-JsonFile {
    param([string]$Path, $Object, [int]$Depth = 8)
    $json = $Object | ConvertTo-Json -Depth $Depth
    Write-TextFileAtomic -Path $Path -Text $json
}

function New-RandomPassword {
    param([int]$Length = 40)
    $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($chars[$b % $chars.Length]) }
    return $sb.ToString()
}

# DPAPI：只有当前用户 + 本机才能解密
function Protect-SecretFile {
    param([string]$Path, [string]$Plain)
    $secure = ConvertTo-SecureString -String $Plain -AsPlainText -Force
    $cipher = ConvertFrom-SecureString -SecureString $secure
    Write-TextFileAtomic -Path $Path -Text $cipher
}

function Unprotect-SecretFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "缺少口令文件：$Path" }
    $cipher = [System.IO.File]::ReadAllText($Path).Trim()
    $secure = ConvertTo-SecureString -String $cipher
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# 只允许当前用户与 SYSTEM 读取（去掉继承，防止其他账户/程序读取私钥与口令）
function Set-PrivateFileAcl {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $Path /inheritance:r /grant:r "*${sid}:(R)" "*S-1-5-18:(R)" 2>&1 | Out-Null
}

# ---------------- 网络探测 ----------------
function Invoke-Curl {
    param([string[]]$Arguments, [int]$TimeoutSec = 40)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & curl.exe @Arguments 2>$null
        return ("$out" -replace '\s+$', '')
    } finally { $ErrorActionPreference = $prev }
}

# 返回 HTTP 状态码字符串（失败返回 000）
function Get-HttpCode {
    param(
        [string]$Url,
        [string]$ResolveHost = $null,
        [string]$ResolveIp = $null,
        [switch]$Insecure,
        [int]$MaxTime = 15,
        [int]$ConnectTimeout = 4,
        [hashtable]$Headers = @{},
        [switch]$NoRevoke
    )
    $a = @('-s', '-o', 'NUL', '-w', '%{http_code}', '--connect-timeout', "$ConnectTimeout", '--max-time', "$MaxTime")
    if (-not $NoRevoke) { $a += '--ssl-no-revoke' }
    if ($Insecure) { $a += '-k' }
    if ($ResolveHost -and $ResolveIp) { $a += @('--resolve', "${ResolveHost}:443:$ResolveIp") }
    foreach ($k in $Headers.Keys) { $a += @('-H', "$k`: $($Headers[$k])") }
    $a += $Url
    $code = Invoke-Curl -Arguments $a
    if ($code -match '^\d{3}$') { return $code }
    return '000'
}

function Test-TcpPort {
    param([string]$Ip, [int]$Port = 443, [int]$TimeoutMs = 1200)
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($Ip, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($iar)
        return $true
    } catch { return $false }
    finally { if ($c) { $c.Dispose() } }
}

# 严格 TLS + 真实 HTTP 请求，验证「本机代理 → GitHub」整条链路（会校验证书）
function Test-ProxyServesGithub {
    param([int]$Port = 443, [string]$Path = '/octocat', [int]$TimeoutMs = 20000)
    $tcp = $null; $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(4000)) { throw '连接 127.0.0.1 超时' }
        $tcp.EndConnect($iar)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false)
        $ssl.ReadTimeout = $TimeoutMs
        $ssl.WriteTimeout = $TimeoutMs
        $ssl.AuthenticateAsClient('github.com')   # 默认校验：证书链 + 主机名
        $req = "GET $Path HTTP/1.1`r`nHost: github.com`r`nUser-Agent: gh-accel-v6-verify`r`nAccept: */*`r`nConnection: close`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $ssl.Write($bytes, 0, $bytes.Length)
        $ssl.Flush()
        $reader = New-Object System.IO.StreamReader($ssl, [System.Text.Encoding]::ASCII)
        $statusLine = $reader.ReadLine()
        if ($statusLine -match '^HTTP/\d\.\d\s+(\d{3})') {
            return [pscustomobject]@{ Ok = ($Matches[1] -eq '200'); Status = [int]$Matches[1]; Error = $null; Subject = $ssl.RemoteCertificate.Subject }
        }
        return [pscustomobject]@{ Ok = $false; Status = 0; Error = "无法解析响应：$statusLine" }
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Error = $_.Exception.GetBaseException().Message }
    } finally {
        if ($ssl) { try { $ssl.Dispose() } catch {} }
        if ($tcp) { try { $tcp.Dispose() } catch {} }
    }
}

function Get-ProxyHealth {
    param([int]$Port = 443)
    $json = Invoke-Curl -Arguments @('-k', '-s', '--max-time', '5', "https://127.0.0.1:$Port/__gh_accel/health", '-H', 'Host: 127.0.0.1')
    if (-not $json) { return $null }
    try { return ($json | ConvertFrom-Json) } catch { return $null }
}

# ---------------- 进程 / 代理 ----------------
function Get-PortListener {
    param([int]$Port = 443)
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return $null }
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.OwningProcess)" -ErrorAction SilentlyContinue
    $pname = ''
    $pcmd = ''
    if ($p) { $pname = "$($p.Name)"; $pcmd = "$($p.CommandLine)" }
    return [pscustomobject]@{
        PID = $c.OwningProcess
        Name = $pname
        CommandLine = $pcmd
        LocalAddress = $c.LocalAddress
    }
}

# 停掉本工具（含 v5 遗留）的 proxy.js 进程
function Stop-AccelProxy {
    param([int]$Port = 443, [switch]$Quiet)
    $stopped = 0
    $listener = Get-PortListener -Port $Port
    if ($listener -and $listener.CommandLine -like '*proxy.js*') {
        Stop-Process -Id $listener.PID -Force -ErrorAction SilentlyContinue
        $stopped++
        if (-not $Quiet) { Good "  已停止占用 $Port 端口的代理 (PID $($listener.PID))" }
    }
    $all = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $all) {
        if ($p.CommandLine -like '*proxy.js*' -and $p.ProcessId -ne $listener.PID) {
            try {
                $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
                if ($proc) {
                    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                    $stopped++
                    if (-not $Quiet) { Good "  已停止遗留代理 (PID $($p.ProcessId))" }
                }
            } catch {}
        }
    }
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
    return $stopped
}

# ---------------- Node.js ----------------
function Find-Node {
    $c = Get-Command node -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($root) {
            $candidates.Add((Join-Path $root 'nodejs\node.exe'))
            $candidates.Add((Join-Path $root 'Programs\nodejs\node.exe'))
        }
    }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $nodeDir = Join-Path $script:WorkDir '.node'
    if (Test-Path -LiteralPath $nodeDir) {
        $found = Get-ChildItem -LiteralPath $nodeDir -Recurse -Filter 'node.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Test-NodeSignature {
    param([string]$Path)
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        return ($sig.Status -eq 'Valid' -and "$($sig.SignerCertificate.Subject)" -match 'OpenJS|Node\.js')
    } catch { return $false }
}

function Install-Node {
    Info '未检测到 Node.js，正在自动获取（无需手动操作）...'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Info '  [1/3] winget 安装 Node.js LTS...'
        & winget install OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $n = Find-Node
        if ($n) { Good "  winget 安装成功：$n"; return $n }
        Warn '  winget 未成功，改用便携版...'
    } else {
        Info '  [1/3] 系统无 winget，跳过'
    }

    $nodeDir = Join-Path $script:WorkDir '.node'
    New-Item -ItemType Directory -Force -Path $nodeDir | Out-Null
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
                $old = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 180 -UseBasicParsing -ErrorAction Stop
                $ProgressPreference = $old
                if ((Get-Item -LiteralPath $zip).Length -gt 10MB) {
                    Info '  [3/3] 解压并校验数字签名...'
                    Expand-Archive -LiteralPath $zip -DestinationPath $nodeDir -Force -ErrorAction Stop
                    $n = Find-Node
                    if ($n) {
                        if (Test-NodeSignature $n) { Good '  便携版已就绪（签名有效）' }
                        else { Warn '  便携版已就绪，但数字签名校验未通过，请自行确认来源' }
                        return $n
                    }
                } else {
                    Warn '  文件异常（可能是错误页），换下一个源'
                }
            } catch { Warn "  失败：$($_.Exception.Message)" }
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }
    }
    return $null
}

# ---------------- 证书 ----------------
# 找出「本工具」可能装过的证书（v5 的 CN=github.com / 旧 FriendlyName / 状态文件记录的指纹）
function Get-AccelCertCandidates {
    param($State)
    $thumbprints = @()
    if ($State -and $State.certThumbprint) { $thumbprints += $State.certThumbprint }
    $legacySubjects = @(
        'CN=github.com', 'CN=Local GitHub Proxy', 'CN=Local SNI Proxy', 'CN=Local Proxy'
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($storeName in @('Root', 'My')) {
        $storePath = "Cert:\LocalMachine\$storeName"
        $certs = Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue
        foreach ($c in $certs) {
            $reason = $null
            if ($thumbprints -contains $c.Thumbprint) { $reason = 'install-state 记录' }
            elseif ($c.FriendlyName -match '^(Local GitHub Proxy|GitHub Accelerator v6)') { $reason = 'FriendlyName 匹配' }
            elseif ($legacySubjects -contains $c.Subject -and $c.Subject -eq $c.Issuer) { $reason = '自签 github.com 证书' }
            if ($reason) {
                $result.Add([pscustomobject]@{ Store = $storeName; Cert = $c; Reason = $reason })
            }
        }
    }
    return $result
}

# 把 .cer 装进根存储（用 .NET API，不弹任何 UI 对话框；Import-Certificate 在部分环境会弹安全警告）
function Install-RootCertificate {
    param(
        [string]$CerPath,
        [string]$StoreLocation = 'LocalMachine',
        [string]$StoreName = 'Root'
    )
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CerPath)
    $loc = [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    if ($StoreLocation -eq 'CurrentUser') { $loc = [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser }
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($StoreName, $loc)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try { $store.Add($cert) } finally { $store.Close() }
    return $cert
}

# 读取带口令的 PFX（Windows PowerShell 5.1 的 Get-PfxCertificate 没有 -Password 参数）
function Get-PfxCertificateObject {
    param([string]$Path, [string]$PlainPassword)
    $secure = ConvertTo-SecureString -String $PlainPassword -AsPlainText -Force
    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
    return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Path, $secure, $flags)
}

function Remove-AccelCerts {
    param($State, [switch]$DryRun, [switch]$Quiet)
    $removed = 0
    $candidates = Get-AccelCertCandidates -State $State
    foreach ($item in $candidates) {
        $c = $item.Cert
        if ($DryRun) {
            Info ("  将删除证书 [{0}] {1} ({2}) 原因：{3}" -f $item.Store, $c.Thumbprint.Substring(0, 16), $c.Subject, $item.Reason)
        } else {
            $ok = $false
            try {
                # 用 .NET API 删除：比 Cert: 提供程序更可靠，且不触发任何确认对话框
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($item.Store, [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
                $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                try { $store.Remove($c); $ok = $true } finally { $store.Close() }
            } catch { $ok = $false }
            if (-not $ok) {
                try { Remove-Item -Path $c.PSPath -Force -ErrorAction Stop; $ok = $true } catch {}
            }
            if ($ok) {
                $removed++
                if (-not $Quiet) { Good ("  已删除证书 [{0}] {1}…  {2}" -f $item.Store, $c.Thumbprint.Substring(0, 16), $c.Subject) }
            } else {
                Warn ("  删除证书失败 [{0}] {1}（可用 certlm.msc 手动删除）" -f $item.Store, $c.Thumbprint.Substring(0, 12))
            }
        }
    }
    return $removed
}

# ---------------- hosts ----------------
function Read-HostsLines {
    return @([System.IO.File]::ReadAllLines($script:HostsPath))
}

function Get-HostsBackup {
    $backup = "$($script:HostsPath).bak-v6-$(Get-Date -Format 'MMdd-HHmmss')"
    Copy-Item -LiteralPath $script:HostsPath -Destination $backup -Force
    return $backup
}

# 去掉本工具（v5/v6）写入的整段 GitHub 配置
function Remove-GitHubHostsSection {
    param([string[]]$Lines)
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($x in $Lines) {
        if ($x -match '^\s*#\s*=+\s*GitHub\s+(hosts|fix)|auto-fixed by fix-github') { $skip = $true; continue }
        if ($x -match '^\s*#\s*=+\s*end\s+GitHub') { $skip = $false; continue }
        if ($skip) { continue }
        $out.Add($x)
    }
    while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
    return $out.ToArray()
}

function Set-GitHubHostsBlock {
    param([string[]]$BlockLines, [switch]$DryRun)
    $lines = Read-HostsLines
    $clean = @(Remove-GitHubHostsSection -Lines $lines)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($x in $clean) { $out.Add($x) }
    $out.Add('')
    $out.Add("$($script:HostsMarkBegin) ($(Get-Date -Format 'yyyy-MM-dd HH:mm')) ===")
    foreach ($x in $BlockLines) { $out.Add($x) }
    $out.Add($script:HostsMarkEnd)
    if ($DryRun) {
        Info '  hosts 将写入以下内容（DryRun 不落盘）：'
        $out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        return
    }
    $backup = Get-HostsBackup
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $tmp = "$($script:HostsPath).tmp-v6"
    [System.IO.File]::WriteAllLines($tmp, $out.ToArray(), $utf8)
    Move-Item -LiteralPath $tmp -Destination $script:HostsPath -Force
    ipconfig /flushdns 2>&1 | Out-Null
    Good "  hosts 已更新（备份：$(Split-Path -Leaf $backup)）"
}

function Get-GitHubHostsLines {
    $lines = Read-HostsLines
    return @($lines | Where-Object { $_ -match 'github' })
}

# ---------------- 开机自启（计划任务） ----------------
function Get-AccelTask {
    return Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
}

function Register-AccelTask {
    param([switch]$DryRun)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($script:RunProxy)`"" `
        -WorkingDirectory $script:WorkDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
    try { $trigger.Delay = 'PT20S' } catch {}
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited

    if ($DryRun) {
        Info ("  将注册计划任务 {0}（登录时启动，延迟 20 秒，失败重试 5 次）" -f $script:TaskName)
        Info ("  命令：powershell.exe -File `"{0}`"" -f $script:RunProxy)
        return
    }
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description 'GitHub 加速器 v6：开机自动启动本地代理' -Force | Out-Null
    Good "  已注册开机自启：计划任务 $($script:TaskName)"
}

function Unregister-AccelTask {
    param([switch]$DryRun)
    $t = Get-AccelTask
    if (-not $t) { return $false }
    if ($DryRun) { Info "  将删除计划任务 $($script:TaskName)"; return $true }
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Good "  已删除计划任务 $($script:TaskName)"
    return $true
}

# ---------------- 兼容旧版 v5 清理 ----------------
function Get-LegacyDirs {
    $dirs = @()
    $parent = Split-Path -Parent $script:WorkDir
    foreach ($d in @($parent, (Join-Path $parent 'v5'), (Join-Path $env:USERPROFILE 'Desktop'))) {
        if ($d -and (Test-Path (Join-Path $d 'proxy.js')) -and $d -ne $script:WorkDir) { $dirs += $d }
    }
    return ($dirs | Select-Object -Unique)
}

function Start-LegacyProxy {
    param([string]$NodeExe)
    foreach ($d in (Get-LegacyDirs)) {
        $js = Join-Path $d 'proxy.js'
        $cfg = Join-Path $d 'proxy-config.json'
        if ((Test-Path $js) -and (Test-Path $cfg)) {
            Start-Process -FilePath $NodeExe -ArgumentList 'proxy.js' -WorkingDirectory $d -WindowStyle Hidden
            Start-Sleep -Seconds 2
            if (Get-PortListener -Port 443) { return $true }
        }
    }
    return $false
}

# ---------------- 体检 ----------------
function Show-Doctor {
    $state = Read-JsonFile -Path $script:StatePath
    $port = $script:DefaultPort
    if ($state -and $state.listenPort) { $port = [int]$state.listenPort }

    Write-Host ''
    Info '===== 环境体检 ====='

    if (Test-IsAdmin) { Good '  管理员：是' } else { Warn '  管理员：否（体检不需要，安装/回滚才需要）' }

    $node = Find-Node
    if ($node) {
        $ver = ''
        try { $ver = "$(& $node --version)" } catch {}
        if (Test-NodeSignature $node) { Good ("  Node.js：{0}  {1}（签名有效）" -f $ver, $node) }
        else { Warn ("  Node.js：{0}  {1}（签名未通过，可能是自制/便携版）" -f $ver, $node) }
    } else {
        Warn '  Node.js：未找到'
    }

    if ($state) {
        $tp = "$($state.certThumbprint)"
        if ($tp.Length -gt 16) { $tp = $tp.Substring(0, 16) + '…' }
        Good ("  安装状态：v{0}，模式 {1}，端口 {2}，证书 {3}" -f $state.version, $state.mode, $state.listenPort, $tp)
        if ($state.installedAt) { Write-Host ("      安装时间：{0}" -f $state.installedAt) -ForegroundColor DarkGray }
    } else {
        Warn '  安装状态：未安装（没有 install-state.json）'
    }

    $t = Get-AccelTask
    if ($t) {
        $last = ''
        try { $last = (Get-ScheduledTaskInfo -TaskName $script:TaskName).LastTaskResult } catch {}
        Good ("  开机自启：{0}，状态 {1}，上次结果 {2}" -f $script:TaskName, $t.State, $last)
    } else {
        Warn '  开机自启：未注册'
    }

    $listener = Get-PortListener -Port $port
    if ($listener) {
        Good ("  端口 {0}：{1} (PID {2})" -f $port, $listener.Name, $listener.PID)
        if ($listener.CommandLine) { Write-Host ("      {0}" -f $listener.CommandLine) -ForegroundColor DarkGray }
    } else {
        Warn ("  端口 {0}：没有进程监听" -f $port)
    }

    $h = Get-ProxyHealth -Port $port
    if ($h) {
        Good ("  代理健康：v{0}，运行 {1} 秒，请求 {2}，失败 {3}，降级 {4}，拦截非法域名 {5}" -f `
                $h.version, $h.uptimeSec, $h.stats.requests, $h.stats.failures, $h.stats.degraded, $h.stats.blocked)
        foreach ($d in $h.domains.PSObject.Properties) {
            Write-Host ("      域名 {0}：{1} 个备用 IP" -f $d.Name, $d.Value) -ForegroundColor DarkGray
        }
        if ($h.stats.degraded -gt 0) {
            Warn '  出现过证书校验降级：上游 TLS 证书校验失败过，请确认网络中没有中间人'
        }
    } else {
        Warn '  代理健康接口无响应'
    }

    $probe = Test-ProxyServesGithub -Port $port
    if ($probe.Ok) { Good ("  严格 TLS 探测 github.com：HTTP {0}（证书受系统信任）" -f $probe.Status) }
    else { Warn ("  严格 TLS 探测失败：{0}" -f $probe.Error) }

    $certs = Get-AccelCertCandidates -State $state
    if ($certs.Count -gt 0) {
        Warn ("  证书存储：仍有 {0} 张与本工具相关的证书" -f $certs.Count)
        foreach ($c in $certs) {
            Write-Host ("      [{0}] {1}  {2}  ({3})" -f $c.Store, $c.Cert.Thumbprint.Substring(0, 16), $c.Cert.Subject, $c.Reason) -ForegroundColor DarkGray
        }
    } else {
        Good '  证书存储：没有本工具的证书'
    }

    $hostsLines = Get-GitHubHostsLines
    if ($hostsLines.Count -gt 0) {
        Good ("  hosts：{0} 行 GitHub 映射" -f $hostsLines.Count)
        $hostsLines | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    } else {
        Warn '  hosts：没有 GitHub 映射'
    }

    try {
        $dns = @([System.Net.Dns]::GetHostAddresses('github.com') | ForEach-Object { $_.IPAddressToString })
        if ($dns -contains '127.0.0.1') { Good '  DNS：github.com -> 127.0.0.1（走本机代理）' }
        else { Warn ("  DNS：github.com -> {0}" -f ($dns -join ', ')) }
    } catch {
        Warn '  DNS：解析 github.com 失败'
    }

    Write-Host ''
    if ($probe.Ok -and $h -and $listener) { Good '体检结论：代理链路正常 ✅' }
    else { Warn '体检结论：代理链路不完整，可运行「快速修复GitHub.bat」重新安装' }
    Write-Host ''
}
