# ============================================================
# GitHub 加速器 v6 · 代理启动器（由计划任务调用）
#
# 职责：
#   1. 从 install-state.json 读取安装状态
#   2. 用 DPAPI 解出 PFX 口令（口令只存在于 proxy-pass.dat，且只有本用户能解）
#   3. 校验 PFX 指纹与安装状态一致（防止私钥被替换）
#   4. 同步启动 node proxy.js（任务因此一直处于运行状态，崩溃可按计划任务策略重启）
#
# 一般不需要手动运行；「只启动代理.bat」会调用 start-proxy.ps1。
# ============================================================
param([switch]$Once)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Test-Path -LiteralPath $script:LogsDir)) {
    New-Item -ItemType Directory -Force -Path $script:LogsDir | Out-Null
}
$runLog = Join-Path $script:LogsDir 'run-proxy.log'

function Write-RunLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        if ((Test-Path -LiteralPath $runLog) -and (Get-Item -LiteralPath $runLog).Length -gt 5MB) {
            Move-Item -LiteralPath $runLog -Destination "$runLog.1" -Force
        }
        Add-Content -LiteralPath $runLog -Value $line -Encoding UTF8
    } catch {}
}

try {
    $state = Read-JsonFile -Path $script:StatePath
    if (-not $state) { Write-RunLog '未安装（缺少 install-state.json）'; exit 1 }
    if ($state.mode -ne 'proxy') { Write-RunLog '当前是直连模式，不需要启动代理'; exit 0 }

    $port = [int]$state.listenPort
    if (-not $Once) {
        $h = Get-ProxyHealth -Port $port
        if ($h -and $h.ok) { Write-RunLog "代理已在运行（PID $($h.pid)），跳过"; exit 0 }
    }

    if (-not (Test-Path -LiteralPath $script:PfxPath)) { throw "缺少证书文件 $script:PfxPath" }
    if (-not (Test-Path -LiteralPath $script:SecretPath)) { throw "缺少口令文件 $script:SecretPath" }

    $pass = Unprotect-SecretFile -Path $script:SecretPath
    $pfx = Get-PfxCertificateObject -Path $script:PfxPath -PlainPassword $pass
    if ($pfx.Thumbprint -ne $state.certThumbprint) {
        throw 'PFX 指纹与安装状态不一致：证书文件可能被替换，已拒绝启动'
    }

    $node = Find-Node
    if (-not $node) { throw '找不到 Node.js（若使用便携版，请确认 .node 目录还在）' }

    $env:GH_ACCEL_PFX_PASS = $pass
    Write-RunLog "启动代理：$node proxy.js（端口 $port，证书 $($pfx.Thumbprint.Substring(0,16))…）"

    $stdout = Join-Path $script:LogsDir 'proxy-stdout.log'
    $stderr = Join-Path $script:LogsDir 'proxy-stderr.log'
    $proc = Start-Process -FilePath $node -ArgumentList ('"' + $script:ProxyJs + '"') `
        -WorkingDirectory $script:WorkDir -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    Write-RunLog "代理进程退出，退出码 $($proc.ExitCode)"
    exit $proc.ExitCode
}
catch {
    Write-RunLog "启动失败：$($_.Exception.Message)"
    exit 9
}
finally {
    Remove-Item Env:\GH_ACCEL_PFX_PASS -ErrorAction SilentlyContinue
}
