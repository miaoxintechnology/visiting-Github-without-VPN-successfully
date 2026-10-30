# ============================================================
# 只启动本地代理（不重新扫描、不改 hosts）
#
# 用途：修复过一次后，重启电脑 / 代理意外退出时，
#      快速把代理重新拉起来，不用再等几分钟的完整扫描。
#
# 与 fix-github.ps1 的区别：
#   fix-github.ps1  → 扫描 IP + 判断封锁类型 + 改 hosts + 起代理（1~3 分钟）
#   start-proxy.ps1 → 只按现有 proxy-config.json 起代理（1~3 秒）
#
# 用法：双击同目录的「只启动代理.bat」
# ============================================================
param([switch]$NoPause)

$ErrorActionPreference = 'SilentlyContinue'
$script:WorkDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$proxyJs = Join-Path $script:WorkDir 'proxy.js'
$cfgPath = Join-Path $script:WorkDir 'proxy-config.json'

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Good($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[-] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[x] $m" -ForegroundColor Red }

Write-Host ''
Write-Host '===== GitHub 本地代理 =====' -ForegroundColor Cyan

# ---------- 1. 文件检查 ----------
if (-not (Test-Path $proxyJs)) {
    Fail "缺少 proxy.js（应与本脚本同目录）"
    if (-not $NoPause) { Read-Host '按回车关闭' }
    exit 1
}
if (-not (Test-Path $cfgPath)) {
    Fail '缺少 proxy-config.json'
    Warn '请先运行「快速修复GitHub.bat」（会自动生成配置）'
    if (-not $NoPause) { Read-Host '按回车关闭' }
    exit 1
}

# ---------- 2. 找 Node.js ----------
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
    $nodeDir = Join-Path $script:WorkDir '.node'
    if (Test-Path $nodeDir) {
        $found = Get-ChildItem $nodeDir -Recurse -Filter 'node.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $node = $found.FullName }
    }
}
if (-not $node) {
    Fail '找不到 Node.js'
    Warn '请先运行「快速修复GitHub.bat」（它会自动安装 Node.js）'
    if (-not $NoPause) { Read-Host '按回车关闭' }
    exit 1
}
Good "Node.js：$node"

# ---------- 3. 检查是否已在运行 ----------
$listening = Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue
if ($listening) {
    $procId = ($listening | Select-Object -First 1).OwningProcess
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    Good "代理已在运行 (127.0.0.1:443，PID $procId $(if($proc){$proc.ProcessName}))"
    if (-not $NoPause) { Start-Sleep -Seconds 3 }
    exit 0
}

# ---------- 4. 启动代理 ----------
Info '启动代理...'
Start-Process -FilePath $node -ArgumentList 'proxy.js' -WorkingDirectory $script:WorkDir -WindowStyle Hidden
Start-Sleep -Seconds 2

# ---------- 5. 验证 ----------
$check = Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue
if ($check) {
    Good '代理已启动！(127.0.0.1:443)'
    Write-Host ''
    Write-Host ' GitHub 现在可以访问了' -ForegroundColor Green
    Write-Host ' 如果浏览器还打不开，按 Ctrl+Shift+R 强刷' -ForegroundColor DarkGray
} else {
    Fail '代理启动失败'
    $logPath = Join-Path $script:WorkDir 'proxy.log'
    if (Test-Path $logPath) {
        Write-Host ' --- proxy.log 最后几行 ---' -ForegroundColor DarkGray
        Get-Content $logPath -Tail 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    Warn '可运行「快速修复GitHub.bat」重新完整修复'
}
if (-not $NoPause) { Read-Host '按回车关闭' }
