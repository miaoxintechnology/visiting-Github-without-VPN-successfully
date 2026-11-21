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

# ---------------- curl 解析 ----------------
# 兼容性说明：Windows 10 老版本自带的 curl 是 7.55.1（2017 年），
# 不支持 --parallel / -Z（需要 7.66+）。这里自动挑选可用的最高版本 curl，
# 并记录是否支持并行；不支持时上层会降级到 .NET 并发实现。
function Resolve-Curl {
    if ($script:CurlExe) { return $script:CurlExe }

    $candidates = New-Object System.Collections.Generic.List[string]
    $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $candidates.Add($cmd.Source) }

    # Git for Windows / scoop / chocolatey 常见安装位置。
    # 注意顺序：msys64 的 curl 读不到 Windows 的 hosts（实测 github.com 解析失败），
    # 所以排在最后，只有前面都不行时才用。
    $extra = @(
        "$env:ProgramFiles\Git\mingw64\bin\curl.exe",
        "$env:ProgramFiles\Git\usr\bin\curl.exe",
        "$env:ProgramFiles\Git\bin\curl.exe",
        "${env:ProgramFiles(x86)}\Git\mingw64\bin\curl.exe",
        "$env:USERPROFILE\scoop\apps\curl\current\bin\curl.exe",
        "$env:ProgramData\chocolatey\bin\curl.exe",
        'C:\msys64\ucrt64\bin\curl.exe',
        'C:\msys64\mingw64\bin\curl.exe',
        'C:\msys64\usr\bin\curl.exe'
    )
    foreach ($p in $extra) { if ($p) { $candidates.Add($p) } }

    $best = $null; $bestVersion = [version]'0.0.0'; $bestParallel = $false
    $seen = @{}
    $parallelCandidates = New-Object System.Collections.Generic.List[object]
    foreach ($p in $candidates) {
        if (-not $p) { continue }
        $key = $p.ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $verLine = (& $p --version 2>$null | Select-Object -First 1)
            if ($verLine -match 'curl\s+(\d+)\.(\d+)\.(\d+)') {
                $v = [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])")
                if ($v -ge [version]'7.66') {
                    $parallelCandidates.Add([pscustomobject]@{ Path = $p; Version = $v })
                } elseif ($v -gt $bestVersion) {
                    $best = $p; $bestVersion = $v; $bestParallel = $false
                }
            }
        } catch { }
    }

    # 逐个验证「支持并行」的候选是否真能联网，选版本最高的可用者。
    # 踩过的坑：msys64 自带的 curl 8.22 版本最高、--parallel 也支持，
    # 但它走 msys 自己的网络配置，连 github.com 返回 000；Git 自带的
    # curl 8.21 才正常。所以必须实测连通性，不能只看版本号。
    foreach ($cand in ($parallelCandidates | Sort-Object Version -Descending)) {
        if (Test-CurlConnectivity -Exe $cand.Path) {
            $best = $cand.Path; $bestVersion = $cand.Version; $bestParallel = $true
            break
        } else {
            Write-Host ("[-] curl 不可用（连不上网络），已跳过：{0}" -f $cand.Path) -ForegroundColor DarkYellow
        }
    }
    # 系统里没有支持并行的 curl → 自动下载便携版（放 .tools\curl，不污染系统）
    # 若设置了 GH_ACCEL_NO_CURL_DOWNLOAD=1，则跳过下载，直接用 .NET 并发降级
    if (-not $bestParallel -and -not $env:GH_ACCEL_NO_CURL_DOWNLOAD) {
        $portable = Install-CurlPortable
        if ($portable) {
            $best = $portable
            $bestParallel = $true
            try {
                $line = (& $portable --version 2>$null | Select-Object -First 1)
                if ($line -match 'curl\s+(\d+)\.(\d+)\.(\d+)') {
                    $bestVersion = [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])")
                }
            } catch { }
        }
    }

    if (-not $best -and $candidates.Count -gt 0) { $best = $candidates[0] }
    if (-not $best) { $best = 'curl.exe'; $bestVersion = [version]'0.0.0' }

    $script:CurlExe = $best
    $script:CurlVersion = $bestVersion
    $script:CurlHasParallel = $bestParallel
    return $best
}

# 验证某个 curl 是否真能用：
#   1) 基础网络正常（连 baidu，国内必达，不受 GitHub 封锁影响）
#   2) 若 hosts 里已配置 github.com -> 127.0.0.1，要求它能正确读取该映射
#      （msys64 的 curl 读不到 Windows hosts，实测 remote_ip 为空，
#        会导致「代理装好但整条链路失效」，必须排除）
function Test-CurlConnectivity {
    param([string]$Exe)
    try {
        # 1) 基础网络
        $code = (& $Exe -s -o NUL -w '%{http_code}' --connect-timeout 3 --max-time 8 'https://www.baidu.com/' 2>$null)
        if ($code -notmatch '^[123]\d\d$') { return $false }

        # 2) hosts 读取能力（仅在 hosts 已配置 GitHub 映射时检查）
        $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        if (Test-Path -LiteralPath $hostsPath) {
            $mapped = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue) |
                      Where-Object { $_ -match '^\s*127\.0\.0\.1\s+github\.com\s*$' }
            if ($mapped.Count -gt 0) {
                $ip = (& $Exe -s -o NUL -w '%{remote_ip}' --connect-timeout 2 --max-time 5 `
                       'https://github.com/favicon.ico' 2>$null)
                if ($ip -ne '127.0.0.1') {
                    Write-Host ("[-] curl 读不到 hosts 映射，已跳过：{0}" -f $Exe) -ForegroundColor DarkYellow
                    return $false
                }
            }
        }
        return $true
    } catch { return $false }
}

# 下载便携版 curl 到 .tools\curl（仅在系统里找不到支持 --parallel 的新版 curl 时使用）
# 返回 curl.exe 路径，失败返回 $null。不写系统目录、不需要管理员、不改 PATH。
function Install-CurlPortable {
    param([switch]$Force)
    $toolsDir = Join-Path $PSScriptRoot '.tools\curl'
    $exePath = Join-Path $toolsDir 'bin\curl.exe'

    if (-not $Force -and (Test-Path -LiteralPath $exePath)) {
        try {
            $line = (& $exePath --version 2>$null | Select-Object -First 1)
            if ($line -match 'curl\s+(\d+)\.(\d+)') {
                $v = [version]("$($Matches[1]).$($Matches[2])")
                if ($v -ge [version]'7.66') { return $exePath }
            }
        } catch { }
    }

    try {
        Write-Host '[*] 未找到支持 --parallel 的 curl，尝试自动下载便携版...' -ForegroundColor Cyan
        Write-Host '    （国内下载约 1~4 分钟；若太慢可设 GH_ACCEL_NO_CURL_DOWNLOAD=1 跳过，改用 .NET 并发）' -ForegroundColor DarkGray

        # 1) 解析 curl.se/windows 最新版下载地址
        $page = Invoke-WebRequest -Uri 'https://curl.se/windows/' -UseBasicParsing -TimeoutSec 30
        $verList = @([regex]::Matches($page.Content, 'dl-(\d+\.\d+\.\d+_\d+)/curl-\d+\.\d+\.\d+_\d+-win64-mingw\.zip') |
                     ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        if ($verList.Count -eq 0) {
            Write-Host '[-] 无法解析 curl 下载版本号' -ForegroundColor Yellow
            return $null
        }
        $ver = $verList[0]
        $url = "https://curl.se/windows/dl-$ver/curl-$ver-win64-mingw.zip"
        Write-Host "    版本：$ver" -ForegroundColor DarkGray
        Write-Host "    地址：$url" -ForegroundColor DarkGray

        # 2) 下载
        $zip = Join-Path $env:TEMP "curl-$ver.zip"
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 180 -UseBasicParsing -ErrorAction Stop
        } finally { $ProgressPreference = $oldProgress }
        if (-not (Test-Path -LiteralPath $zip) -or (Get-Item -LiteralPath $zip).Length -lt 500KB) {
            Write-Host '[-] 下载失败或文件异常' -ForegroundColor Yellow
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            return $null
        }

        # 3) 解压（用系统自带 tar 优先，老系统用 Expand-Archive）
        $tmpDir = Join-Path $env:TEMP ("curl-extract-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $extracted = $false
        if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
            & tar.exe -xf $zip -C $tmpDir 2>$null
            if ($LASTEXITCODE -eq 0) { $extracted = $true }
        }
        if (-not $extracted) {
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmpDir)
                $extracted = $true
            } catch {
                Expand-Archive -Path $zip -DestinationPath $tmpDir -Force
                $extracted = $true
            }
        }
        if (-not $extracted) { throw '解压失败' }

        # 4) 找到 curl.exe 并放到 .tools\curl\bin
        $found = Get-ChildItem $tmpDir -Recurse -Filter 'curl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) { throw '压缩包里没有 curl.exe' }

        New-Item -ItemType Directory -Path (Join-Path $toolsDir 'bin') -Force | Out-Null
        Copy-Item $found.FullName $exePath -Force
        # mingw 版是静态链接，通常无依赖 DLL；若有则一并复制
        Get-ChildItem $found.DirectoryName -Filter '*.dll' -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $toolsDir 'bin') -Force }

        # 5) 验证
        $line2 = (& $exePath --version 2>$null | Select-Object -First 1)
        if ($line2 -match 'curl\s+(\d+)\.(\d+)') {
            $v2 = [version]("$($Matches[1]).$($Matches[2])")
            if ($v2 -ge [version]'7.66') {
                Write-Host "[+] 便携版 curl 已就绪：$exePath" -ForegroundColor Green
                return $exePath
            }
        }
        Write-Host '[-] 下载的 curl 版本仍不支持 --parallel' -ForegroundColor Yellow
        return $null
    } catch {
        Write-Host "[-] 自动下载 curl 失败：$($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    } finally {
        Remove-Item (Join-Path $env:TEMP "curl-$ver.zip") -Force -ErrorAction SilentlyContinue
        if ($tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------- 网络探测 ----------------
function Invoke-Curl {
    param([string[]]$Arguments, [int]$TimeoutSec = 40)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $exe = Resolve-Curl
        $out = & $exe @Arguments 2>$null
        return ("$out" -replace '\s+$', '')
    } finally { $ErrorActionPreference = $prev }
}

# 无 SNI 批量探测（.NET 并发实现，不依赖 curl 版本）
# URL 用 IP，HttpWebRequest 对 IP 不发 SNI；Host 头指定目标域名，上游按域名返回内容。
function Test-NoSniBatchDotNet {
    param(
        [string]$Hostname,
        [string[]]$Ips,
        [string]$Path = '/',
        [string]$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36',
        [int]$Batch = 20,
        [int]$TimeoutMs = 7000
    )
    $hits = New-Object System.Collections.Generic.List[string]
    if (-not $Ips -or $Ips.Count -eq 0) { return $hits.ToArray() }

    $prevCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    $prevProtocol = [System.Net.ServicePointManager]::SecurityProtocol
    try {
        # 等价 curl -k：不校验上游证书（后续由 Get-NoSniCertProbe 单独严格校验）
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

        $total = $Ips.Count
        for ($i = 0; $i -lt $total; $i += $Batch) {
            $end = [Math]::Min($i + $Batch - 1, $total - 1)
            $chunk = @($Ips[$i..$end])
            $pending = New-Object System.Collections.Generic.List[object]
            foreach ($ip in $chunk) {
                try {
                    $req = [System.Net.HttpWebRequest]::Create("https://$ip$Path")
                    $req.Host = $Hostname
                    $req.UserAgent = $UserAgent
                    $req.Timeout = $TimeoutMs
                    $req.ReadWriteTimeout = $TimeoutMs
                    $req.AllowAutoRedirect = $false
                    $req.Method = 'GET'
                    $req.KeepAlive = $false
                    $pending.Add([pscustomobject]@{
                        Ip = $ip
                        Req = $req
                        Async = $req.BeginGetResponse($null, $null)
                    })
                } catch { }
            }
            foreach ($item in $pending) {
                $code = 0
                try {
                    $resp = $item.Req.EndGetResponse($item.Async)
                    try { $code = [int]$resp.StatusCode } finally { $resp.Close() }
                } catch {
                    # 301/302 会抛 WebException，但异常里带响应
                    $webResp = $null
                    try { $webResp = $_.Exception.Response } catch { }
                    if ($webResp) {
                        try { $code = [int]$webResp.StatusCode } catch { }
                        try { $webResp.Close() } catch { }
                    }
                }
                if ($code -eq 200 -or $code -eq 301 -or $code -eq 302) {
                    if (-not $hits.Contains($item.Ip)) { $hits.Add($item.Ip) }
                }
            }
        }
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCallback
        [System.Net.ServicePointManager]::SecurityProtocol = $prevProtocol
    }
    return $hits.ToArray()
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
