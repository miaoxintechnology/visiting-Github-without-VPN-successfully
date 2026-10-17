# ============================================================
# GitHub 一键回滚 (Windows)
#
# 彻底撤销 fix-github.ps1 的所有改动，恢复到原始状态：
#   1. 停止本地代理进程
#   2. 从「受信任的根证书颁发机构」删除本地自签证书
#   3. 从 hosts 删除所有 GitHub 相关条目（保留其他配置）
#   4. 删除脚本生成的配置文件（证书/配置/日志）
#   5. 刷新 DNS 缓存
#
# 用法：
#   双击同目录的「一键回滚.bat」，或：
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
# ============================================================
param([switch]$NoPause)

$ErrorActionPreference = 'SilentlyContinue'
$script:WorkDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Good($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[-] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[x] $m" -ForegroundColor Red }

# ---------- 自提权 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '[*] 正在请求管理员权限...' -ForegroundColor Cyan
    $a = @('-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($NoPause) { $a += '-NoPause' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs
    exit
}
Good '管理员权限确认'

# ---------- 1. 停止代理 ----------
Info '第 1/5 步：停止本地代理...'
$stopped = 0
$pids = Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
foreach ($p in $pids) {
    $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -eq 'node') {
        Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        Good "  已停止代理进程 (PID $p)"
        $stopped++
    }
}
# 兜底：清理命令行里带 proxy.js 的 node 进程
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*proxy.js*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $stopped++ }
if ($stopped -eq 0) { Warn '  没有发现运行中的代理进程' } else { Good "  共停止 $stopped 个代理进程" }
Start-Sleep -Milliseconds 800

# ---------- 2. 删除受信任证书 ----------
Info '第 2/5 步：删除受信任的本地证书...'
$certNames = @('CN=Local GitHub Proxy', 'CN=Local SNI Proxy', 'CN=Local Proxy')
$removed = 0
foreach ($store in @('Cert:\LocalMachine\Root', 'Cert:\LocalMachine\My')) {
    Get-ChildItem $store -ErrorAction SilentlyContinue |
        Where-Object { $certNames -contains $_.Subject } |
        ForEach-Object {
            Good "  删除证书: $($_.Subject) ($($_.Thumbprint.Substring(0,12))...)"
            Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue
            $removed++
        }
}
if ($removed -eq 0) { Warn '  没有找到本地代理证书' } else { Good "  共删除 $removed 张证书" }

# ---------- 3. 清理 hosts ----------
Info '第 3/5 步：清理 hosts 文件...'
$backup = "$hostsPath.bak-uninstall-$(Get-Date -Format 'MMdd-HHmmss')"
Copy-Item $hostsPath $backup -Force
Good "  已备份到 $(Split-Path $backup -Leaf)"

$lines = [System.IO.File]::ReadAllLines($hostsPath)
$out = [System.Collections.Generic.List[string]]::new()
$skipSection = $false
$removedLines = 0
$githubDomains = @(
    'github.com', 'www.github.com', 'api.github.com', 'codeload.github.com',
    'gist.github.com', 'collector.github.com', 'raw.githubusercontent.com',
    'assets-cdn.github.com', 'avatars.githubusercontent.com', 'avatars0.githubusercontent.com',
    'avatars1.githubusercontent.com', 'avatars2.githubusercontent.com', 'objects.githubusercontent.com',
    'github.githubassets.com', 'github.global.ssl.fastly.net'
)

foreach ($x in $lines) {
    # 3.1 跳过脚本标记段（兼容各版本标记）
    if ($x -match '#\s*===?\s*GitHub\s+hosts' -or
        $x -match 'auto-fixed by fix-github' -or
        $x -match '#\s*===?\s*GitHub\s+fix') {
        $skipSection = $true
        continue
    }
    if ($x -match '#\s*===?\s*end\s+GitHub') {
        $skipSection = $false
        continue
    }
    if ($skipSection) { $removedLines++; continue }

    # 3.2 跳过残留的 GitHub 域名映射行（含注释掉的行）
    $trimmed = $x.Trim()
    $isGithubLine = $false
    foreach ($d in $githubDomains) {
        # 匹配 "IP 域名" 或 "127.0.0.1 域名" 形式，行尾就是域名
        $escaped = [regex]::Escape($d)
        if ($trimmed -match "^\s*#?\s*\S+\s+${escaped}\s*$") { $isGithubLine = $true; break }
    }
    if ($isGithubLine) { $removedLines++; continue }

    $out.Add($x)
}

# 清理末尾多余空行
while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }

[System.IO.File]::WriteAllLines($hostsPath, $out.ToArray(), [System.Text.Encoding]::ASCII)
if ($removedLines -gt 0) { Good "  已移除 $removedLines 行 GitHub 相关配置" } else { Warn '  hosts 中没有 GitHub 相关配置' }

# 显示 hosts 最终内容
Write-Host '  ---- hosts 最终内容 ----' -ForegroundColor DarkGray
[System.IO.File]::ReadAllLines($hostsPath) | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

# ---------- 4. 删除脚本生成的配置文件 ----------
Info '第 4/5 步：删除脚本生成的配置文件...'
$filesToRemove = @(
    'proxy-config.json', 'proxy-cert.pfx', 'proxy-cert.cer',
    'cert.pem', 'key.pem', 'proxy.log'
)
$deleted = 0
foreach ($f in $filesToRemove) {
    $path = Join-Path $script:WorkDir $f
    if (Test-Path $path) {
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        Good "  已删除: $f"
        $deleted++
    }
}
if ($deleted -eq 0) { Warn '  没有需要删除的配置文件' }

# ---------- 5. 刷新 DNS ----------
Info '第 5/5 步：刷新 DNS 缓存...'
ipconfig /flushdns | Out-Null
Good '  DNS 缓存已刷新'

# ---------- 验证 ----------
Write-Host ''
Info '验证回滚结果...'
$allClean = $true

# 5.1 代理进程
$stillRunning = Get-NetTCPConnection -LocalPort 443 -State Listen -ErrorAction SilentlyContinue
if ($stillRunning) {
    Warn "  仍有进程监听 443（可能不是代理，属正常）"
} else {
    Good '  443 端口已释放'
}

# 5.2 证书
$stillCert = @()
foreach ($store in @('Cert:\LocalMachine\Root', 'Cert:\LocalMachine\My')) {
    $stillCert += Get-ChildItem $store -ErrorAction SilentlyContinue |
                  Where-Object { $certNames -contains $_.Subject }
}
if ($stillCert.Count -gt 0) { Warn "  仍有 $($stillCert.Count) 张证书未删除"; $allClean = $false }
else { Good '  受信任证书已清理' }

# 5.3 hosts
$stillGithub = [System.IO.File]::ReadAllLines($hostsPath) | Where-Object { $_ -match 'github' }
if ($stillGithub) {
    Warn "  hosts 仍有 $($stillGithub.Count) 行含 github 的内容"
    $stillGithub | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    $allClean = $false
} else {
    Good '  hosts 已无 GitHub 相关配置'
}

$sw.Stop()
Write-Host ''
Write-Host ('=' * 56) -ForegroundColor Green
if ($allClean) {
    Write-Host (" 回滚完成！耗时 {0:N0} 秒" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host ' 所有改动已撤销，系统已恢复原始状态' -ForegroundColor Green
} else {
    Write-Host (" 回滚基本完成（耗时 {0:N0} 秒），但有几项未完全清理" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Yellow
    Write-Host ' 请查看上方黄色提示' -ForegroundColor Yellow
}
Write-Host ('=' * 56) -ForegroundColor Green
Write-Host ''
Write-Host ' 注意：回滚后 GitHub 将恢复为「无法访问」的原始状态' -ForegroundColor Yellow
Write-Host '（因为所有绕过措施都已移除，这是预期行为）' -ForegroundColor Yellow
Write-Host ''
Write-Host " hosts 备份保留在: $(Split-Path $backup -Leaf)" -ForegroundColor DarkGray
Write-Host ' 如需再次修复，重新运行 fix-github.ps1 即可' -ForegroundColor DarkGray
Write-Host ''
if (-not $NoPause) { Read-Host '按回车关闭窗口' }
