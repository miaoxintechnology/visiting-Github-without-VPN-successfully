# ============================================================
# GitHub 加速器 v6 · 一键回滚
#
# 彻底撤销 v5 / v6 的所有改动：
#   1. 停止本地代理（含 v5 遗留进程）
#   2. 删除开机自启计划任务
#   3. 删除「受信任的根证书颁发机构」里的证书
#      —— 包括 v5 的 CN=github.com（v5 的 uninstall 漏删的那张）
#   4. 从 hosts 删除 GitHub 配置段与残留映射行
#   5. 删除证书/口令/配置/日志文件
#   6. 刷新 DNS 并验证
#
# 用法：双击「一键回滚.bat」
#
# 参数：
#   -DryRun        只打印将要做的事，不修改系统
#   -KeepNode      保留自动下载的便携版 Node.js（.node 目录）
#   -CleanLegacy   同时删除 v5 目录里遗留的证书/配置（含明文口令的旧文件）
#   -NoPause       结束后不暂停
# ============================================================
param(
    [switch]$NoPause,
    [switch]$DryRun,
    [switch]$KeepNode,
    [switch]$CleanLegacy
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$script:ForwardArgs = @()
if ($NoPause) { $script:ForwardArgs += '-NoPause' }
if ($DryRun) { $script:ForwardArgs += '-DryRun' }
if ($KeepNode) { $script:ForwardArgs += '-KeepNode' }
if ($CleanLegacy) { $script:ForwardArgs += '-CleanLegacy' }

Show-AccelIcon
Write-Host ''
Write-Host ('=' * 62) -ForegroundColor Cyan
Write-Host '  GitHub 加速器 v6 · 一键回滚' -ForegroundColor White
Write-Host ('=' * 62) -ForegroundColor Cyan
if ($DryRun) { Warn 'DryRun 模式：只打印计划，不修改系统' }

$state = Read-JsonFile -Path $script:StatePath
$port = $script:DefaultPort
if ($state -and $state.listenPort) { $port = [int]$state.listenPort }

if (-not $DryRun) {
    if (-not (Test-IsAdmin)) {
        Request-Elevation -ScriptPath $PSCommandPath -Arguments $script:ForwardArgs
        exit
    }
    Good '管理员权限确认'
}

$hadProblem = $false

try {
    # ---------- 1. 停止代理 ----------
    Info '第 1/7 步：停止本地代理'
    $listener = Get-PortListener -Port $port
    if ($listener) {
        if ($DryRun) {
            Info ("  将停止占用 {0} 端口的进程：{1} (PID {2})" -f $port, $listener.Name, $listener.PID)
        } else {
            $null = Stop-AccelProxy -Port $port
        }
    }
    if ($DryRun) {
        foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue)) {
            if ($p.CommandLine -like '*proxy.js*') { Info ("  将停止 node proxy.js（PID {0}）" -f $p.ProcessId) }
        }
    }
    if (-not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
        Good ("  端口 {0} 已释放" -f $port)
    } elseif (-not $DryRun) {
        Warn ("  端口 {0} 仍被占用（可能不是本工具）" -f $port)
    }

    # ---------- 2. 计划任务 ----------
    Info '第 2/7 步：删除开机自启'
    $taskDeleted = Unregister-AccelTask -DryRun:$DryRun
    if (-not $taskDeleted) { Good '  没有需要删除的计划任务' }

    # ---------- 3. 证书 ----------
    Info '第 3/7 步：删除受信任根证书（含 v5 的 CN=github.com）'
    if ($DryRun) {
        $null = Remove-AccelCerts -State $state -DryRun
    } else {
        $removed = Remove-AccelCerts -State $state
        if ($removed -eq 0) { Good '  没有找到需要删除的证书' }
    }
    if (-not $DryRun) {
        $left = Get-AccelCertCandidates -State $state
        if ($left.Count -gt 0) {
            Warn ("  仍有 {0} 张证书未删除" -f $left.Count)
            foreach ($c in $left) { Write-Host ("      [{0}] {1} {2}" -f $c.Store, $c.Cert.Thumbprint, $c.Cert.Subject) -ForegroundColor DarkGray }
            $hadProblem = $true
        } else {
            Good '  证书存储已清理干净'
        }
    }

    # ---------- 4. hosts ----------
    Info '第 4/7 步：清理 hosts'
    $githubDomains = @(
        'github.com', 'www.github.com', 'api.github.com', 'codeload.github.com',
        'gist.github.com', 'collector.github.com', 'raw.githubusercontent.com',
        'assets-cdn.github.com', 'avatars.githubusercontent.com', 'avatars0.githubusercontent.com',
        'avatars1.githubusercontent.com', 'avatars2.githubusercontent.com', 'objects.githubusercontent.com',
        'github.githubassets.com', 'github.global.ssl.fastly.net'
    )
    $lines = Read-HostsLines
    $clean = @(Remove-GitHubHostsSection -Lines $lines)
    $kept = New-Object System.Collections.Generic.List[string]
    $removedLines = [Math]::Max(0, $lines.Count - $clean.Count)
    foreach ($x in $clean) {
        $isGithub = $false
        foreach ($d in $githubDomains) {
            $escaped = [regex]::Escape($d)
            if ($x -match "^\s*#?\s*\S+\s+${escaped}\s*$") { $isGithub = $true; break }
        }
        if ($isGithub) { $removedLines++; continue }
        $kept.Add($x)
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1].Trim() -eq '') { $kept.RemoveAt($kept.Count - 1) }

    if ($DryRun) {
        Info ("  将从 hosts 移除 {0} 行 GitHub 映射" -f $removedLines)
        $kept | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } else {
        $backup = Get-HostsBackup
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $tmp = "$($script:HostsPath).tmp-v6"
        [System.IO.File]::WriteAllLines($tmp, $kept.ToArray(), $utf8)
        Move-Item -LiteralPath $tmp -Destination $script:HostsPath -Force
        ipconfig /flushdns 2>&1 | Out-Null
        Good ("  hosts 已清理（移除 {0} 行，备份：{1}）" -f $removedLines, (Split-Path -Leaf $backup))
    }

    # ---------- 5. 文件 ----------
    Info '第 5/7 步：删除本工具生成的文件'
    $files = @(
        'proxy-config.json', 'proxy-cert.pfx', 'proxy-cert.cer', 'proxy-pass.dat',
        'install-state.json', 'proxy-state.json', 'proxy.log', 'proxy.log.1', 'proxy.log.2'
    )
    foreach ($f in $files) {
        $p = Join-Path $script:WorkDir $f
        if (Test-Path -LiteralPath $p) {
            if ($DryRun) { Info "  将删除 $f" }
            else { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; Good "  已删除 $f" }
        }
    }
    if (Test-Path -LiteralPath $script:LogsDir) {
        if ($DryRun) { Info '  将删除 logs 目录' }
        else { Remove-Item -LiteralPath $script:LogsDir -Recurse -Force -ErrorAction SilentlyContinue; Good '  已删除 logs 目录' }
    }
    if (-not $KeepNode) {
        $nodeDir = Join-Path $script:WorkDir '.node'
        if (Test-Path -LiteralPath $nodeDir) {
            if ($DryRun) { Info '  将删除便携版 Node.js（.node）' }
            else { Remove-Item -LiteralPath $nodeDir -Recurse -Force -ErrorAction SilentlyContinue; Good '  已删除便携版 Node.js（.node）' }
        }
    }

    # ---------- 6. v5 遗留 ----------
    Info '第 6/7 步：检查 v5 遗留文件'
    $legacyDirs = @(Get-LegacyDirs)
    if ($legacyDirs.Count -eq 0) {
        Good '  没有发现 v5 目录'
    } else {
        foreach ($d in $legacyDirs) {
            $found = @()
            foreach ($f in @('proxy-cert.pfx', 'proxy-config.json', 'proxy-pass.dat', 'proxy-cert.cer')) {
                if (Test-Path -LiteralPath (Join-Path $d $f)) { $found += $f }
            }
            if ($found.Count -gt 0) {
                Warn ("  {0} 里还有：{1}" -f $d, ($found -join ', '))
                $hasPlainPass = $false
                $cfg = Join-Path $d 'proxy-config.json'
                if (Test-Path -LiteralPath $cfg) {
                    $t = [System.IO.File]::ReadAllText($cfg)
                    if ($t -match 'localproxy') { $hasPlainPass = $true }
                }
                if ($hasPlainPass) { Warn '  该旧配置含明文口令 localproxy，建议删除（加 -CleanLegacy 自动删除）' }
                if ($CleanLegacy) {
                    foreach ($f in $found) {
                        if ($DryRun) { Info "  将删除 $d\$f" }
                        else { Remove-Item -LiteralPath (Join-Path $d $f) -Force -ErrorAction SilentlyContinue; Good "  已删除 $d\$f" }
                    }
                }
            }
        }
    }

    # ---------- 7. 验证 ----------
    Info '第 7/7 步：验证回滚结果'
    if ($DryRun) {
        Info '  DryRun：跳过验证'
    } else {
        $stillPort = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($stillPort) { Warn '  端口仍被监听（可能不是本工具）'; $hadProblem = $true } else { Good '  端口已释放' }

        $certs = Get-AccelCertCandidates -State $null
        if ($certs.Count -eq 0) { Good '  没有残留证书' } else { Warn ("  残留 {0} 张证书" -f $certs.Count); $hadProblem = $true }

        # Windows 保护「用户级受信任根存储」：程序无法自动删除，只能提示手动处理
        $lmRootThumbs = @(Get-ChildItem 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue | ForEach-Object { $_.Thumbprint })
        $userOnly = @()
        foreach ($ce in (Get-ChildItem 'Cert:\CurrentUser\Root' -ErrorAction SilentlyContinue)) {
            if ($ce.Subject -eq 'CN=github.com' -and $ce.Subject -eq $ce.Issuer -and ($lmRootThumbs -notcontains $ce.Thumbprint)) {
                $userOnly += $ce
            }
        }
        if ($userOnly.Count -gt 0) {
            Warn ("  用户级根证书还剩 {0} 张（Windows 不允许程序自动删除）" -f $userOnly.Count)
            foreach ($u in $userOnly) {
                Write-Host ("      {0}  {1}" -f $u.Thumbprint, $u.Subject) -ForegroundColor DarkGray
            }
            Info '  手动处理：Win+R → certmgr.msc → 受信任的根证书颁发机构 → 证书 → 删除 CN=github.com'
            $hadProblem = $true
        }

        $gh = Get-GitHubHostsLines
        if ($gh.Count -eq 0) { Good '  hosts 已无 GitHub 映射' }
        else {
            Warn ("  hosts 仍有 {0} 行含 github" -f $gh.Count)
            $gh | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            $hadProblem = $true
        }

        $t = Get-AccelTask
        if ($t) { Warn '  计划任务仍然存在'; $hadProblem = $true } else { Good '  计划任务已删除' }
    }

    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor $(if ($hadProblem) { 'Yellow' } else { 'Green' })
    if ($DryRun) {
        Info 'DryRun 完成：未修改任何系统设置'
    } elseif ($hadProblem) {
        Warn '回滚基本完成，但有少量残留，请查看上方黄色提示'
    } else {
        Good '回滚完成：hosts / 证书 / 计划任务 / 配置 已全部恢复'
    }
    Write-Host ('=' * 62) -ForegroundColor $(if ($hadProblem) { 'Yellow' } else { 'Green' })
    Write-Host ''
    Info '注意：回滚后 GitHub 会恢复为「无法直连」的原始状态，这是预期行为。'
    Write-Host ''
}
catch {
    Fail "回滚失败：$($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
finally {
    if (-not $NoPause) { Read-Host '按回车关闭窗口' }
}
