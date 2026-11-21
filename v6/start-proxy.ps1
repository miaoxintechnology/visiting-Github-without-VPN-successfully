# ============================================================
# GitHub 加速器 v6 · 只启动/重启代理（不重新扫描、不改 hosts）
#
# 用途：代理意外退出、或重启电脑后计划任务没起来时，快速拉起。
# 双击「只启动代理.bat」即可，不需要管理员权限。
#
# 参数：
#   -Restart   先停掉现有代理再启动
#   -NoPause   结束后不暂停
# ============================================================
param([switch]$Restart, [switch]$NoPause)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Show-AccelIcon
Write-Host ''
Write-Host '===== GitHub 加速器 v6 · 启动代理 =====' -ForegroundColor Cyan

try {
    $state = Read-JsonFile -Path $script:StatePath
    if (-not $state) {
        Fail '尚未安装 v6（找不到 install-state.json）'
        Info '请先运行「快速修复GitHub.bat」完成安装'
        exit 1
    }
    if ($state.mode -ne 'proxy') {
        Warn '当前是直连模式，不需要启动代理'
        exit 0
    }

    $port = [int]$state.listenPort
    if ($Restart) {
        Info '先停止现有代理...'
        $null = Stop-AccelProxy -Port $port
    }

    $h = Get-ProxyHealth -Port $port
    if ($h -and $h.ok) {
        Good ("代理已在运行：PID {0}，v{1}，已运行 {2} 秒" -f $h.pid, $h.version, $h.uptimeSec)
        foreach ($d in $h.domains.PSObject.Properties) {
            Good ("  域名 {0}：{1} 个备用 IP" -f $d.Name, $d.Value)
        }
        if ($h.stats.degraded -gt 0) { Warn ("  注意：已发生 {0} 次证书校验降级" -f $h.stats.degraded) }
        exit 0
    }

    $listener = Get-PortListener -Port $port
    if ($listener) {
        Fail ("端口 {0} 已被其他程序占用：{1} (PID {2})" -f $port, $listener.Name, $listener.PID)
        exit 1
    }

    $task = Get-AccelTask
    if ($task) {
        Info "通过计划任务启动（$($script:TaskName)）..."
        Start-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
    } else {
        Warn '没有找到计划任务，直接启动 run-proxy.ps1 ...'
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$($script:RunProxy)`""
        ) -WindowStyle Hidden
    }

    $ok = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 750
        $h = Get-ProxyHealth -Port $port
        if ($h -and $h.ok) { $ok = $true; break }
    }

    if ($ok) {
        Good ("代理已启动：PID {0}，v{1}" -f $h.pid, $h.version)
        $probe = Test-ProxyServesGithub -Port $port
        if ($probe.Ok) { Good ("严格 TLS 探测：HTTP {0} ✅" -f $probe.Status) }
        else { Warn ("严格 TLS 探测失败：{0}" -f $probe.Error) }
    } else {
        Fail '代理没有在 30 秒内就绪'
        $log = Join-Path $script:LogsDir 'run-proxy.log'
        if (Test-Path -LiteralPath $log) {
            Warn '--- run-proxy.log 最后 10 行 ---'
            Get-Content -LiteralPath $log -Tail 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
        Warn '可运行「快速修复GitHub.bat」重新安装'
        exit 1
    }
}
catch {
    Fail "启动失败：$($_.Exception.Message)"
    exit 1
}
finally {
    if (-not $NoPause) { Read-Host '按回车关闭窗口' }
}
